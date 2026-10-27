defmodule Backplane.AgentRuntime.Codex.DynamicRuntime do
  @moduledoc "Host-mediated MCP resources, deferred tool publication, and plugin requests."

  use GenServer

  alias Backplane.AgentRuntime.{
    Codex.Contract,
    Codex.Dynamic,
    Codex.ToolSearch,
    Codex.ResourceRequest,
    Error,
    ToolRegistry,
    ToolCatalog
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @spec contracts(map()) :: [map()]
  def contracts(%{dynamic_runtime: runtime}) when is_pid(runtime) do
    capabilities = GenServer.call(runtime, :capabilities)

    []
    |> maybe_add(
      capabilities.search?,
      contract("tool_search", tool_search_schema(), runtime, true)
    )
    |> maybe_add(
      capabilities.mcp?,
      contract("list_mcp_resources", mcp_list_schema(), runtime, true)
    )
    |> maybe_add(
      capabilities.mcp?,
      contract("list_mcp_resource_templates", mcp_list_schema(), runtime, true)
    )
    |> maybe_add(
      capabilities.mcp?,
      contract("read_mcp_resource", mcp_read_schema(), runtime, true)
    )
    |> maybe_add(
      capabilities.plugins?,
      contract("list_available_plugins_to_install", empty_schema(), runtime, true)
    )
    |> maybe_add(
      capabilities.plugins?,
      contract("request_plugin_install", plugin_request_schema(), runtime, false)
    )
  end

  def contracts(_context), do: []

  @spec call(map()) :: {:ok, map()} | {:error, Error.t()}
  def call(%{tool_name: name, backend_context: %{runtime: runtime}} = operation)
      when is_pid(runtime) and
             name in ["list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource"] do
    adapter = GenServer.call(runtime, :resource_adapter)

    case execute(operation, %{mcp_adapter: adapter}) do
      {:ok, result, _} -> {:ok, result}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def call(%{backend_context: %{runtime: runtime}} = operation) when is_pid(runtime),
    do: GenServer.call(runtime, {:tool, operation}, :infinity)

  def call(_operation),
    do: {:error, Error.new(:unsupported_capability, "dynamic runtime is unavailable")}

  @doc """
  Runs one caller-owned MCP resource request with cooperative local cancellation.

  The starter must only start that resource request in the calling process. It
  returns the public MCP result for the adapter's usual result/error conversion.
  Additional untracked adapter effects cannot be confirmed by this helper.
  """
  def resource_request(operation, starter), do: ResourceRequest.run(operation, starter)

  @doc false
  def cancel_resource(operation), do: ResourceRequest.cancel(operation)

  @impl true
  def init(opts) do
    with {:ok, dynamic} <- Dynamic.new(max_results: Keyword.get(opts, :max_results, 50)) do
      candidates = Keyword.get(opts, :candidates, [])

      {:ok,
       %{
         dynamic: dynamic,
         candidates: candidates,
         discovery_owners: %{},
         pending_publications: %{},
         resource_requests: %{},
         mcp_adapter: Keyword.get(opts, :mcp_adapter),
         plugin_adapter: Keyword.get(opts, :plugin_adapter),
         plugin_context: Keyword.get(opts, :plugin_context, %{})
       }}
    end
  end

  @impl true
  def handle_call(:resource_adapter, _from, state), do: {:reply, state.mcp_adapter, state}

  def handle_call({:register_resource, operation, control}, {owner, _}, state) do
    registration = ResourceRequest.registration_id()

    entry = %{
      registration: registration,
      operation: operation,
      owner: owner,
      monitor: Process.monitor(owner),
      control: control,
      waiters: [],
      result: nil,
      request_identity: nil,
      stop_generation: nil,
      coordinator_monitor: nil,
      managed: false
    }

    {:reply, {:ok, registration},
     %{state | resource_requests: Map.put(state.resource_requests, registration, entry)}}
  end

  def handle_call({:coordinate_resource, registration, coordinator}, {owner, _}, state)
      when is_pid(coordinator) do
    case state.resource_requests[registration] do
      %{owner: ^owner, coordinator_monitor: nil} = entry ->
        entry = %{entry | coordinator_monitor: Process.monitor(coordinator), managed: true}
        {:reply, :ok, put_in(state.resource_requests[registration], entry)}

      _ ->
        {:reply, {:error, Error.new(:resource_conflict, "resource coordinator is stale")}, state}
    end
  end

  def handle_call({:cancel_resource, operation, deadline}, from, state) do
    identity = Backplane.AgentRuntime.ToolEffects.cancellation_identity(operation)
    entry = state.resource_requests[operation[:resource_registration]]

    entry =
      if entry &&
           Backplane.AgentRuntime.ToolEffects.cancellation_identity(entry.operation) === identity &&
           (entry.stop_generation == nil or entry.stop_generation === operation[:stop_generation]),
         do: entry

    case entry do
      %{result: {:cancelled, report}} ->
        {:reply, ResourceRequest.assertion(entry, report), state}

      %{result: nil} ->
        ResourceRequest.signal(entry.control, "runtime_cancelled", deadline)

        entry = %{
          entry
          | waiters: [from | entry.waiters],
            stop_generation: operation.stop_generation
        }

        {:noreply, put_in(state.resource_requests[entry.registration], entry)}

      _ ->
        {:reply, {:error, Error.new(:unknown_outcome, "resource cancellation is unconfirmed")},
         state}
    end
  end

  def handle_call({:finish_resource, registration, result}, {owner, _}, state) do
    case state.resource_requests[registration] do
      %{owner: ^owner, result: nil} = entry ->
        entry = %{entry | result: result}

        assertion =
          case result do
            {:cancelled, report} -> ResourceRequest.assertion(entry, report)
            _ -> {:error, Error.new(:unknown_outcome, "resource completed before cancellation")}
          end

        Enum.each(entry.waiters, &GenServer.reply(&1, assertion))
        {:reply, :ok, put_in(state.resource_requests[registration], %{entry | waiters: []})}

      _ ->
        {:reply,
         {:error, Error.new(:resource_conflict, "resource request registration is stale")}, state}
    end
  end

  def handle_call({:attach_resource, registration, identity}, {owner, _}, state) do
    case state.resource_requests[registration] do
      %{owner: ^owner, request_identity: nil} = entry ->
        {:reply, :ok,
         put_in(state.resource_requests[registration], %{entry | request_identity: identity})}

      _ ->
        {:reply, {:error, Error.new(:resource_conflict, "resource registration is stale")}, state}
    end
  end

  def handle_call({:discard_resource, registration}, {owner, _}, state) do
    case state.resource_requests[registration] do
      %{owner: ^owner} = entry ->
        retire_resource_monitors(entry)

        {:reply, :ok,
         %{state | resource_requests: Map.delete(state.resource_requests, registration)}}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:capabilities, _from, state) do
    {:reply,
     %{
       search?: state.candidates != [],
       mcp?: adapter?(state.mcp_adapter),
       plugins?: adapter?(state.plugin_adapter)
     }, state}
  end

  def handle_call({:tool, operation}, _from, state) do
    case execute(operation, state) do
      {:ok, result, next} -> {:reply, {:ok, result}, next}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_cast({:release_resource, registration, identity}, state) do
    case state.resource_requests[registration] do
      %{operation: operation} = entry ->
        if Backplane.AgentRuntime.ToolEffects.cancellation_identity(operation) === identity do
          retire_resource_monitors(entry)

          {:noreply,
           %{state | resource_requests: Map.delete(state.resource_requests, registration)}}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, state) do
    requests =
      Enum.reduce(state.resource_requests, %{}, fn {id, entry}, acc ->
        cond do
          entry.coordinator_monitor == monitor ->
            reply_resource_waiters(entry, "resource coordinator exited")
            retire_resource_monitors(entry)
            acc

          entry.monitor == monitor ->
            reply_resource_waiters(entry, "resource owner exited")

            if entry.managed and entry.result != nil do
              Map.put(acc, id, %{entry | monitor: nil, waiters: []})
            else
              retire_resource_monitors(entry)
              acc
            end

          true ->
            Map.put(acc, id, entry)
        end
      end)

    {:noreply, %{state | resource_requests: requests}}
  end

  defp retire_resource_monitors(entry) do
    for monitor <- [entry.monitor, entry.coordinator_monitor],
        is_reference(monitor),
        do: Process.demonitor(monitor, [:flush])

    :ok
  end

  defp reply_resource_waiters(entry, message) do
    Enum.each(entry.waiters, fn from ->
      GenServer.reply(from, {:error, Error.new(:unknown_outcome, message)})
    end)
  end

  defp execute(%{tool_name: "tool_search", arguments: arguments} = operation, state) do
    with {:ok, owner_key} <- discovery_owner(operation),
         {:ok, query, limit} <- search_arguments(arguments),
         {:ok, state, dynamic} <- discover_owner(state, owner_key),
         {:ok, state, dynamic} <- reconcile_publication(state, operation, owner_key, dynamic),
         :ok <- positive_limit(limit),
         {:ok, results} <- Dynamic.search(dynamic, operation.run_id, query, limit: limit),
         {:ok, state, publication} <-
           publish_results(state, operation, owner_key, dynamic, results) do
      {:ok, %{tools: results, publication: publication}, state}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp execute(%{tool_name: "list_mcp_resources", arguments: arguments} = operation, state),
    do: adapter_call(state, :mcp_adapter, :list_resources, [arguments, operation])

  defp execute(
         %{tool_name: "list_mcp_resource_templates", arguments: arguments} = operation,
         state
       ),
       do: adapter_call(state, :mcp_adapter, :list_resource_templates, [arguments, operation])

  defp execute(%{tool_name: "read_mcp_resource", arguments: arguments} = operation, state),
    do: adapter_call(state, :mcp_adapter, :read_resource, [arguments, operation])

  defp execute(%{tool_name: "list_available_plugins_to_install"} = operation, state),
    do: adapter_call(state, :plugin_adapter, :list_candidates, [operation, state.plugin_context])

  defp execute(%{tool_name: "request_plugin_install", arguments: arguments} = operation, state) do
    with {:ok, receipt, next_dynamic} <-
           request_plugin(state.dynamic, operation.run_id, arguments),
         outcome <-
           call_adapter(state, :plugin_adapter, :request_install, [
             arguments,
             Map.put(operation, :plugin_request_id, receipt.id)
           ]) do
      plugin_outcome(outcome, receipt, next_dynamic, operation, state)
    end
  end

  defp execute(_operation, _state), do: {:error, Error.new(:not_found, "unknown dynamic tool")}

  defp search_arguments(arguments) when is_map(arguments) do
    with {:ok, query} <- ToolSearch.query(Map.get(arguments, "query")) do
      {:ok, query, Map.get(arguments, "limit", 8)}
    end
  end

  defp search_arguments(_), do: {:error, validation("search arguments must be an object")}

  defp discovery_owner(operation) do
    with run when is_binary(run) and run != "" <- Map.get(operation, :run_id),
         incarnation when is_integer(incarnation) and incarnation > 0 <-
           Map.get(operation, :incarnation),
         {:ok, caller} <- discovery_caller(operation) do
      {:ok, {caller, run, incarnation}}
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> {:error, validation("dynamic run and positive incarnation are required")}
    end
  end

  defp discovery_caller(operation) do
    case Map.fetch(operation, :caller) do
      :error -> {:ok, :host_direct}
      {:ok, caller} when is_binary(caller) and caller != "" -> {:ok, caller}
      _ -> {:error, validation("dynamic caller must be a nonempty string")}
    end
  end

  defp discover_owner(state, {_caller, run, _incarnation} = owner_key) do
    case Map.fetch(state.discovery_owners, owner_key) do
      {:ok, dynamic} ->
        {:ok, state, dynamic}

      :error ->
        with {:ok, dynamic} <- Dynamic.new(max_results: state.dynamic.max_results),
             {:ok, dynamic, _found} <-
               Dynamic.discover(dynamic, run, state.candidates, source: :host) do
          {:ok, put_owner(state, owner_key, dynamic), dynamic}
        end
    end
  end

  defp put_owner(state, key, dynamic),
    do: %{state | discovery_owners: Map.put(state.discovery_owners, key, dynamic)}

  defp publish_results(state, _operation, _key, _dynamic, []),
    do: {:ok, state, %{status: :no_matches}}

  defp publish_results(state, operation, owner_key, dynamic, results) do
    with {:ok, _validated} <- publish_dynamic(dynamic, operation.run_id, results),
         %{stage_catalog: stage, catalog_snapshot: current} <- operation.backend_context,
         :ok <- publication_callback(stage),
         {:ok, registry, authority, tools} <- extend_catalog(state, current, operation, results),
         update = %{
           run_id: operation.run_id,
           incarnation: operation.incarnation,
           expected_revision: current.revision,
           publication_id: unique_id("dynamic_publication"),
           schema_admission: :strict,
           catalog: %{
             revision: current.revision + 1,
             registry: registry,
             authority: authority,
             tools: tools
           }
         },
         {:ok, receipt} <- stage.(update) do
      pending = %{
        revision: update.catalog.revision,
        publication_id: update.publication_id,
        results: results
      }

      next = put_owner(state, owner_key, dynamic)

      {:ok,
       %{next | pending_publications: Map.put(next.pending_publications, owner_key, pending)},
       receipt}
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> {:error, unsupported("catalog publication context is unavailable")}
    end
  end

  # A staged receipt is not publication. Only the next trusted committed catalog
  # snapshot can consume these candidates; discarded stages remain discoverable.
  defp reconcile_publication(state, operation, owner_key, dynamic) do
    pending = state.pending_publications[owner_key]
    current = get_in(operation, [:backend_context, :catalog_snapshot])

    if pending && is_map(current) && current[:revision] >= pending.revision &&
         pending_registered?(current.registry, pending.results) do
      with {:ok, next} <- publish_dynamic(dynamic, operation.run_id, pending.results) do
        state = put_owner(state, owner_key, next)

        {:ok, %{state | pending_publications: Map.delete(state.pending_publications, owner_key)},
         next}
      end
    else
      {:ok, state, dynamic}
    end
  end

  defp pending_registered?(registry, results) do
    Enum.all?(results, fn result ->
      case ToolRegistry.lookup(registry, result.name) do
        {:ok, %{tool_revision: revision}} -> revision == result.revision
        _ -> false
      end
    end)
  end

  defp publish_dynamic(dynamic, owner, results) do
    Enum.reduce_while(results, {:ok, dynamic}, fn result, {:ok, current} ->
      case Dynamic.publish(current, owner, result.name) do
        {:ok, next, _receipt} -> {:cont, {:ok, next}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp extend_catalog(state, current, operation, results) do
    selected = MapSet.new(Enum.map(results, & &1.name))

    with {:ok, contracts} <- normalize_selected(state.candidates, selected),
         :ok <- ensure_catalog_names_available(current.registry, contracts),
         {:ok, registry} <- register_all(current.registry, contracts) do
      names = Enum.map(contracts, & &1.tool_name)
      revisions = Map.new(contracts, &{&1.tool_name, &1.tool_revision})

      authority =
        current.authority
        |> Map.update(:grants, names, &Enum.uniq(&1 ++ names))
        |> Map.update(:tool_revisions, revisions, &Map.merge(&1, revisions))
        |> Map.put(:run_id, operation.run_id)

      tools =
        current.tools ++
          (contracts
           |> Enum.filter(&ToolCatalog.provider_visible?(Contract.descriptor(&1)))
           |> Enum.map(&Contract.provider_definition/1))

      {:ok, registry, authority, tools}
    end
  end

  defp normalize_selected(candidates, selected) do
    Enum.reduce_while(candidates, {:ok, []}, fn attrs, {:ok, contracts} ->
      case Contract.new(attrs) do
        {:ok, contract} ->
          if MapSet.member?(selected, contract.tool_name),
            do: {:cont, {:ok, [contract | contracts]}},
            else: {:cont, {:ok, contracts}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, contracts} -> {:ok, Enum.reverse(contracts)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp ensure_catalog_names_available(registry, contracts) do
    case Enum.find(contracts, &Map.has_key?(registry.tools, &1.tool_name)) do
      nil ->
        :ok

      contract ->
        {:error,
         Error.new(:resource_conflict, "dynamic tool collides with the active catalog",
           details: %{tool: contract.tool_name}
         )}
    end
  end

  defp register_all(registry, contracts) do
    Enum.reduce_while(contracts, {:ok, registry}, fn contract, {:ok, acc} ->
      case ToolRegistry.register(acc, Contract.descriptor(contract)) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp request_plugin(dynamic, owner, arguments) do
    case Dynamic.request_plugin(dynamic, owner, arguments) do
      {:ok, next, receipt} -> {:ok, receipt, next}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp adapter_call(state, key, function, arguments) do
    case call_adapter(state, key, function, arguments) do
      {:ok, result} when is_map(result) or is_list(result) -> {:ok, result, state}
      {:error, %Error{} = error} -> {:error, error}
      other -> malformed_adapter_result(other)
    end
  end

  defp call_adapter(state, key, function, arguments) do
    adapter = Map.fetch!(state, key)

    cond do
      not adapter?(adapter) ->
        {:error, unsupported("configured host adapter is unavailable")}

      not function_exported?(adapter, function, length(arguments)) ->
        {:error, unsupported("configured host adapter does not support this operation")}

      true ->
        apply(adapter, function, arguments)
    end
  end

  defp plugin_outcome({:ok, {:completed, fields}}, receipt, dynamic, operation, state) do
    if valid_plugin_completion?(fields, operation.arguments) do
      {:ok, completed, _receipt} =
        Dynamic.complete_plugin(dynamic, operation.run_id, Map.put(fields, :id, receipt.id))

      result = Map.merge(fields, %{request_id: receipt.id, status: :completed})
      {:ok, result, %{state | dynamic: completed}}
    else
      {:error,
       Error.new(:unknown_outcome, "host plugin completion evidence is invalid",
         details: %{reason: :malformed_plugin_completion, request_id: receipt.id}
       )}
    end
  end

  defp plugin_outcome({:ok, result}, receipt, dynamic, _operation, state)
       when is_map(result) or is_list(result) do
    {:ok, %{request_id: receipt.id, status: :requested, host: result},
     %{state | dynamic: dynamic}}
  end

  defp plugin_outcome({:error, %Error{} = error}, _receipt, _dynamic, _operation, _state),
    do: {:error, error}

  defp plugin_outcome(other, _receipt, _dynamic, _operation, _state),
    do: malformed_adapter_result(other)

  defp valid_plugin_completion?(fields, arguments) when is_map(fields) do
    required = [:completed, :user_confirmed, :tool_type, :action_type, :tool_id]

    Enum.all?(required, &Map.has_key?(fields, &1)) and
      Enum.all?(Map.keys(fields), &(&1 in [:tool_name | required])) and
      fields.completed == true and is_boolean(fields.user_confirmed) and
      Enum.all?([:tool_type, :action_type, :tool_id], fn key ->
        value = Map.get(fields, key)
        nonempty_text?(value) and value == Map.get(arguments, Atom.to_string(key))
      end) and
      (not Map.has_key?(fields, :tool_name) or nonempty_text?(fields.tool_name))
  end

  defp valid_plugin_completion?(_fields, _arguments), do: false

  defp nonempty_text?(value),
    do: is_binary(value) and value != "" and String.valid?(value)

  defp malformed_adapter_result(other) do
    {:error,
     Error.new(:malformed_result, "host adapter returned invalid data",
       details: %{received: other}
     )}
  end

  defp adapter?(adapter),
    do: is_atom(adapter) and not is_nil(adapter) and Code.ensure_loaded?(adapter)

  defp maybe_add(items, true, item), do: items ++ [item]
  defp maybe_add(items, false, _item), do: items

  defp contract(name, schema, runtime, read_only) do
    %{
      name: name,
      description: description(name),
      schema: schema,
      backend: Backplane.AgentRuntime.Codex.Backend,
      backend_context: %{family: :dynamic, runtime: runtime},
      revision: 1,
      strict: false,
      safety: %{read_only: read_only, retry_safe: read_only, parallel_safe: read_only}
    }
  end

  defp description("tool_search"),
    do: "Search deferred tool metadata and publish matching tools for the next model call."

  defp description("list_mcp_resources"), do: "List resources provided by configured MCP servers."
  defp description("list_mcp_resource_templates"), do: "List MCP resource templates."
  defp description("read_mcp_resource"), do: "Read one resource from a configured MCP server."

  defp description("list_available_plugins_to_install"),
    do: "List host-known plugin install candidates."

  defp description("request_plugin_install"), do: "Request host-mediated plugin installation."

  defp tool_search_schema,
    do:
      object_schema(
        %{"query" => %{"type" => "string"}, "limit" => %{"type" => "integer", "minimum" => 1}},
        ["query"]
      )

  defp mcp_list_schema,
    do:
      object_schema(
        %{"server" => %{"type" => "string"}, "cursor" => %{"type" => "string"}},
        []
      )

  defp mcp_read_schema,
    do:
      object_schema(
        %{"server" => %{"type" => "string"}, "uri" => %{"type" => "string"}},
        ["server", "uri"]
      )

  defp plugin_request_schema,
    do:
      object_schema(
        %{
          "tool_type" => %{"type" => "string"},
          "action_type" => %{"type" => "string"},
          "tool_id" => %{"type" => "string"},
          "suggest_reason" => %{"type" => "string"}
        },
        ["tool_type", "action_type", "tool_id", "suggest_reason"]
      )

  defp empty_schema, do: object_schema(%{}, [])

  defp object_schema(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }

  defp unique_id(prefix),
    do: prefix <> "_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

  defp validation(message), do: Error.new(:validation, message)
  defp unsupported(message), do: Error.new(:unsupported_capability, message)

  defp positive_limit(value) when is_integer(value) and value > 0, do: :ok
  defp positive_limit(_), do: {:error, validation("limit must be positive")}

  defp publication_callback(callback) when is_function(callback, 1), do: :ok

  defp publication_callback(_),
    do: {:error, unsupported("catalog publication callback is unavailable")}
end
