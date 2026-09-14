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

  @spec run(module(), term(), map(), map(), keyword()) ::
          {:ok, map(), map()} | {:error, Error.t()}
  def run(store, context, record, meta, opts \\ [])
      when is_atom(store) and is_map(record) and is_map(meta) and is_list(opts) do
    with {:ok, committed, prepared} <- commit(store, context, record, meta, opts),
         {:ok, effects} <- dispatch(prepared, opts) do
      {:ok, committed,
       %{
         effects: effects,
         fenced: [],
         run: prepared.run,
         budget: prepared.budget,
         operation: prepared.operation
       }}
    end
  end

  @doc false
  @spec commit(module(), term(), map(), map(), keyword()) ::
          {:ok, map(), map()} | {:error, Error.t()}
  def commit(store, context, record, meta, opts)
      when is_atom(store) and is_map(record) and is_map(meta) and is_list(opts) do
    with {:ok, run, _transition, _effects} <- Kernel.execute(record, meta.command),
         {:ok, prepared} <- prepare(meta.command, run, meta, opts),
         commit_meta = Map.put(meta, :outbox, prepared.outbox),
         {:ok, committed} <- Store.store(store, context, record, commit_meta) do
      {:ok, committed, Map.put(prepared, :run, run)}
    end
  end

  @doc false
  @spec dispatch(map(), keyword()) :: {:ok, list()} | {:error, Error.t()}
  def dispatch(%{effect: :none}, _opts), do: {:ok, []}

  def dispatch(%{effect: :provider, adapter: adapter, operation: operation}, opts) do
    with {:ok, response} <- call_adapter(adapter, :start, operation),
         :ok <- bounded(response, Keyword.get(opts, :output_limit, @default_output_limit)) do
      {:ok, [response]}
    end
  end

  def dispatch(%{effect: :tool, adapter: adapter, operation: operation}, opts) do
    with {:ok, result} <- call_adapter(adapter, :execute, operation),
         {:ok, _} <-
           ToolEffects.validate_output(%{payload: result},
             limit: Keyword.get(opts, :output_limit, @default_output_limit)
           ) do
      {:ok, [result]}
    end
  end

  defp prepare(command, run, meta, opts) do
    case command do
      {:provider_started, _at, input} -> prepare_provider(input, run, meta, opts)
      {:tool_invoked, _at, input} -> prepare_tool(input, run, opts)
      _ -> {:ok, %{effect: :none, operation: nil, outbox: [], budget: Keyword.get(opts, :budget)}}
    end
  end

  defp prepare_provider(input, _run, meta, opts) do
    with {:ok, adapter} <- required_module(opts, :adapter, "provider adapter"),
         {:ok, budget, reservation} <- reserve(opts, "provider:#{field(input, :attempt_id)}") do
      trusted = Map.get(meta, :operation, %{})

      operation =
        trusted
        |> Map.merge(Map.take(input, [:run_id, :incarnation, :step_id, :attempt_id]))
        |> Map.put(:provider_context, Keyword.get(opts, :provider_context, %{}))

      intent = %{type: :provider, operation: operation, reservation: reservation}

      {:ok,
       %{
         effect: :provider,
         adapter: adapter,
         operation: operation,
         outbox: [intent],
         budget: budget
       }}
    end
  end

  defp prepare_tool(input, _run, opts) do
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
         {:ok, budget, reservation} <- reserve(opts, "tool:#{field(input, :invocation_id)}") do
      operation =
        input
        |> Map.take([
          :run_id,
          :incarnation,
          :step_id,
          :attempt_id,
          :invocation_id,
          :tool_name,
          :tool_revision
        ])
        |> Map.put(:arguments, arguments)
        |> Map.put(:caller, authorization.caller)
        |> Map.put(:effective_authority, authority_summary(authority))
        |> Map.put(:backend_context, Map.get(descriptor, :backend_context, %{}))

      intent = %{type: :tool, operation: operation, reservation: reservation}

      {:ok,
       %{
         effect: :tool,
         adapter: adapter,
         operation: operation,
         outbox: [intent],
         budget: budget
       }}
    end
  end

  defp reserve(opts, reservation_id) do
    with {:ok, budget} <- required_map(opts, :budget, "finite budget"),
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

  defp authority_summary(authority) do
    Map.take(authority, [:caller, :run_id, :grants, :tool_revision, :scope])
  end

  defp arguments_digest(arguments) do
    :crypto.hash(:sha256, :erlang.term_to_binary(arguments))
    |> Base.encode16(case: :lower)
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
