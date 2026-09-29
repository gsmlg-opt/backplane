defmodule Backplane.AgentRuntime.Codex.DynamicRuntime do
  @moduledoc "Host-mediated MCP resources, deferred tool publication, and plugin requests."

  use GenServer

  alias Backplane.AgentRuntime.{Codex.Contract, Codex.Dynamic, Error, ToolRegistry}

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
  def call(%{backend_context: %{runtime: runtime}} = operation) when is_pid(runtime),
    do: GenServer.call(runtime, {:tool, operation}, :infinity)

  def call(_operation),
    do: {:error, Error.new(:unsupported_capability, "dynamic runtime is unavailable")}

  @impl true
  def init(opts) do
    with {:ok, dynamic} <- Dynamic.new(max_results: Keyword.get(opts, :max_results, 50)) do
      candidates = Keyword.get(opts, :candidates, [])

      {:ok,
       %{
         dynamic: dynamic,
         candidates: candidates,
         discovered: MapSet.new(),
         mcp_adapter: Keyword.get(opts, :mcp_adapter),
         plugin_adapter: Keyword.get(opts, :plugin_adapter),
         plugin_context: Keyword.get(opts, :plugin_context, %{})
       }}
    end
  end

  @impl true
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

  defp execute(%{tool_name: "tool_search", arguments: arguments} = operation, state) do
    owner = operation.run_id

    with {:ok, state} <- discover_owner(state, owner),
         query when is_binary(query) <- arguments["query"],
         limit <- arguments["limit"] || 8,
         :ok <- positive_limit(limit),
         {:ok, results} <- Dynamic.search(state.dynamic, owner, query, limit: limit),
         {:ok, state, publication} <- publish_results(state, operation, results) do
      {:ok, %{tools: results, publication: publication}, state}
    else
      nil -> {:error, validation("query is required")}
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
         {:ok, host_result, _state} <-
           adapter_call(state, :plugin_adapter, :request_install, [arguments, operation]) do
      result = %{request_id: receipt.id, status: :requested, host: host_result}
      {:ok, result, %{state | dynamic: next_dynamic}}
    end
  end

  defp execute(_operation, _state), do: {:error, Error.new(:not_found, "unknown dynamic tool")}

  defp discover_owner(%{discovered: discovered} = state, owner) do
    if MapSet.member?(discovered, owner) do
      {:ok, state}
    else
      case Dynamic.discover(state.dynamic, owner, state.candidates, source: :host) do
        {:ok, dynamic, _found} ->
          {:ok, %{state | dynamic: dynamic, discovered: MapSet.put(discovered, owner)}}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  defp publish_results(state, _operation, []), do: {:ok, state, %{status: :no_matches}}

  defp publish_results(state, operation, results) do
    with {:ok, dynamic} <- publish_dynamic(state.dynamic, operation.run_id, results),
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
      {:ok, %{state | dynamic: dynamic}, receipt}
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> {:error, unsupported("catalog publication context is unavailable")}
    end
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

      tools = current.tools ++ Enum.map(contracts, &Contract.provider_definition/1)
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
    adapter = Map.fetch!(state, key)

    cond do
      not adapter?(adapter) ->
        {:error, unsupported("configured host adapter is unavailable")}

      not function_exported?(adapter, function, length(arguments)) ->
        {:error, unsupported("configured host adapter does not support this operation")}

      true ->
        case apply(adapter, function, arguments) do
          {:ok, result} when is_map(result) or is_list(result) ->
            {:ok, result, state}

          {:error, %Error{} = error} ->
            {:error, error}

          other ->
            {:error,
             Error.new(:malformed_result, "host adapter returned invalid data",
               details: %{received: other}
             )}
        end
    end
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
