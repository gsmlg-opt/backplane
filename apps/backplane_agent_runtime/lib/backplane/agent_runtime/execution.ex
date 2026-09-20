defmodule Backplane.AgentRuntime.Execution do
  alias Backplane.AgentRuntime.Approval
  alias Backplane.AgentRuntime.Budget
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.InputSchema
  alias Backplane.AgentRuntime.Kernel
  alias Backplane.AgentRuntime.Policy
  alias Backplane.AgentRuntime.Store
  alias Backplane.AgentRuntime.ToolEffects
  alias Backplane.AgentRuntime.ToolRegistry

  @moduledoc """
  Store-first runtime execution boundary.

  Tool work is resolved from the host registry, validated, authorized, budgeted,
  and committed as a normalized intent before its registered backend is called.
  Provider adapters and authority are supplied by the host and cannot be
  selected or expanded by model arguments.
  """

  @default_output_limit 1_048_576
  @default_commit_timeout 5_000
  @default_effect_timeout 30_000
  @default_cleanup_timeout 5_000
  @default_run_timeout 300_000
  @maximum_timeout 3_600_000

  @spec run(module(), term(), map(), map(), keyword()) ::
          {:ok, map(), map()} | {:error, Error.t()}
  def run(store, context, record, meta, opts \\ [])
      when is_atom(store) and is_map(record) and is_map(meta) and is_list(opts) do
    with {:ok, limits} <- validate_limits(opts),
         :ok <- validate_deadline_for_command(record, meta.command, opts),
         {:ok, commit_timeout} <-
           initial_commit_timeout(record, meta.command, limits, opts),
         {:ok, committed, prepared} <-
           bounded_worker(
             fn -> commit(store, context, record, meta, opts) end,
             commit_timeout,
             :commit
           ) do
      case prepared.effect do
        :none ->
          successful_run_result(committed, prepared, [])

        _ ->
          run_effect(store, context, committed, prepared, limits, opts)
      end
    end
  end

  defp run_effect(store, context, committed, prepared, limits, opts) do
    with {:ok, effect_timeout} <-
           effective_timeout(prepared.run, limits.effect, limits.run, opts) do
      case bounded_worker(fn -> dispatch(prepared, opts) end, effect_timeout, :effect) do
        {:ok, effects} ->
          successful_run_result(committed, prepared, effects)

        {:error, %Error{} = error} ->
          settle_direct_uncertainty(store, context, prepared.run, error, limits, opts)
          {:error, error}
      end
    else
      {:error, %Error{} = error} ->
        settle_direct_uncertainty(store, context, prepared.run, error, limits, opts)
        {:error, error}
    end
  end

  defp successful_run_result(committed, prepared, effects) do
    {:ok, committed,
     %{
       effects: effects,
       fenced: [],
       run: prepared.run,
       budget: prepared.budget,
       operation: prepared.operation
     }}
  end

  @doc false
  @spec commit(module(), term(), map(), map(), keyword()) ::
          {:ok, map(), map()} | {:error, Error.t()}
  def commit(store, context, record, meta, opts)
      when is_atom(store) and is_map(record) and is_map(meta) and is_list(opts) do
    with {:ok, limits} <- validate_limits(opts),
         :ok <- validate_commit_deadline(record, meta.command, opts),
         {:ok, command} <- command_with_deadline(meta.command, record, limits.run, opts),
         {:ok, run, _transition, _effects} <- Kernel.execute(record, command),
         {:ok, prepared} <- prepare(command, run, meta, record, opts),
         {:ok, canonical_command} <-
           canonical_command(command, prepared, record, limits.run, opts),
         {:ok, canonical_run, _transition, _effects} <- Kernel.execute(record, canonical_command),
         :ok <- serializable(canonical_run),
         commit_meta =
           meta |> Map.put(:command, canonical_command) |> Map.put(:outbox, prepared.outbox),
         {:ok, committed} <- Store.store(store, context, record, commit_meta),
         {:ok, operation} <- acknowledged_operation(committed, prepared) do
      {:ok, committed, %{prepared | run: canonical_run, operation: operation}}
    end
  end

  @spec validate_limits(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def validate_limits(opts) when is_list(opts) do
    with {:ok, commit} <- finite_timeout(opts, :commit_timeout, @default_commit_timeout),
         {:ok, effect} <- finite_timeout(opts, :effect_timeout, @default_effect_timeout),
         {:ok, cleanup} <- finite_timeout(opts, :cleanup_timeout, @default_cleanup_timeout),
         {:ok, run} <- finite_timeout(opts, :run_timeout, @default_run_timeout),
         :ok <- validate_clock(opts, :monotonic_now),
         :ok <- validate_clock(opts, :wall_now) do
      {:ok, %{commit: commit, effect: effect, cleanup: cleanup, run: run}}
    end
  end

  @spec validate_deadline(map(), keyword()) :: :ok | {:error, Error.t()}
  def validate_deadline(record, opts) when is_map(record) and is_list(opts),
    do: validate_record_deadline(record, opts)

  @doc false
  @spec dispatch(map(), keyword()) :: {:ok, list()} | {:error, Error.t()}
  def dispatch(%{effect: :none}, _opts), do: {:ok, []}

  def dispatch(
        %{effect: :provider, adapter: adapter, operation: operation, host_context: host_context},
        opts
      ) do
    operation = Map.put(operation, :provider_context, host_context)

    with {:ok, response} <- call_adapter(adapter, :start, operation),
         :ok <- bounded(response, Keyword.get(opts, :output_limit, @default_output_limit)) do
      {:ok, [response]}
    end
  end

  def dispatch(
        %{effect: :tool, adapter: adapter, operation: operation, host_context: host_context},
        opts
      ) do
    operation = Map.put(operation, :backend_context, host_context)

    with {:ok, result} <- call_adapter(adapter, :execute, operation),
         {:ok, _} <-
           ToolEffects.validate_output(%{payload: result},
             limit: Keyword.get(opts, :output_limit, @default_output_limit)
           ) do
      {:ok, [result]}
    end
  end

  defp prepare(command, run, meta, record, opts) do
    case command do
      {:provider_started, _at, input} ->
        prepare_provider(input, run, meta, record, opts)

      {:tool_invoked, _at, input} ->
        prepare_tool(input, run, record, opts)

      _ ->
        {:ok,
         %{
           effect: :none,
           operation: nil,
           outbox: [],
           budget: Map.get(record, :execution_budget) || Keyword.get(opts, :budget),
           host_context: nil,
           adapter: nil,
           intent: nil,
           run: run
         }}
    end
  end

  defp prepare_provider(input, _run, meta, record, opts) do
    with {:ok, adapter} <- required_module(opts, :adapter, "provider adapter"),
         {:ok, budget, reservation} <-
           reserve(record, opts, "provider:#{field(input, :attempt_id)}") do
      trusted = Map.get(meta, :operation, %{})

      operation =
        trusted
        |> Map.merge(Map.take(input, [:run_id, :incarnation, :step_id, :attempt_id]))

      intent = %{
        type: :provider,
        status: :started,
        operation: operation,
        reservation: reservation
      }

      with :ok <- serializable(intent), :ok <- serializable(budget) do
        {:ok,
         %{
           effect: :provider,
           adapter: adapter,
           operation: operation,
           outbox: [intent],
           intent: intent,
           budget: budget,
           host_context: Keyword.get(opts, :provider_context, %{}),
           run: nil
         }}
      end
    end
  end

  defp prepare_tool(input, _run, record, opts) do
    arguments = field(input, :arguments)
    tool_name = field(input, :tool_name)

    with {:ok, registry} <- required_registry(opts),
         {:ok, descriptor} <- ToolRegistry.lookup(registry, tool_name),
         :ok <- exact_tool_revision(descriptor, input),
         {:ok, arguments} <- InputSchema.validate(Map.get(descriptor, :schema), arguments),
         {:ok, authority} <- required_map(opts, :authority, "host authority"),
         {:ok, authorization} <- Policy.authorize_tool(authority, descriptor, input),
         :ok <- approval(descriptor, input, arguments, opts),
         {:ok, adapter} <- descriptor_backend(descriptor),
         {:ok, budget, reservation} <-
           reserve(record, opts, "tool:#{field(input, :invocation_id)}") do
      operation =
        input
        |> Map.take([
          :run_id,
          :incarnation,
          :step_id,
          :attempt_id,
          :invocation_id,
          :tool_name,
          :tool_revision,
          :tool_call_id,
          :turn_id
        ])
        |> Map.put(:arguments, arguments)
        |> Map.put(:caller, authorization.caller)
        |> Map.put(:effective_authority, authority_summary(authority))

      intent = %{type: :tool, status: :started, operation: operation, reservation: reservation}

      with :ok <- serializable(intent), :ok <- serializable(budget) do
        {:ok,
         %{
           effect: :tool,
           adapter: adapter,
           operation: operation,
           outbox: [intent],
           intent: intent,
           budget: budget,
           host_context: Map.get(descriptor, :backend_context, %{}),
           run: nil
         }}
      end
    end
  end

  defp reserve(record, opts, reservation_id) do
    budget = Map.get(record, :execution_budget) || Keyword.get(opts, :budget)

    with {:ok, budget} <- required_budget(budget),
         {:ok, budget, receipt} <-
           Budget.reserve(budget, reservation_id, Keyword.get(opts, :budget_amount, 1)) do
      {:ok, budget, receipt}
    end
  end

  defp approval(descriptor, input, arguments, opts) do
    if get_in(descriptor, [:safety, :requires_approval]) == true do
      digest = arguments_digest(arguments)

      with {:ok, approval} <- required_map(opts, :approval, "approval"),
           {:ok, decision} <- required_map(opts, :approval_decision, "approval decision"),
           :ok <- approval_matches(approval, input, digest),
           {:ok, :approved} <- Approval.decide(approval, decision) do
        :ok
      else
        {:ok, :denied} -> {:error, Error.new(:forbidden, "tool approval was denied")}
        {:error, %Error{} = error} -> {:error, error}
      end
    else
      :ok
    end
  end

  defp approval_matches(approval, input, digest) do
    expected = %{
      run_id: field(input, :run_id),
      tool_name: field(input, :tool_name),
      tool_revision: field(input, :tool_revision),
      arguments_digest: digest
    }

    if Map.take(approval, Map.keys(expected)) == expected do
      :ok
    else
      {:error, Error.new(:forbidden, "approval does not match the exact operation")}
    end
  end

  defp exact_tool_revision(descriptor, input) do
    if descriptor.tool_revision == field(input, :tool_revision) do
      :ok
    else
      {:error, Error.new(:forbidden, "tool revision does not match registered descriptor")}
    end
  end

  defp descriptor_backend(%{backend: adapter}) when is_atom(adapter), do: {:ok, adapter}

  defp descriptor_backend(_descriptor),
    do: {:error, Error.new(:unsupported_capability, "registered tool backend is unavailable")}

  defp required_registry(opts) do
    case Keyword.get(opts, :registry) do
      %ToolRegistry{} = registry -> {:ok, registry}
      _ -> {:error, Error.new(:validation, "tool registry is required")}
    end
  end

  defp required_module(opts, key, label) do
    case Keyword.get(opts, key) do
      adapter when is_atom(adapter) and not is_nil(adapter) -> {:ok, adapter}
      _ -> {:error, Error.new(:validation, "#{label} is required")}
    end
  end

  defp required_map(opts, key, label) do
    case Keyword.get(opts, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, Error.new(:validation, "#{label} is required")}
    end
  end

  defp required_budget(%{quota: quota, used: used, reservations: reservations} = budget)
       when is_integer(quota) and quota > 0 and is_integer(used) and used >= 0 and
              is_map(reservations) and used <= quota,
       do: {:ok, budget}

  defp required_budget(_budget),
    do: {:error, Error.new(:validation, "finite budget is required")}

  defp call_adapter(adapter, function, operation) do
    case apply(adapter, function, [operation]) do
      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:error, %Error{} = error} ->
        {:error, error}

      other ->
        {:error,
         Error.new(:malformed_result, "backend returned an invalid result",
           details: %{received: other}
         )}
    end
  end

  defp bounded(result, limit) when is_integer(limit) and limit >= 0 do
    size = :erlang.external_size(result)

    if size <= limit,
      do: :ok,
      else:
        {:error,
         Error.new(:resource_conflict, "provider output exceeds the configured bound",
           details: %{limit: limit, size: size}
         )}
  end

  defp command_with_deadline({:admit, at, input}, record, run_timeout, opts)
       when is_map(input) do
    deadline = field(input, :deadline) || absolute_deadline(record, run_timeout, opts)
    {:ok, {:admit, at, Map.put(input, :deadline, deadline)}}
  end

  defp command_with_deadline(command, _record, _run_timeout, _opts), do: {:ok, command}

  defp canonical_command(command, %{effect: :none}, _record, _run_timeout, _opts),
    do: {:ok, command}

  defp canonical_command({kind, at, input}, prepared, record, run_timeout, opts)
       when kind in [:provider_started, :tool_invoked] and is_map(input) do
    deadline = absolute_deadline(record, run_timeout, opts)

    canonical_input =
      case kind do
        :provider_started ->
          Map.take(prepared.operation, [:run_id, :incarnation, :step_id, :attempt_id])

        :tool_invoked ->
          Map.take(prepared.operation, [
            :run_id,
            :incarnation,
            :step_id,
            :attempt_id,
            :invocation_id,
            :tool_name,
            :tool_revision,
            :tool_call_id,
            :turn_id,
            :arguments,
            :caller,
            :effective_authority
          ])
      end

    canonical_input =
      canonical_input
      |> Map.put(:execution_intent, prepared.intent)
      |> Map.put(:execution_budget, prepared.budget)
      |> Map.put(:execution_deadline, deadline)

    {:ok, {kind, at, canonical_input}}
  end

  defp acknowledged_operation(%{outbox: []}, %{effect: :none}), do: {:ok, nil}

  defp acknowledged_operation(%{outbox: [intent]}, %{intent: intent}) do
    {:ok, Map.fetch!(intent, :operation)}
  end

  defp acknowledged_operation(_committed, _prepared) do
    {:error, Error.new(:execution_failure, "committed intent does not match prepared operation")}
  end

  defp finite_timeout(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 and value <= @maximum_timeout -> {:ok, value}
      _ -> {:error, Error.new(:validation, "#{key} must be a finite positive timeout")}
    end
  end

  defp validate_clock(opts, key) do
    default =
      case key do
        :monotonic_now -> fn -> System.monotonic_time(:millisecond) end
        :wall_now -> fn -> System.system_time(:millisecond) end
      end

    case Keyword.get(opts, key, default) do
      clock when is_function(clock, 0) -> :ok
      _ -> {:error, Error.new(:validation, "#{key} must be a zero-arity function")}
    end
  end

  defp absolute_deadline(%{deadline: deadline}, _run_timeout, _opts)
       when is_integer(deadline),
       do: deadline

  defp absolute_deadline(_record, run_timeout, opts), do: wall_now(opts) + run_timeout

  defp effective_timeout(record, configured, run_timeout, opts) do
    remaining = absolute_deadline(record, run_timeout, opts) - wall_now(opts)

    if remaining > 0,
      do: {:ok, min(configured, remaining)},
      else: {:error, Error.new(:timeout, "run deadline has expired")}
  end

  defp initial_commit_timeout(_record, command, limits, _opts)
       when elem(command, 0) in [:cancel, :deadline_exceeded, :cleanup_settled],
       do: {:ok, min(limits.commit, limits.cleanup)}

  defp initial_commit_timeout(record, _command, limits, opts),
    do: effective_timeout(record, limits.commit, limits.run, opts)

  defp wall_now(opts) do
    clock = Keyword.get(opts, :wall_now, fn -> System.system_time(:millisecond) end)
    clock.()
  end

  defp validate_record_deadline(%{deadline: nil}, _opts), do: :ok

  defp validate_record_deadline(%{deadline: deadline}, opts) when is_integer(deadline) do
    if deadline > wall_now(opts),
      do: :ok,
      else: {:error, Error.new(:timeout, "run deadline has expired")}
  end

  defp validate_record_deadline(%{deadline: _deadline}, _opts),
    do: {:error, Error.new(:validation, "run deadline must be an absolute millisecond timestamp")}

  defp validate_record_deadline(_record, _opts), do: :ok

  defp validate_commit_deadline(record, command, opts) do
    case validate_deadline_for_command(record, command, opts) do
      {:error, %Error{} = error} ->
        {:error, %{error | details: Map.put(error.details, :boundary, :before_store)}}

      :ok ->
        :ok
    end
  end

  defp validate_deadline_for_command(_record, {kind, _at}, _opts)
       when kind in [:cancel, :deadline_exceeded],
       do: :ok

  defp validate_deadline_for_command(_record, {:cleanup_settled, _at, _input}, _opts), do: :ok

  # Checkpoints carry no external effect and may settle control state after expiry.
  defp validate_deadline_for_command(_record, {:conversation_updated, _at, _input}, _opts),
    do: :ok

  defp validate_deadline_for_command(record, _command, opts),
    do: validate_record_deadline(record, opts)

  defp settle_direct_uncertainty(store, context, run, error, limits, opts) do
    at = wall_now(opts)
    stop = if error.class == :timeout, do: {:deadline_exceeded, at}, else: {:cancel, at}
    cleanup_deadline = monotonic_now(opts) + limits.cleanup

    with {:ok, first_timeout} <- cleanup_remaining(cleanup_deadline, limits.commit, opts),
         {:ok, receipt, cancelling} <-
           bounded_worker(
             fn -> commit(store, context, run, %{command: stop}, opts) end,
             first_timeout,
             :cleanup_commit
           ),
         settlement = %{
           certainty: :uncertain,
           evidence: %{
             "reason" => error.message,
             "required" => Kernel.cleanup_requirements(cancelling.run),
             "transition_revision" => receipt.revision
           }
         },
         {:ok, second_timeout} <- cleanup_remaining(cleanup_deadline, limits.commit, opts),
         {:ok, _receipt, _prepared} <-
           bounded_worker(
             fn ->
               commit(
                 store,
                 context,
                 cancelling.run,
                 %{command: {:cleanup_settled, at + 1, settlement}},
                 opts
               )
             end,
             second_timeout,
             :cleanup_commit
           ) do
      :ok
    else
      _ -> :uncertain
    end
  end

  defp cleanup_remaining(deadline, commit_timeout, opts) do
    remaining = deadline - monotonic_now(opts)

    if remaining > 0,
      do: {:ok, min(commit_timeout, remaining)},
      else: {:error, Error.new(:timeout, "cleanup deadline exceeded")}
  end

  defp monotonic_now(opts) do
    clock = Keyword.get(opts, :monotonic_now, fn -> System.monotonic_time(:millisecond) end)
    clock.()
  end

  defp bounded_worker(function, timeout, kind) do
    {:ok, supervisor} = Task.Supervisor.start_link()
    task = Task.Supervisor.async_nolink(supervisor, function)

    try do
      case Task.yield(task, timeout) do
        {:ok, result} ->
          result

        {:exit, reason} ->
          {:error, Error.new(:execution_failure, "#{kind} worker exited", cause: reason)}

        nil ->
          Task.shutdown(task, :brutal_kill)

          {:error,
           Error.new(:timeout, "#{kind} deadline exceeded", details: %{certainty: :uncertain})}
      end
    after
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal)
    end
  end

  defp serializable(value) when is_pid(value) or is_port(value) or is_reference(value),
    do: {:error, Error.new(:validation, "committed intent contains a runtime handle")}

  defp serializable(value) when is_function(value),
    do: {:error, Error.new(:validation, "committed intent contains a runtime function")}

  defp serializable(value) when is_map(value) do
    Enum.reduce_while(Map.to_list(value), :ok, fn {key, item}, :ok ->
      with :ok <- serializable(key), :ok <- serializable(item) do
        {:cont, :ok}
      else
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp serializable(value) when is_list(value), do: serializable_list(value)

  defp serializable(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> serializable_list()

  defp serializable(_value), do: :ok

  defp serializable_list(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case serializable(value) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp authority_summary(authority) do
    Map.take(authority, [:caller, :run_id, :grants, :tool_revision, :scope])
  end

  defp arguments_digest(arguments) do
    :crypto.hash(:sha256, :erlang.term_to_binary(arguments))
    |> Base.encode16(case: :lower)
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
