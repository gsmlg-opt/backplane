defmodule Backplane.AgentRuntime.Codex.Reconciliation.HistoricalSource do
  @moduledoc false

  alias Backplane.AgentRuntime.{Error, Kernel}
  alias Backplane.AgentRuntime.Codex.Reconciliation
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

  @fields ~w(schema_version subject source root_agent_id authority root_admission_ref executor_ref provider_refs host_refs managers)
  @provider_fields ~w(run_id incarnation step_id attempt_id)a
  @tool_fields @provider_fields ++ [:invocation_id]
  @host_identity ~w(root_header_id transcript_header_id child_session_id host_lifetime_id)
  @binding_fields @host_identity ++
                    ~w(run_id run_incarnation native_owner_id native_session_incarnation)

  def load(config, request) do
    with {:ok, evidence} <- Reconciliation.load_evidence(config, request["evidence_ref"]),
         :ok <- Evidence.fields(evidence, @fields, @fields),
         :ok <- Evidence.version(evidence),
         :ok <-
           check(
             Map.take(evidence, ~w(subject source root_agent_id)) ===
               Map.take(request, ~w(subject source root_agent_id)),
             "source_identity"
           ),
         {:ok, record} <-
           Reconciliation.historical_continuation_record(
             config,
             request["source"],
             evidence["authority"]
           ),
         :ok <- original_work(record, request["source"]),
         :ok <- admission(config, request, evidence),
         :ok <- executor(config, request, evidence),
         :ok <- providers(config, record.run, evidence),
         :ok <- hosts(config, request, evidence),
         :ok <- managers(config, request, evidence),
         {:ok, ^record} <-
           Reconciliation.historical_continuation_record(
             config,
             request["source"],
             evidence["authority"]
           ) do
      {:ok, record.run, evidence}
    else
      {:error, _} = error -> error
      {:ok, _} -> conflict("historical Store changed before continuation acceptance")
    end
  end

  defp original_work(%{run: run} = record, source) do
    intents = Map.get(run, :execution_intents)
    results = Map.get(run, :tool_results)
    tools = Map.get(run, :active_tools)
    attempts = Map.get(run, :provider_attempts)
    work = Kernel.cleanup_requirements(run)

    with :ok <- check(is_map(intents) and is_map(results) and is_map(tools), "tool_inventory"),
         :ok <- check(is_map(attempts) and map_size(attempts) > 0, "provider_inventory"),
         :ok <-
           check(
             is_nil(work.provider) and work.children == [] and work.dependencies == [] and
               is_nil(run[:active_wait]) and record.effects == [],
             "independent_work"
           ),
         :ok <-
           check(
             Enum.all?(attempts, fn {attempt_id, operation} ->
               original?(operation, source) and operation[:attempt_id] == attempt_id
             end),
             "provider_generation"
           ),
         :ok <-
           check(
             Enum.all?(Map.values(intents), &original_intent?(&1, source, tools, results)),
             "execution_intents"
           ),
         :ok <-
           check(
             map_size(tools) > 0 and
               Enum.all?(tools, fn {id, operation} ->
                 intent = intents["tool:#{id}"]

                 original?(operation, source) and operation[:invocation_id] == id and
                   is_map(intent) and is_map(intent[:operation]) and
                   Map.take(intent.operation, @tool_fields) === Map.take(operation, @tool_fields) and
                   intent[:status] in [:started, :uncertain] and not Map.has_key?(results, id)
               end),
             "lost_tool_inventory"
           ),
         :ok <-
           check(
             Enum.all?(record.outbox, fn intent ->
               intent[:type] == :tool and intent[:status] in [:started, :uncertain] and
                 is_map(intent[:operation]) and
                 intents["tool:#{intent.operation[:invocation_id]}"] === intent
             end),
             "outbox"
           ) do
      :ok
    end
  end

  defp original_intent?(
         %{type: type, status: status, operation: operation},
         source,
         _tools,
         _results
       )
       when type in [:provider, :tool] and status in [:consumed, :cancelled],
       do: original?(operation, source)

  defp original_intent?(
         %{type: :tool, status: status, operation: operation},
         source,
         tools,
         results
       )
       when status in [:started, :uncertain] do
    original?(operation, source) and Map.has_key?(tools, operation[:invocation_id]) and
      not Map.has_key?(results, operation[:invocation_id])
  end

  defp original_intent?(_intent, _source, _tools, _results), do: false

  defp original?(%{run_id: run_id, incarnation: incarnation}, source),
    do: run_id == source["run_id"] and incarnation == source["original_incarnation"]

  defp original?(_operation, _source), do: false

  defp admission(config, request, evidence) do
    source = request["source"]

    expected = %{
      "run_id" => source["run_id"],
      "incarnation" => source["original_incarnation"],
      "store_ref" => source["store_ref"]
    }

    with {:ok, fact} <- fact(config, evidence["root_admission_ref"]),
         do: check(fact === expected, "root_admission")
  end

  defp executor(config, request, evidence) do
    source = request["source"]

    expected = %{
      "run_id" => source["run_id"],
      "incarnation" => source["original_incarnation"],
      "status" => "stopped",
      "reason" => ":normal"
    }

    with {:ok, fact} <- fact(config, evidence["executor_ref"]),
         do: check(fact === expected, "executor")
  end

  defp providers(config, run, evidence) do
    with {:ok, facts} <- facts(config, evidence["provider_refs"], "provider_inventory"),
         :ok <- Evidence.each(facts, &provider/1),
         :ok <- Evidence.unique(facts, & &1["identity"]),
         {:ok, expected} <- Evidence.public(Map.values(run.provider_attempts)),
         :ok <-
           check(
             MapSet.new(Enum.map(facts, & &1["identity"])) === MapSet.new(expected),
             "provider_inventory"
           ) do
      :ok
    end
  end

  defp provider(fact) do
    fields = ~w(identity status exit_kind observer)
    identity_fields = Enum.map(@provider_fields, &Atom.to_string/1)

    with :ok <- Evidence.fields(fact, fields, fields),
         :ok <- Evidence.fields(fact["identity"], identity_fields, identity_fields),
         :ok <-
           Evidence.each(
             ~w(run_id step_id attempt_id),
             &Evidence.identifier(fact["identity"][&1])
           ),
         :ok <- Evidence.positive(fact["identity"]["incarnation"]),
         :ok <- Evidence.identifier(fact["exit_kind"]),
         :ok <- Evidence.identifier(fact["observer"]),
         do: check(fact["status"] == "stopped", "provider")
  end

  defp hosts(config, request, evidence) do
    with {:ok, hosts} <- facts(config, evidence["host_refs"], "host_inventory"),
         :ok <- Evidence.each(hosts, &host(&1, request)),
         do: Evidence.unique(hosts, &get_in(&1, ["identity", "host_lifetime_id"]))
  end

  defp host(host, request) do
    fields = ~w(identity bindings native async_hooks session_end)
    identity = host["identity"]
    scope = request["subject"]["scope_id"]

    with :ok <- Evidence.fields(host, fields, fields),
         :ok <- Evidence.fields(identity, @host_identity, @host_identity),
         :ok <- Evidence.identifier(identity["host_lifetime_id"]),
         :ok <-
           check(
             identity["root_header_id"] == scope and identity["transcript_header_id"] == scope and
               is_nil(identity["child_session_id"]),
             "host_scope"
           ),
         :ok <- Evidence.each(host["bindings"], &binding(&1, identity)),
         :ok <-
           Evidence.unique(host["bindings"], fn binding ->
             Map.take(
               binding,
               ~w(run_id run_incarnation native_owner_id native_session_incarnation)
             )
           end),
         :ok <-
           check(Enum.any?(host["bindings"], &source_binding?(&1, request)), "source_binding"),
         :ok <-
           check(
             Enum.all?(host["bindings"], fn binding ->
               binding["run_id"] != request["source"]["run_id"] or
                 source_binding?(binding, request)
             end),
             "source_binding"
           ),
         :ok <- Evidence.each(host["native"], &native/1),
         :ok <- Evidence.unique(host["native"], &Map.take(&1, ~w(owner_id session_incarnation))),
         :ok <-
           check(
             Enum.all?(host["bindings"], fn binding ->
               Enum.any?(host["native"], fn native ->
                 native["owner_id"] == binding["native_owner_id"] and
                   native["session_incarnation"] == binding["native_session_incarnation"]
               end)
             end),
             "native"
           ),
         :ok <- check(host["async_hooks"] === %{"status" => "confirmed"}, "async_hooks"),
         :ok <-
           Evidence.fields(
             host["session_end"],
             ~w(status dispatch outcome warnings),
             ~w(status dispatch outcome warnings)
           ),
         :ok <-
           check(
             host["session_end"]["status"] == "confirmed" and
               host["session_end"]["dispatch"] == "completed" and
               is_list(host["session_end"]["warnings"]),
             "session_end"
           ) do
      :ok
    end
  end

  defp binding(binding, host_identity) do
    with :ok <- Evidence.fields(binding, @binding_fields, @binding_fields),
         :ok <- check(Map.take(binding, @host_identity) === host_identity, "binding_scope"),
         :ok <- Evidence.identifier(binding["run_id"]),
         :ok <- Evidence.positive(binding["run_incarnation"]),
         :ok <- Evidence.identifier(binding["native_owner_id"]),
         do: Evidence.positive(binding["native_session_incarnation"])
  end

  defp source_binding?(binding, request) do
    binding["run_id"] == request["source"]["run_id"] and
      binding["run_incarnation"] == request["source"]["original_incarnation"] and
      binding["native_owner_id"] == request["subject"]["owner_id"] and
      binding["native_session_incarnation"] == request["subject"]["incarnation"]
  end

  defp native(native) do
    fields = ~w(status owner_id session_incarnation)

    with :ok <- Evidence.fields(native, fields, fields),
         :ok <- Evidence.identifier(native["owner_id"]),
         :ok <- Evidence.positive(native["session_incarnation"]),
         do: check(native["status"] == "confirmed", "native")
  end

  defp managers(config, request, evidence) do
    entries = evidence["managers"]

    with :ok <- check(is_list(entries) and entries != [], "manager_inventory"),
         :ok <- Evidence.unique(entries, & &1["receipt_id"]),
         {:ok, ids} <- collect(entries, &manager(config, request, &1)),
         do: Evidence.unique(ids, & &1)
  end

  defp manager(config, request, entry) do
    fields = ~w(receipt_id acknowledgement_ref)

    with :ok <- Evidence.fields(entry, fields, fields),
         :ok <- Evidence.identifier(entry["receipt_id"]),
         {:ok, receipt} <- Reconciliation.load_receipt(config, entry["receipt_id"]),
         subject = receipt["subject"],
         :ok <-
           check(
             subject["kind"] == "manager" and
               subject["scope_id"] == request["subject"]["scope_id"] and
               subject["root_agent_id"] == request["root_agent_id"],
             "manager_scope"
           ),
         {:ok, ^receipt} <- Reconciliation.load_confirmed(config, entry["receipt_id"], subject),
         {:ok, acknowledgement} <- fact(config, entry["acknowledgement_ref"]),
         :ok <-
           check(
             acknowledgement === %{
               "manager_id" => subject["manager_id"],
               "receipt_id" => receipt["receipt_id"],
               "receipt_digest" => receipt["receipt_digest"],
               "revision" => receipt["revision"],
               "status" => "confirmed"
             },
             "manager_acknowledgement"
           ) do
      {:ok, subject["manager_id"]}
    else
      {:error, _} = error -> error
      {:ok, _} -> conflict("manager receipt changed before continuation acceptance")
    end
  end

  defp facts(config, references, component) do
    with :ok <- check(is_list(references) and references != [], component),
         :ok <- Evidence.unique(references, & &1),
         do: collect(references, &fact(config, &1))
  end

  defp fact(config, reference) do
    with :ok <- Evidence.identifier(reference),
         do: Reconciliation.load_evidence(config, reference)
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp check(true, _component), do: :ok

  defp check(false, component),
    do:
      {:error,
       Error.new(:unknown_outcome, "historical continuation component is unconfirmed",
         details: %{component: component}
       )}

  defp conflict(message), do: {:error, Error.new(:resource_conflict, message)}
end
