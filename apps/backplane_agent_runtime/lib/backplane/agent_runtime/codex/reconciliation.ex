defmodule Backplane.AgentRuntime.Codex.Reconciliation do
  @moduledoc """
  Explicit, observation-only reconciliation of fenced runtime lifetimes.

  The configured host adapter owns exclusivity, immutable evidence and receipt
  persistence. This module never executes effects, changes a run, or calls a
  cleanup callback. Receipts certify lifetime closure separately from outcomes.
  """

  alias Backplane.AgentRuntime.{Error, Kernel, Store}
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

  @callbacks [
    mode: 0,
    load_evidence: 2,
    runtime_store: 2,
    load_receipt: 2,
    compare_and_swap_receipt: 4
  ]
  @terminal [:completed, :failed, :cancelled, :timed_out, :unknown_outcome]
  @bundle_fields ~w(schema_version manifest admission_fence inventory observations run_fences policy_records archives artifacts)
  @request_fields ~w(schema_version receipt_id expected_revision subject evidence_ref)

  @doc "Validate opt-in host configuration without invoking host callbacks."
  def validate_options(opts) do
    case {Keyword.get(opts, :recovery), Keyword.get(opts, :recovery_scope_id)} do
      {nil, nil} ->
        :ok

      {{module, _context}, scope} when is_atom(module) ->
        with :ok <- Evidence.identifier(scope), do: adapter_module(module)

      _ ->
        Evidence.invalid("recovery requires an adapter and a nonempty recovery_scope_id")
    end
  end

  @doc "Run host work under a bounded, temporary supervised task."
  def bounded(fun, timeout \\ 5_000) when is_function(fun, 0) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      task = Task.Supervisor.async_nolink(supervisor, fn -> safe(fun) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> uncertain("recovery worker did not acknowledge completion")
      end
    after
      Supervisor.stop(supervisor, :normal)
    end
  end

  def reconcile(config, request), do: bounded(fn -> do_reconcile(config, request) end)

  @doc "Read bounded JSON evidence without performing recovery effects."
  def load_evidence(config, reference) do
    bounded(fn ->
      with :ok <- adapter(config),
           :ok <- Evidence.identifier(reference),
           {:ok, value} <- invoke(config, :load_evidence, [reference]),
           do: Evidence.public(value)
    end)
  end

  @doc "Load a current authoritative terminal Store record through a trusted reference."
  def load_record(config, reference), do: bounded(fn -> record(config, reference) end)

  @doc false
  def load_receipt(config, reference) do
    bounded(fn ->
      with :ok <- adapter(config),
           :ok <- Evidence.identifier(reference),
           do: receipt(config, reference)
    end)
  end

  @doc false
  def run_obligations(run, original_incarnation, provenance_ref) do
    {:ok,
     Enum.map(required_obligations(run, original_incarnation), fn {kind, identity} ->
       Evidence.obligation(kind, identity, provenance_ref)
     end)
     |> Enum.uniq_by(&{&1["kind"], &1["identity"]})}
  end

  @doc "Read an exact confirmed receipt for projection into a fenced controller."
  def load_confirmed(config, reference, subject, manifest_digest \\ nil) do
    bounded(fn ->
      with :ok <- adapter(config),
           :ok <- Evidence.identifier(reference),
           {:ok, subject} <- Evidence.public(subject),
           {:ok, receipt} <- receipt(config, reference),
           :ok <- same(receipt["subject"], subject, "receipt subject differs"),
           :ok <- optional_digest(receipt, manifest_digest),
           {:ok, ^receipt} <- receipt_result(receipt),
           :ok <- receipt_authority(config, receipt) do
        {:ok, receipt}
      end
    end)
  end

  defp receipt_authority(config, receipt) do
    Evidence.each(receipt["run_fences"], fn fence ->
      reference = Map.take(fence, ~w(store_ref run_id original_incarnation))

      with {:ok, current} <- record(config, reference),
           :ok <-
             same(current.revision, fence["current_revision"], "receipt Store revision is stale"),
           :ok <-
             same(
               current.run.incarnation,
               fence["current_incarnation"],
               "receipt Store incarnation is stale"
             ) do
        outcome =
          Enum.find(receipt["historical_outcomes"], &(&1["run_id"] == reference["run_id"]))

        expected = %{
          "run_id" => current.run.run_id,
          "state" => to_string(current.run.state),
          "outcome_digest" => Evidence.digest(current.run[:outcome])
        }

        same(outcome, expected, "receipt historical outcome differs from Store")
      end
    end)
  end

  defp do_reconcile(config, request) do
    with :ok <- adapter(config),
         {:ok, request} <- request(request),
         {:ok, previous} <- previous_receipt(config, request) do
      if previous && previous["accepted_request_digest"] == Evidence.digest(request) do
        receipt_result(previous)
      else
        reconcile_revision(config, request, previous)
      end
    end
  end

  defp reconcile_revision(config, request, previous) do
    with :ok <- expected_revision(previous, request),
         {:ok, raw} <- invoke(config, :load_evidence, [request["evidence_ref"]]),
         {:ok, bundle} <- Evidence.public(raw),
         {:ok, manifest} <- validate_bundle(bundle, request),
         :ok <- same_manifest(previous, manifest),
         :ok <- immutable_observations(config, previous, bundle),
         {:ok, records} <- records(config, manifest["run_refs"]),
         {:ok, fences} <- run_fences(records, manifest, bundle),
         :ok <- run_inventory(records, manifest),
         {:ok, progress} <- observations(config, manifest["obligations"], bundle),
         :ok <- monotonic_progress(previous, progress),
         :ok <- recheck_records(config, manifest["run_refs"], records) do
      next = build_receipt(request, previous, bundle, manifest, records, fences, progress)
      persist(config, request, next)
    end
  end

  defp request(value) do
    with {:ok, value} <- Evidence.public(value),
         :ok <- Evidence.fields(value, @request_fields, @request_fields),
         :ok <- Evidence.version(value),
         :ok <- Evidence.identifier(value["receipt_id"]),
         :ok <- Evidence.identifier(value["evidence_ref"]),
         :ok <- Evidence.subject(value["subject"]),
         true <- is_integer(value["expected_revision"]) and value["expected_revision"] >= 0 do
      {:ok, value}
    else
      false -> Evidence.invalid("expected receipt revision must be nonnegative")
      error -> error
    end
  end

  defp previous_receipt(config, request) do
    case receipt(config, request["receipt_id"]) do
      {:ok, previous} ->
        with :ok <-
               same(
                 previous["subject"],
                 request["subject"],
                 "receipt ID belongs to another subject"
               ),
             do: {:ok, previous}

      {:error, %Error{class: :not_found}} ->
        {:ok, nil}

      error ->
        error
    end
  end

  defp receipt(config, id) do
    with {:ok, value} <- invoke(config, :load_receipt, [id]),
         {:ok, value} <- Evidence.validate_receipt(value),
         :ok <- same(value["receipt_id"], id, "receipt ID differs"),
         do: {:ok, value}
  end

  defp expected_revision(previous, request) do
    revision = if previous, do: previous["revision"], else: 0

    if revision == request["expected_revision"],
      do: :ok,
      else: conflict("stale receipt revision", %{current_revision: revision})
  end

  defp validate_bundle(bundle, request) do
    with :ok <- Evidence.fields(bundle, @bundle_fields, @bundle_fields),
         :ok <- Evidence.version(bundle),
         {:ok, manifest} <- Evidence.validate_manifest(bundle["manifest"]),
         :ok <- same(manifest["subject"], request["subject"], "evidence subject differs"),
         :ok <- admission_fence(bundle["admission_fence"], manifest),
         :ok <- inventory(bundle["inventory"], manifest),
         :ok <- dag(manifest["obligations"]),
         true <- is_list(bundle["observations"]) and is_list(bundle["run_fences"]),
         true <- Enum.all?(~w(policy_records archives artifacts), &is_map(bundle[&1])) do
      {:ok, manifest}
    else
      false -> Evidence.invalid("invalid recovery evidence collections")
      error -> error
    end
  end

  defp admission_fence(fence, manifest) do
    fields = ~w(reference subject manifest_digest revision exclusive producer_ref)

    with :ok <- Evidence.fields(fence, fields, fields),
         :ok <- Evidence.positive(fence["revision"]),
         :ok <- Evidence.identifier(fence["producer_ref"]),
         :ok <-
           same(fence["reference"], manifest["admission_fence_ref"], "admission fence differs"),
         :ok <- same(fence["subject"], manifest["subject"], "admission owner differs"),
         :ok <-
           same(
             fence["manifest_digest"],
             manifest["manifest_digest"],
             "admission inventory differs"
           ) do
      if fence["exclusive"] == true,
        do: :ok,
        else: uncertain("exclusive recovery authority is missing")
    end
  end

  defp inventory(inventory, manifest) do
    fields = ~w(manifest_digest revision producer_ref complete obligations)

    with :ok <- Evidence.fields(inventory, fields, fields),
         :ok <- Evidence.positive(inventory["revision"]),
         :ok <- Evidence.identifier(inventory["producer_ref"]),
         :ok <-
           same(
             inventory["manifest_digest"],
             manifest["manifest_digest"],
             "effect inventory differs"
           ),
         :ok <-
           same(
             inventory["obligations"],
             manifest["obligations"],
             "effect inventory is incomplete"
           ) do
      if inventory["complete"] == true,
        do: :ok,
        else: uncertain("host inventory is not sealed and complete")
    end
  end

  defp same_manifest(nil, _), do: :ok

  defp same_manifest(previous, manifest),
    do: optional_digest(previous, manifest["manifest_digest"])

  defp immutable_observations(_, nil, _), do: :ok

  defp immutable_observations(config, previous, bundle) do
    with {:ok, raw} <- invoke(config, :load_evidence, [previous["evidence_ref"]]),
         {:ok, old} <- Evidence.public(raw),
         :ok <-
           same(
             Evidence.digest(old),
             previous["evidence_digest"],
             "previous evidence is no longer immutable"
           ) do
      if Enum.all?(old["observations"], &(&1 in bundle["observations"])),
        do: :ok,
        else: conflict("recovery progress retracts a component observation")
    end
  end

  defp monotonic_progress(nil, _), do: :ok

  defp monotonic_progress(previous, progress) do
    if Enum.all?(previous["satisfied"], &(&1 in progress.satisfied)),
      do: :ok,
      else: conflict("recovery progress retracts a satisfied obligation")
  end

  defp optional_digest(_, nil), do: :ok

  defp optional_digest(receipt, digest),
    do: same(receipt["manifest_digest"], digest, "receipt manifest differs")

  defp record(config, reference) do
    with :ok <- adapter(config),
         {:ok, reference} <- Evidence.public(reference),
         :ok <- Evidence.run_ref(reference),
         {:ok, resolution} <- invoke(config, :runtime_store, [reference["store_ref"]]),
         {:ok, impl, context} <- store_resolution(resolution),
         {:ok, mode} <- Store.validate_mode(impl),
         {:ok, _} <- store_capabilities(impl, mode),
         {:ok, record} <- impl.load(context, reference["run_id"], []),
         :ok <- validate_record(record, reference) do
      {:ok, record}
    end
  end

  defp store_resolution({impl, context}) when is_atom(impl), do: {:ok, impl, context}

  defp store_resolution(_),
    do: Evidence.invalid("runtime_store must return a Store implementation and context")

  defp store_capabilities(impl, :durable), do: Store.validate_durable_capabilities(impl)
  defp store_capabilities(impl, :ephemeral), do: Store.validate_capabilities(impl)

  defp validate_record(%{run: run, revision: revision}, reference) when is_map(run) do
    cond do
      run[:run_id] != reference["run_id"] ->
        conflict("authoritative run ID differs")

      not is_integer(revision) or revision <= 0 or run[:expected_revision] != revision ->
        conflict("authoritative Store revision differs")

      not is_integer(run[:incarnation]) or run.incarnation < reference["original_incarnation"] ->
        conflict("authoritative run incarnation is stale")

      run[:state] not in @terminal ->
        uncertain("authoritative run is not terminal")

      true ->
        :ok
    end
  end

  defp validate_record(_, _), do: Evidence.invalid("Store returned an invalid recovery record")

  defp records(config, references) do
    collect(references, fn reference -> record(config, reference) end)
  end

  defp recheck_records(config, references, records) do
    with {:ok, current} <- records(config, references),
         do: same(current, records, "Store authority changed before receipt persistence")
  end

  defp run_fences(records, manifest, bundle) do
    Enum.zip(manifest["run_refs"], records)
    |> collect(fn {reference, record} ->
      run = record.run
      chain = Enum.filter(bundle["run_fences"], &(&1["run_id"] == reference["run_id"]))

      with :ok <-
             fence_chain(
               chain,
               reference["original_incarnation"],
               run.incarnation,
               record.revision
             ) do
        {:ok,
         %{
           "store_ref" => reference["store_ref"],
           "run_id" => run.run_id,
           "original_incarnation" => reference["original_incarnation"],
           "current_incarnation" => run.incarnation,
           "current_revision" => record.revision,
           "chain" => chain
         }}
      end
    end)
  end

  defp fence_chain([], incarnation, incarnation, _), do: :ok
  defp fence_chain([], _, _, _), do: uncertain("authoritative recovery fence chain is missing")

  defp fence_chain(chain, original, current, revision) do
    fields = ~w(run_id from_incarnation to_incarnation from_revision to_revision source_ref)

    Enum.reduce_while(chain, {:ok, original, 0}, fn fence,
                                                    {:ok, incarnation, previous_revision} ->
      with :ok <- Evidence.fields(fence, fields, fields),
           :ok <- Evidence.identifier(fence["source_ref"]),
           true <- fence["from_incarnation"] == incarnation,
           true <- is_integer(fence["to_incarnation"]) and fence["to_incarnation"] > incarnation,
           true <-
             is_integer(fence["from_revision"]) and fence["from_revision"] >= previous_revision,
           true <-
             fence["to_revision"] == fence["from_revision"] + 1 and
               fence["to_revision"] <= revision do
        {:cont, {:ok, fence["to_incarnation"], fence["to_revision"]}}
      else
        _ -> {:halt, conflict("recovery fence chain is not contiguous")}
      end
    end)
    |> case do
      {:ok, ^current, _} -> :ok
      {:ok, _, _} -> conflict("recovery fence chain does not reach current Store incarnation")
      error -> error
    end
  end

  defp run_inventory(records, manifest) do
    obligations = manifest["obligations"]

    Enum.zip(records, manifest["run_refs"])
    |> Enum.flat_map(fn {%{run: run}, ref} ->
      required_obligations(run, ref["original_incarnation"])
    end)
    |> Evidence.each(fn {kind, identity} ->
      if Enum.any?(
           obligations,
           &(&1["kind"] == kind and identity_subset?(identity, &1["identity"]))
         ),
         do: :ok,
         else:
           uncertain("manifest omits an authoritative run obligation", %{
             kind: kind,
             identity: identity
           })
    end)
  end

  defp required_obligations(run, original_incarnation) do
    base = %{"run_id" => run.run_id, "incarnation" => original_incarnation}
    executor = {"executor", base}

    cleanup =
      [Kernel.cleanup_requirements(run), Map.get(run, :cleanup_required, %{})]
      |> Enum.flat_map(&cleanup_obligations(&1, base))

    # A terminal checkpoint clears active_provider even while the old executor
    # may still exist. Its immutable accepted-attempt inventory remains required.
    providers =
      run
      |> Map.get(:provider_attempts, %{})
      |> Map.values()
      |> Enum.map(&{"provider", public_identity(&1, base)})

    intents =
      run
      |> Map.get(:execution_intents, %{})
      |> Map.values()
      |> Enum.filter(&(&1[:status] in [:started, :uncertain]))
      |> Enum.map(fn intent ->
        identity =
          Map.take(
            Map.get(intent, :operation, %{}),
            [:run_id, :incarnation, :step_id, :attempt_id, :invocation_id]
          )

        {to_string(intent.type), public_identity(identity, base)}
      end)

    [executor | cleanup ++ providers ++ intents]
  end

  defp cleanup_obligations(requirements, base) do
    Enum.flat_map(
      [
        {:provider, "provider"},
        {:tools, "tool"},
        {:children, "child"},
        {:dependencies, "dependency"}
      ],
      fn {key, kind} ->
        value = Map.get(requirements, key)
        items = if is_list(value), do: value, else: if(is_nil(value), do: [], else: [value])
        Enum.map(items, fn identity -> {kind, public_identity(identity, base)} end)
      end
    )
  end

  defp public_identity(identity, base) when is_map(identity) do
    case Evidence.public(identity) do
      {:ok, value} -> Map.merge(base, value)
      _ -> %{"invalid_identity" => true}
    end
  end

  defp public_identity(identity, base), do: Map.put(base, "id", to_string(identity))

  defp identity_subset?(expected, actual),
    do: Enum.all?(expected, fn {k, v} -> actual[k] == v end)

  defp observations(config, obligations, bundle) do
    observations = bundle["observations"]

    with :ok <- Evidence.each(observations, &observation/1),
         :ok <- Evidence.unique(observations, & &1["observation_id"]),
         :ok <- Evidence.unique(observations, & &1["obligation_id"]),
         :ok <- Evidence.each(observations, &observation_identity(&1, obligations)),
         {:ok, results} <- collect(obligations, &satisfy(config, &1, observations)) do
      results = propagate_dependencies(results)
      satisfied = for {obligation, true, _} <- results, do: obligation
      pending = for {obligation, false, _} <- results, do: obligation
      effects = for {obligation, _, true} <- results, do: obligation
      {:ok, %{satisfied: satisfied, pending: pending, unresolved_effects: effects}}
    end
  end

  defp propagate_dependencies(results) do
    resolved =
      results
      |> Enum.filter(fn {_, closed, effect} -> closed and not effect end)
      |> MapSet.new(fn {obligation, _, _} -> obligation["obligation_id"] end)

    next =
      Enum.map(results, fn {obligation, closed, effect} ->
        {obligation,
         closed and Enum.all?(Map.get(obligation, "requires", []), &MapSet.member?(resolved, &1)),
         effect}
      end)

    if next == results, do: next, else: propagate_dependencies(next)
  end

  defp observation(value) do
    fields =
      ~w(observation_id observation_revision obligation_id identity result source_ref observed_at_unix_ms)

    with :ok <- Evidence.fields(value, fields, fields),
         :ok <-
           Evidence.each(
             ~w(observation_id obligation_id source_ref),
             &Evidence.identifier(value[&1])
           ),
         :ok <- Evidence.positive(value["observation_revision"]),
         true <- value["result"] in ~w(stopped closed not_started),
         true <- is_integer(value["observed_at_unix_ms"]) and value["observed_at_unix_ms"] >= 0 do
      :ok
    else
      false -> Evidence.invalid("invalid component observation")
      error -> error
    end
  end

  defp observation_identity(observation, obligations) do
    case Enum.find(obligations, &(&1["obligation_id"] == observation["obligation_id"])) do
      nil ->
        conflict("observation refers to an unknown obligation")

      obligation ->
        same(
          observation["identity"],
          obligation["identity"],
          "observed component identity differs"
        )
    end
  end

  defp satisfy(config, obligation, observations) do
    fact = Enum.find(observations, &(&1["obligation_id"] == obligation["obligation_id"]))

    case {obligation["kind"], obligation["identity"]} do
      {"tool", _} ->
        unresolved = is_nil(fact) or fact["result"] != "not_started"
        {:ok, {obligation, not is_nil(fact), unresolved}}

      {_, %{"receipt_id" => id, "subject" => subject} = identity} ->
        case receipt(config, id) do
          {:ok, receipt} ->
            with :ok <- same(receipt["subject"], subject, "subordinate receipt owner differs"),
                 :ok <- optional_digest(receipt, identity["manifest_digest"]),
                 :ok <- subordinate_authority(config, receipt) do
              {:ok, {obligation, receipt["retirement"] == "confirmed", false}}
            end

          {:error, %Error{class: :not_found}} ->
            {:ok, {obligation, false, false}}

          error ->
            error
        end

      _ ->
        {:ok, {obligation, not is_nil(fact), false}}
    end
  end

  defp subordinate_authority(config, %{"retirement" => "confirmed"} = receipt),
    do: receipt_authority(config, receipt)

  defp subordinate_authority(_, _), do: :ok

  defp dag(obligations) do
    graph = Map.new(obligations, &{&1["obligation_id"], Map.get(&1, "requires", [])})

    with :ok <-
           Evidence.each(Map.values(graph), fn deps ->
             if is_list(deps) and Enum.all?(deps, &Map.has_key?(graph, &1)),
               do: :ok,
               else: Evidence.invalid("ownership dependency is absent")
           end) do
      acyclic(graph)
    end
  end

  defp acyclic(graph) when map_size(graph) == 0, do: :ok

  defp acyclic(graph) do
    roots = for {id, []} <- graph, do: id

    if roots == [] do
      Evidence.invalid("ownership inventory has a cycle")
    else
      graph |> Map.drop(roots) |> Map.new(fn {id, deps} -> {id, deps -- roots} end) |> acyclic()
    end
  end

  defp build_receipt(request, previous, bundle, manifest, records, fences, progress) do
    confirmed = progress.pending == [] and progress.unresolved_effects == []

    failure =
      if confirmed,
        do: nil,
        else: %{
          "class" => "unknown_outcome",
          "message" => "lifetime obligations remain unconfirmed"
        }

    %{
      "schema_version" => 1,
      "receipt_id" => request["receipt_id"],
      "revision" => request["expected_revision"] + 1,
      "subject" => request["subject"],
      "manifest_digest" => manifest["manifest_digest"],
      "evidence_ref" => request["evidence_ref"],
      "evidence_digest" => Evidence.digest(bundle),
      "run_fences" => fences,
      "historical_outcomes" =>
        Enum.map(records, fn %{run: run} ->
          %{
            "run_id" => run.run_id,
            "state" => to_string(run.state),
            "outcome_digest" => Evidence.digest(run[:outcome])
          }
        end),
      "satisfied" => progress.satisfied,
      "pending" => progress.pending,
      "unresolved_effects" => progress.unresolved_effects,
      "closure" => if(progress.pending == [], do: "confirmed", else: "pending"),
      "retirement" => if(confirmed, do: "confirmed", else: "pending"),
      "first_failure" => (previous && previous["first_failure"]) || failure,
      "accepted_request_digest" => Evidence.digest(request)
    }
    |> Evidence.seal("receipt_digest")
  end

  defp persist(config, request, next) do
    case invoke(config, :compare_and_swap_receipt, [
           request["receipt_id"],
           request["expected_revision"],
           next
         ]) do
      {:ok, ^next} ->
        receipt_result(next)

      {:error, %Error{class: :resource_conflict}} = error ->
        error

      _ ->
        case receipt(config, request["receipt_id"]) do
          {:ok, ^next} ->
            receipt_result(next)

          _ ->
            uncertain("receipt persistence acknowledgement is unknown", %{
              receipt_id: request["receipt_id"]
            })
        end
    end
  end

  defp receipt_result(%{"retirement" => "confirmed"} = receipt), do: {:ok, receipt}

  defp receipt_result(receipt) do
    uncertain("lifetime obligations remain unconfirmed", %{
      receipt_id: receipt["receipt_id"],
      revision: receipt["revision"],
      pending: receipt["pending"],
      unresolved_effects: receipt["unresolved_effects"],
      first_failure: receipt["first_failure"]
    })
  end

  defp adapter({module, _context}) when is_atom(module) do
    with :ok <- adapter_module(module) do
      if module.mode() in [:ephemeral, :durable],
        do: :ok,
        else: {:error, Error.new(:unsupported_capability, "invalid recovery adapter mode")}
    end
  end

  defp adapter(_), do: {:error, Error.new(:unsupported_capability, "recovery is not configured")}

  defp adapter_module(module) do
    if Code.ensure_loaded?(module) and
         Enum.all?(@callbacks, fn {name, arity} -> function_exported?(module, name, arity) end),
       do: :ok,
       else:
         {:error, Error.new(:unsupported_capability, "recovery adapter callbacks are incomplete")}
  end

  defp invoke({module, context}, function, args) do
    case apply(module, function, [context | args]) do
      {:ok, _} = result -> result
      {:error, %Error{}} = result -> result
      _ -> uncertain("recovery adapter returned an invalid acknowledgement")
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> uncertain("recovery callback raised before acknowledgement")
  catch
    _, _ -> uncertain("recovery callback stopped before acknowledgement")
  end

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp same(value, value, _message), do: :ok
  defp same(_, _, message), do: conflict(message)

  defp conflict(message, details \\ %{}),
    do: {:error, Error.new(:resource_conflict, message, details: details)}

  defp uncertain(message, details \\ %{}),
    do: {:error, Error.new(:unknown_outcome, message, details: details)}
end
