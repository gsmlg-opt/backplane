defmodule Backplane.AgentRuntime.Codex.Reconciliation.Continuation do
  @moduledoc """
  Records an explicit host decision to admit fresh root work on the same thread.

  The decision binds trusted closure or independent isolation evidence to the
  original run. Unknown outcomes and unresolved effects are retained. See
  PERSISTENCE.md for the host contract.
  """

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Codex.Reconciliation
  alias Backplane.AgentRuntime.Codex.Reconciliation.{Evidence, HistoricalSource, ProviderLoss}

  @request_fields ~w(schema_version subject source receipt_id closure_evidence_ref instruction_ref)
  @historical_request_fields ~w(schema_version mode subject source root_agent_id evidence_ref instruction_ref)
  @components %{
    "root_admission" => "admitted",
    "local_execution" => "stopped",
    "async_hooks" => "closed",
    "session_end" => "closed"
  }
  @notice "A tool from an earlier turn has no recorded result. Its outcome is unknown. " <>
            "Do not assume it succeeded or failed, and do not repeat that action implicitly."

  @doc "Persist or read back the exact continuation decision before admitting its fresh run."
  def prepare(config, request) do
    Reconciliation.bounded(fn ->
      with :ok <- durable_adapter(config),
           {:ok, request} <- validate_request(request) do
        source = Map.take(request["source"], ~w(run_id original_incarnation))
        id = "continuation_" <> Evidence.digest(%{subject: request["subject"], source: source})
        prepare_decision(config, request, id)
      end
    end)
  end

  defp durable_adapter({module, _}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :mode, 0) and
         function_exported?(module, :load_continuation, 2) and
         function_exported?(module, :compare_and_create_continuation, 3) and
         module.mode() == :durable,
       do: :ok,
       else: durable_adapter(nil)
  end

  defp durable_adapter(_) do
    {:error,
     Error.new(:unsupported_capability, "continuation requires a durable recovery adapter")}
  end

  defp validate_request(raw) do
    with {:ok, request} <- Evidence.public(raw),
         :ok <- request_fields(request),
         :ok <- Evidence.version(request),
         :ok <- Evidence.subject(request["subject"]),
         %{"kind" => "session"} <- request["subject"],
         :ok <- Evidence.run_ref(request["source"]) do
      {:ok, request}
    else
      {:error, _} = error -> error
      _ -> Evidence.invalid("continuation requires the original root Session identity")
    end
  end

  defp request_fields(%{"mode" => mode} = request)
       when mode in ~w(historical_owner_loss isolated_provider_loss) do
    with :ok <- Evidence.fields(request, @historical_request_fields, @historical_request_fields),
         do:
           Evidence.each(~w(root_agent_id evidence_ref instruction_ref), fn field ->
             Evidence.identifier(request[field])
           end)
  end

  defp request_fields(request) do
    with :ok <- Evidence.fields(request, @request_fields, @request_fields),
         do:
           Evidence.each(~w(receipt_id closure_evidence_ref instruction_ref), fn field ->
             Evidence.identifier(request[field])
           end)
  end

  defp prepare_decision(config, request, id) do
    case load_decision(config, request, id) do
      {:error, %Error{class: :not_found}} -> create_decision(config, request, id)
      result -> result
    end
  end

  defp create_decision(config, %{"mode" => "historical_owner_loss"} = request, id) do
    with {:ok, run, evidence} <- HistoricalSource.load(config, request),
         {:ok, tools} <- missing_tools(run, request["source"]) do
      outcome = %{
        "run_id" => run.run_id,
        "state" => Atom.to_string(run.state),
        "outcome_digest" => Evidence.outcome_digest(run[:outcome])
      }

      decision =
        decision_fields(request, id, outcome, tools)
        |> Map.merge(%{
          "mode" => "historical_owner_loss",
          "root_agent_id" => request["root_agent_id"],
          "evidence_ref" => request["evidence_ref"],
          "evidence_digest" => Evidence.digest(evidence),
          "historical_limits" => %{
            "original_session_inventory" => "unavailable",
            "original_registry_inventory" => "unavailable",
            "lost_tool_outcomes" => "unknown"
          }
        })
        |> Evidence.seal("decision_digest")

      persist(config, request, id, decision)
    end
  end

  defp create_decision(config, %{"mode" => "isolated_provider_loss"} = request, id) do
    with {:ok, fields} <- ProviderLoss.load(config, request) do
      decision =
        request
        |> decision_fields(id, fields["historical_outcome"], [])
        |> Map.merge(fields)
        |> Evidence.seal("decision_digest")

      persist(config, request, id, decision)
    end
  end

  defp create_decision(config, request, id) do
    with {:ok, receipt, %{state: :unknown_outcome} = run, facts} <-
           Reconciliation.continuation_source(config, request),
         {:ok, tools} <- lost_results(run, receipt, request["source"], facts),
         {:ok, proof} <- Reconciliation.load_evidence(config, request["closure_evidence_ref"]),
         :ok <- validate_closure(proof, request, receipt) do
      decision = build_decision(request, id, receipt, proof, tools)
      persist(config, request, id, decision)
    else
      {:ok, _, _, _} -> uncertain("continuation requires a terminal unknown outcome")
      {:error, _} = error -> error
    end
  end

  defp lost_results(run, receipt, source, facts) do
    with {:ok, tools} <- missing_tools(run, source),
         :ok <-
           Evidence.each(
             receipt["pending"] ++ receipt["unresolved_effects"],
             &lost_tool(&1, tools)
           ),
         :ok <- Evidence.each(receipt["satisfied"], &confirmed_stop(&1, facts, tools)) do
      {:ok, tools}
    end
  end

  defp missing_tools(run, source) do
    intents = Map.get(run, :execution_intents, %{})

    tools =
      for %{type: :tool, status: status, operation: operation} <- Map.values(intents),
          status in [:started, :uncertain],
          operation.incarnation == source["original_incarnation"],
          not Map.has_key?(Map.get(run, :tool_results, %{}), operation.invocation_id) do
        fields =
          ~w(run_id incarnation step_id attempt_id invocation_id tool_call_id tool_name enclosing_invocation_id)a

        {:ok, identity} = operation |> Map.take(fields) |> Evidence.public()
        identity
      end

    with [_ | _] <- tools,
         :ok <- Evidence.each(tools, &Evidence.identifier(&1["invocation_id"])),
         :ok <- Evidence.unique(tools, & &1["invocation_id"]) do
      {:ok, Enum.sort_by(tools, & &1["invocation_id"])}
    else
      [] -> uncertain("the original run has no missing tool result")
      {:error, _} = error -> error
    end
  end

  defp lost_tool(%{"kind" => "tool", "identity" => identity}, tools) do
    if Enum.any?(tools, &matches_tool?(identity, &1)),
      do: :ok,
      else: uncertain("an unresolved tool differs from the original lost invocation")
  end

  defp lost_tool(_, _), do: uncertain("a non-tool lifetime obligation remains pending")

  defp confirmed_stop(%{"kind" => kind} = obligation, facts, _)
       when kind in ~w(provider executor) do
    case observation(facts, obligation) do
      %{"result" => "stopped"} -> :ok
      _ -> uncertain("an Executor or Provider stop is unconfirmed")
    end
  end

  defp confirmed_stop(%{"kind" => "tool", "identity" => identity} = obligation, facts, tools) do
    if match?(%{"result" => "not_started"}, observation(facts, obligation)) and
         Enum.any?(tools, &matches_tool?(identity, &1)) do
      uncertain("not_started conflicts with the original tool intent")
    else
      :ok
    end
  end

  defp confirmed_stop(_, _, _), do: :ok

  defp observation(facts, obligation),
    do: Enum.find(facts, &(&1["obligation_id"] == obligation["obligation_id"]))

  defp matches_tool?(identity, tool) do
    fields = ~w(run_id incarnation step_id attempt_id invocation_id)
    Map.take(identity, fields) === Map.take(tool, fields)
  end

  defp validate_closure(proof, request, receipt) do
    fields = ~w(schema_version subject source receipt_digest components)
    components = proof["components"]

    with :ok <- Evidence.fields(proof, fields, fields),
         :ok <- Evidence.version(proof),
         true <- Map.take(proof, ~w(subject source)) === Map.take(request, ~w(subject source)),
         true <- proof["receipt_digest"] === receipt["receipt_digest"],
         :ok <- Evidence.fields(components, Map.keys(@components), Map.keys(@components)),
         :ok <- Evidence.each(Map.to_list(@components), &component(components, &1)),
         :ok <- Evidence.unique(Map.values(components), & &1["source_ref"]) do
      :ok
    else
      false -> conflict("continuation closure evidence refers to another source or receipt")
      {:error, _} = error -> error
    end
  end

  defp component(components, {name, status}) do
    fact = components[name]

    with :ok <- Evidence.fields(fact, ~w(status source_ref), ~w(status source_ref)),
         ^status <- fact["status"],
         :ok <- Evidence.identifier(fact["source_ref"]) do
      :ok
    else
      {:error, _} = error -> error
      _ -> uncertain("continuation component closure is unconfirmed", %{component: name})
    end
  end

  defp build_decision(request, id, receipt, proof, tools) do
    outcome =
      Enum.find(receipt["historical_outcomes"], &(&1["run_id"] == request["source"]["run_id"]))

    decision_fields(request, id, outcome, tools)
    |> Map.merge(%{
      "receipt_id" => request["receipt_id"],
      "receipt_digest" => receipt["receipt_digest"],
      "closure_evidence_ref" => request["closure_evidence_ref"],
      "closure_evidence_digest" => Evidence.digest(proof)
    })
    |> Evidence.seal("decision_digest")
  end

  defp decision_fields(request, id, outcome, tools) do
    %{
      "schema_version" => 1,
      "continuation_id" => id,
      "subject" => request["subject"],
      "source" => request["source"],
      "target" => %{request["source"] | "run_id" => "run_" <> id, "original_incarnation" => 1},
      "instruction_ref" => request["instruction_ref"],
      "historical_outcome" => outcome,
      "unresolved_tools" => tools,
      "model_notice" => @notice,
      "request_digest" => Evidence.digest(request)
    }
  end

  defp persist({module, context} = config, request, id, decision) do
    case module.compare_and_create_continuation(context, id, decision) do
      {:ok, ^decision} -> {:ok, decision}
      _ -> read_back(config, request, id)
    end
  end

  defp read_back(config, request, id) do
    case load_decision(config, request, id) do
      {:ok, _} = result ->
        result

      {:error, %Error{class: :resource_conflict}} = error ->
        error

      _ ->
        uncertain("continuation persistence acknowledgement is unknown", %{continuation_id: id})
    end
  end

  defp load_decision({module, context} = config, request, id) do
    with {:ok, raw} <- module.load_continuation(context, id),
         {:ok, decision} <- Evidence.public(raw),
         :ok <- Evidence.sealed(decision, "decision_digest"),
         true <- decision["continuation_id"] === id,
         true <- decision["request_digest"] === Evidence.digest(request),
         :ok <- current_isolation(config, request, decision) do
      {:ok, decision}
    else
      false -> conflict("a different continuation decision already owns the source run")
      {:error, %Error{}} = error -> error
      _ -> uncertain("continuation storage returned an invalid acknowledgement")
    end
  end

  defp current_isolation(config, %{"mode" => "isolated_provider_loss"} = request, decision) do
    with {:ok, fields} <- ProviderLoss.load(config, request) do
      if Map.take(decision, Map.keys(fields)) === fields,
        do: :ok,
        else: conflict("durable continuation no longer matches the verified isolation")
    end
  end

  defp current_isolation(_, _, _), do: :ok

  defp conflict(message), do: {:error, Error.new(:resource_conflict, message)}

  defp uncertain(message, details \\ %{}),
    do: {:error, Error.new(:unknown_outcome, message, details: details)}
end
