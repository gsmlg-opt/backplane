defmodule Backplane.AgentRuntime.Codex.MultiAgent.Archive do
  @moduledoc false

  alias Backplane.AgentRuntime.{Error, HostFeedback}
  alias Backplane.AgentRuntime.Codex.Reconciliation
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

  @admission_fields ~w(schema_version record_type child_identity store_ref config_ref authority_ceiling_ref tool_profile admission_receipt_ref child_request configuration authority_ceiling artifact_refs inventory_ref)
  @inventory_fields ~w(schema_version record_type child_identity complete producer_ref obligations)
  @archive_fields ~w(schema_version archive_id archive_digest child_identity tool_profile admission_ref admission_receipt_ref retirement_receipt_ref retirement_receipt_digest manifest_digest terminal_record messages host_feedback history_digest remaining_work deadline child_request configuration_ref configuration_digest authority_ceiling_ref authority_ceiling_digest artifact_refs host_metadata)
  @message_fields ~w(role content id name tool_call_id invocation_id result tool_calls reasoning reasoning_content reasoning_details source host_feedback collaboration refusal annotations provider_state)
  @eligible [:completed, :failed, :cancelled, :timed_out]

  def subject(identity), do: %{"kind" => "child", "identity" => identity}

  def child_manifest(config, pin) do
    with {:ok, material} <- material(config, pin.admission_ref, pin.identity),
         {:ok, required} <-
           Reconciliation.run_obligations(
             material.record.run,
             pin.identity["run_incarnation"],
             material.admission["inventory_ref"]
           ),
         obligations =
           merge_obligations(material.inventory["obligations"], required ++ pin.obligations),
         manifest =
           Evidence.manifest(
             subject(pin.identity),
             [material.run_ref],
             obligations,
             pin.fence_ref
           ),
         {:ok, manifest} <- Evidence.validate_manifest(manifest) do
      {:ok, manifest}
    end
  end

  def manager_manifest(config, pin) do
    Enum.reduce_while(pin.children, {:ok, [], []}, fn child, {:ok, refs, obligations} ->
      case material(config, child.admission_ref, child.identity) do
        {:ok, material} ->
          identity = %{"subject" => subject(child.identity)}

          identity =
            if child.receipt_ref,
              do: Map.put(identity, "receipt_id", child.receipt_ref),
              else: identity

          obligation = Evidence.obligation("child", identity, material.admission["inventory_ref"])
          {:cont, {:ok, refs ++ [material.run_ref], obligations ++ [obligation]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, refs, obligations} ->
        # Child receipts own execution obligations; the manager owns their retirement.
        manifest = Evidence.manifest(pin.subject, refs, obligations, pin.fence_ref)

        # Include run requirements even when a host chooses exact observations instead of receipts.
        add_manager_run_obligations(config, manifest)

      error ->
        error
    end
  end

  defp add_manager_run_obligations(config, manifest) do
    Enum.reduce_while(manifest["run_refs"], {:ok, manifest["obligations"]}, fn ref, {:ok, all} ->
      with {:ok, record} <- Reconciliation.load_record(config, ref),
           {:ok, required} <-
             Reconciliation.run_obligations(
               record.run,
               ref["original_incarnation"],
               manifest["admission_fence_ref"]
             ) do
        {:cont, {:ok, merge_obligations(all, required)}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, obligations} ->
        {:ok,
         Evidence.manifest(
           manifest["subject"],
           manifest["run_refs"],
           obligations,
           manifest["admission_fence_ref"]
         )}

      error ->
        error
    end
  end

  def export(config, pin, receipt_ref) do
    with {:ok, material} <- material(config, pin.admission_ref, pin.identity),
         :ok <- eligible(material.record.run),
         {:ok, receipt} <-
           Reconciliation.load_confirmed(
             config,
             receipt_ref,
             subject(pin.identity),
             pin.manifest["manifest_digest"]
           ),
         :ok <- receipt_record(receipt, material),
         {:ok, history} <- history(material.record.run),
         {:ok, metadata} <- Evidence.public(pin.host_metadata) do
      admission = material.admission

      fields = %{
        "schema_version" => 1,
        "child_identity" => pin.identity,
        "tool_profile" => admission["tool_profile"],
        "admission_ref" => pin.admission_ref,
        "admission_receipt_ref" => admission["admission_receipt_ref"],
        "retirement_receipt_ref" => receipt_ref,
        "retirement_receipt_digest" => receipt["receipt_digest"],
        "manifest_digest" => receipt["manifest_digest"],
        "terminal_record" => terminal(material),
        "messages" => history["messages"],
        "host_feedback" => history["host_feedback"],
        "history_digest" => Evidence.digest(history),
        "remaining_work" => remaining(material.record.run),
        "deadline" => deadline(material.record.run.deadline),
        "child_request" => admission["child_request"],
        "configuration_ref" => admission["config_ref"],
        "configuration_digest" => Evidence.digest(admission["configuration"]),
        "authority_ceiling_ref" => admission["authority_ceiling_ref"],
        "authority_ceiling_digest" => Evidence.digest(admission["authority_ceiling"]),
        "artifact_refs" => admission["artifact_refs"],
        "host_metadata" => metadata
      }

      {:ok,
       fields
       |> Map.put("archive_id", "archive_" <> Evidence.digest(fields))
       |> Evidence.seal("archive_digest")}
    end
  end

  def restore(config, archive) do
    with {:ok, archive} <- validate(archive),
         {:ok, material} <- material(config, archive["admission_ref"], archive["child_identity"]),
         :ok <- eligible(material.record.run),
         {:ok, history} <- history(material.record.run),
         :ok <-
           same(
             terminal(material),
             archive["terminal_record"],
             "archive terminal Store record differs"
           ),
         :ok <-
           same(
             history,
             Map.take(archive, ~w(messages host_feedback)),
             "archive committed history differs"
           ),
         :ok <-
           same(
             remaining(material.record.run),
             archive["remaining_work"],
             "archive remaining budget differs"
           ),
         :ok <-
           same(
             deadline(material.record.run.deadline),
             archive["deadline"],
             "archive deadline differs"
           ),
         :ok <- admission_matches(material.admission, archive),
         {:ok, receipt} <-
           Reconciliation.load_confirmed(
             config,
             archive["retirement_receipt_ref"],
             subject(archive["child_identity"]),
             archive["manifest_digest"]
           ),
         :ok <-
           same(
             receipt["receipt_digest"],
             archive["retirement_receipt_digest"],
             "archive retirement revision differs"
           ),
         :ok <- receipt_record(receipt, material),
         {:ok, ceiling} <- ceiling(material.admission["authority_ceiling"]) do
      {:ok,
       %{
         archive: archive,
         snapshot: snapshot(material.record),
         authority_ceiling: ceiling,
         request: request(material.admission["child_request"])
       }}
    end
  end

  def validate(value) do
    with {:ok, archive} <- Evidence.public(value),
         :ok <- Evidence.fields(archive, @archive_fields, @archive_fields),
         :ok <- Evidence.version(archive),
         :ok <- Evidence.subject(subject(archive["child_identity"])),
         :ok <- Evidence.sealed(archive, "archive_digest"),
         :ok <-
           same(
             archive["archive_id"],
             "archive_" <> Evidence.digest(Map.drop(archive, ~w(archive_id archive_digest))),
             "archive identity differs"
           ),
         :ok <-
           same(
             archive["history_digest"],
             Evidence.digest(Map.take(archive, ~w(messages host_feedback))),
             "archive history digest differs"
           ),
         true <- archive["tool_profile"] in ~w(v1 v2),
         true <- is_integer(archive["remaining_work"]) and archive["remaining_work"] >= 0 do
      {:ok, archive}
    else
      false -> Evidence.invalid("invalid child archive state")
      error -> error
    end
  end

  defp material(config, admission_ref, identity) do
    with :ok <- Evidence.subject(subject(identity)),
         {:ok, admission} <- Reconciliation.load_evidence(config, admission_ref),
         :ok <- Evidence.fields(admission, @admission_fields, @admission_fields),
         :ok <- Evidence.version(admission),
         :ok <-
           same(admission["record_type"], "child_admission", "admission evidence kind differs"),
         :ok <-
           same(admission["child_identity"], identity, "original admission identity differs"),
         :ok <-
           Evidence.each(
             ~w(store_ref config_ref authority_ceiling_ref admission_receipt_ref inventory_ref),
             &Evidence.identifier(admission[&1])
           ),
         true <- admission["tool_profile"] in ~w(v1 v2),
         :ok <- child_request(admission["child_request"], admission["tool_profile"]),
         {:ok, configuration} <- Reconciliation.load_evidence(config, admission["config_ref"]),
         :ok <-
           same(
             configuration,
             admission["configuration"],
             "historical configuration reference differs"
           ),
         {:ok, authority} <-
           Reconciliation.load_evidence(config, admission["authority_ceiling_ref"]),
         :ok <-
           same(
             authority,
             admission["authority_ceiling"],
             "historical authority reference differs"
           ),
         {:ok, _} <- ceiling(authority),
         :ok <- artifacts(config, admission["artifact_refs"]),
         {:ok, inventory} <- Reconciliation.load_evidence(config, admission["inventory_ref"]),
         :ok <- Evidence.fields(inventory, @inventory_fields, @inventory_fields),
         :ok <- Evidence.version(inventory),
         :ok <- same(inventory["record_type"], "child_inventory", "owner inventory kind differs"),
         :ok <- same(inventory["child_identity"], identity, "owner inventory admission differs"),
         :ok <- Evidence.identifier(inventory["producer_ref"]),
         true <- inventory["complete"] == true,
         :ok <- Evidence.each(inventory["obligations"], &Evidence.obligation_shape/1),
         run_ref = %{
           "store_ref" => admission["store_ref"],
           "run_id" => identity["run_id"],
           "original_incarnation" => identity["run_incarnation"]
         },
         {:ok, record} <- Reconciliation.load_record(config, run_ref) do
      {:ok, %{admission: admission, inventory: inventory, record: record, run_ref: run_ref}}
    else
      false ->
        Evidence.invalid("historical admission requires an exact profile and complete inventory")

      error ->
        error
    end
  end

  defp admission_matches(admission, archive) do
    pairs = [
      {"tool_profile", "tool_profile"},
      {"admission_receipt_ref", "admission_receipt_ref"},
      {"child_request", "child_request"},
      {"config_ref", "configuration_ref"},
      {"authority_ceiling_ref", "authority_ceiling_ref"},
      {"artifact_refs", "artifact_refs"}
    ]

    with :ok <-
           Evidence.each(pairs, fn {source, target} ->
             same(admission[source], archive[target], "archive admission/configuration differs")
           end),
         :ok <-
           same(
             Evidence.digest(admission["configuration"]),
             archive["configuration_digest"],
             "archive configuration digest differs"
           ),
         do:
           same(
             Evidence.digest(admission["authority_ceiling"]),
             archive["authority_ceiling_digest"],
             "archive authority digest differs"
           )
  end

  defp receipt_record(receipt, material) do
    record = material.record

    expected =
      Map.merge(material.run_ref, %{
        "current_incarnation" => record.run.incarnation,
        "current_revision" => record.revision
      })

    if Enum.any?(receipt["run_fences"], fn fence ->
         Map.take(fence, Map.keys(expected)) == expected
       end),
       do: :ok,
       else: conflict("retirement receipt does not match current Store fence")
  end

  defp terminal(material) do
    {:ok, outcome} = Evidence.public(Map.get(material.record.run, :outcome))

    Map.merge(material.run_ref, %{
      "current_incarnation" => material.record.run.incarnation,
      "revision" => material.record.revision,
      "historical_outcome" => Atom.to_string(material.record.run.state),
      "outcome" => outcome
    })
  end

  defp history(run) do
    conversation = get_in(run, [:context, :conversation])

    with true <- is_map(conversation),
         true <-
           Enum.all?(
             [:mailbox, :steering, :follow_up, :goal_outbox],
             &(Map.get(conversation, &1, []) == [])
           ),
         true <- is_nil(Map.get(conversation, :pending_interaction)),
         true <- Map.get(conversation, :active_notifications, %{}) == %{},
         {:ok, messages} <- Evidence.public(Map.get(conversation, :messages, [])),
         :ok <- Evidence.each(messages, &message/1),
         {:ok, feedback} <-
           HostFeedback.history(
             messages: Map.get(conversation, :messages, []),
             host_feedback: Map.get(conversation, :host_feedback, [])
           ),
         {:ok, feedback} <- Evidence.public(feedback) do
      {:ok, %{"messages" => messages, "host_feedback" => feedback}}
    else
      false -> conflict("archive has unsettled accepted input or delivery obligations")
      error -> error
    end
  end

  defp message(value) do
    with :ok <- Evidence.fields(value, @message_fields, ["role"]),
         true <- value["role"] in ~w(system developer user assistant tool),
         true <- Map.has_key?(value, "content") or Map.has_key?(value, "result") do
      :ok
    else
      false -> Evidence.invalid("archive contains an unsupported runtime message")
      error -> error
    end
  end

  defp child_request(value, profile) do
    with :ok <-
           Evidence.fields(
             value,
             ~w(profile message task_name options),
             ~w(profile message task_name options)
           ),
         :ok <- same(value["profile"], profile, "historical tool profile differs"),
         :ok <- Evidence.identifier(value["task_name"]),
         true <- is_binary(value["message"]) and is_map(value["options"]) do
      :ok
    else
      false -> Evidence.invalid("invalid historical child request")
      error -> error
    end
  end

  defp request(value),
    do: %{
      profile: if(value["profile"] == "v1", do: :v1, else: :v2),
      message: value["message"],
      task_name: value["task_name"],
      options: value["options"]
    }

  defp ceiling(value) do
    with :ok <-
           Evidence.fields(value, ~w(grants tool_revisions tool_bindings tool_revision), [
             "grants"
           ]),
         :ok <- Evidence.each(value["grants"], &Evidence.identifier/1),
         true <-
           is_map(Map.get(value, "tool_revisions", %{})) and
             is_map(Map.get(value, "tool_bindings", %{})) do
      {:ok,
       %{
         grants: value["grants"],
         tool_revisions: Map.get(value, "tool_revisions", %{}),
         tool_bindings: Map.get(value, "tool_bindings", %{}),
         tool_revision: value["tool_revision"]
       }}
    else
      false -> Evidence.invalid("invalid historical authority ceiling")
      error -> error
    end
  end

  defp artifacts(config, refs) do
    Evidence.each(refs, fn ref ->
      with :ok <- Evidence.identifier(ref),
           {:ok, value} <- Reconciliation.load_evidence(config, ref),
           true <- is_map(value) and value["available"] == true do
        :ok
      else
        false -> conflict("archive artifact no longer resolves")
        error -> error
      end
    end)
  end

  defp eligible(%{state: state}) when state in @eligible, do: :ok
  defp eligible(_), do: conflict("unknown-outcome history cannot continue from an archive")
  defp remaining(run), do: run.execution_budget.quota - run.execution_budget.used
  defp deadline(:infinity), do: "infinity"
  defp deadline(value) when is_integer(value), do: value

  def snapshot(record) do
    conversation = get_in(record.run, [:context, :conversation])

    %{
      run: record.run,
      messages: Map.get(conversation, :messages, []),
      conversation: conversation,
      resource_cleanup: :confirmed
    }
  end

  defp merge_obligations(existing, additions) do
    Enum.reduce(additions, existing, fn value, acc ->
      if Enum.any?(acc, &(&1["kind"] == value["kind"] and &1["identity"] == value["identity"])),
        do: acc,
        else: acc ++ [value]
    end)
  end

  defp same(value, value, _message), do: :ok
  defp same(_, _, message), do: conflict(message)
  defp conflict(message), do: {:error, Error.new(:resource_conflict, message)}
end
