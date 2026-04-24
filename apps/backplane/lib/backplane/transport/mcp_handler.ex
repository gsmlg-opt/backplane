defmodule Backplane.Transport.McpHandler do
  @moduledoc """
  JSON-RPC dispatcher for MCP protocol messages.

  Handles: initialize, tools/list, tools/call, resources/list, resources/read,
  prompts/list, prompts/get, completion/complete, logging/setLevel, ping.
  """

  import Plug.Conn

  require Logger

  alias Backplane.Clients
  alias Backplane.Proxy.Upstream
  alias Backplane.Registry.{InputValidator, ToolRegistry}
  alias Backplane.Skills.Registry, as: SkillsRegistry
  alias Backplane.Telemetry
  alias Backplane.Transport.SSE

  @server_name "backplane"

  defp server_capabilities do
    %{
      tools: %{listChanged: true},
      resources: %{listChanged: true},
      prompts: %{listChanged: true},
      completions: %{},
      logging: %{}
    }
  end

  defp initialize_result do
    %{
      protocolVersion: Backplane.protocol_version(),
      serverInfo: %{name: @server_name, version: Backplane.version()},
      capabilities: server_capabilities()
    }
  end

  @spec handle(Plug.Conn.t()) :: Plug.Conn.t()
  def handle(conn) do
    case conn.body_params do
      %{"_json" => batch} when is_list(batch) ->
        handle_batch(conn, batch)

      %{"jsonrpc" => "2.0", "method" => method, "id" => id} = params ->
        Telemetry.emit_mcp_request(method)
        dispatch(conn, method, id, params["params"])

      %{"jsonrpc" => "2.0", "method" => method} = params when is_map(params) ->
        # Notification (no id) — acknowledge but don't respond with result
        dispatch_notification(conn, method, params["params"])

      %{"method" => _method} ->
        # Missing jsonrpc field
        json_rpc_error(conn, nil, -32_600, "Invalid Request: missing jsonrpc field")

      _ ->
        json_rpc_error(conn, nil, -32_600, "Invalid Request")
    end
  end

  defp handle_batch(conn, []) do
    json_rpc_error(conn, nil, -32_600, "Invalid Request: empty batch")
  end

  defp handle_batch(conn, requests) do
    scopes = conn.assigns[:tool_scopes] || ["*"]

    # Partition into requests needing responses vs notifications
    {to_dispatch, notifications_count} =
      Enum.reduce(requests, {[], 0}, fn request, {items, notif_count} ->
        case request do
          %{"jsonrpc" => "2.0", "method" => method, "id" => id} = params ->
            {[{:request, method, id, params["params"]} | items], notif_count}

          %{"jsonrpc" => "2.0", "method" => _method} ->
            {items, notif_count + 1}

          _ ->
            invalid = %{
              jsonrpc: "2.0",
              id: nil,
              error: %{code: -32_600, message: "Invalid Request"}
            }

            {[{:invalid, invalid} | items], notif_count}
        end
      end)

    to_dispatch = Enum.reverse(to_dispatch)
    _ = notifications_count

    # Process requests concurrently — each may hit a different upstream
    responses =
      to_dispatch
      |> Task.async_stream(
        fn
          {:request, method, id, params} ->
            Telemetry.emit_mcp_request(method)
            dispatch_single(method, id, params, scopes)

          {:invalid, response} ->
            response
        end,
        ordered: true,
        max_concurrency: System.schedulers_online()
      )
      |> Enum.zip(to_dispatch)
      |> Enum.map(fn
        {{:ok, result}, _} ->
          result

        {{:exit, reason}, {:request, _method, id, _params}} ->
          Logger.warning("MCP dispatch task crashed: #{inspect(reason)}")
          %{jsonrpc: "2.0", id: id, error: %{code: -32_603, message: "Internal error"}}

        {{:exit, reason}, _} ->
          Logger.warning("MCP dispatch task crashed: #{inspect(reason)}")
          %{jsonrpc: "2.0", id: nil, error: %{code: -32_603, message: "Internal error"}}
      end)

    case responses do
      [] ->
        # All notifications — just acknowledge
        send_resp(conn, 202, "")

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(responses))
    end
  end

  # Batch dispatch: returns a JSON-RPC response map (no conn)
  defp dispatch_single("tools/list", id, params, scopes) do
    case compute_result("tools/list", id, params) do
      {:result, %{tools: tools} = result} ->
        filtered = Clients.filter_tools(tools, scopes)
        %{jsonrpc: "2.0", id: id, result: %{result | tools: filtered}}
    end
  end

  defp dispatch_single("tools/call", id, %{"name" => name} = params, scopes)
       when is_binary(name) and name != "" do
    if Clients.scope_matches?(scopes, name) do
      case compute_result("tools/call", id, params) do
        {:result, result} ->
          %{jsonrpc: "2.0", id: id, result: result}

        {:error, code, message} ->
          %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
      end
    else
      %{
        jsonrpc: "2.0",
        id: id,
        error: %{code: -32_001, message: "Tool '#{name}' is not in scope for this client"}
      }
    end
  end

  defp dispatch_single(method, id, params, _scopes) do
    case compute_result(method, id, params) do
      {:result, result} -> %{jsonrpc: "2.0", id: id, result: result}
      {:error, code, message} -> %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
    end
  end

  defp compute_result("initialize", _id, _params) do
    {:result, initialize_result()}
  end

  defp compute_result("tools/list", _id, _params) do
    tools =
      ToolRegistry.list_all()
      |> Enum.map(fn tool ->
        %{name: tool.name, description: tool.description, inputSchema: tool.input_schema}
      end)

    {:result, %{tools: tools}}
  end

  defp compute_result("tools/call", _id, %{"name" => name} = params)
       when is_binary(name) and name != "" do
    arguments = params["arguments"] || %{}

    case validate_tool_args(name, arguments) do
      :ok ->
        Backplane.PubSubBroadcaster.broadcast_tools_call(:dispatched, %{tool: name})

        case dispatch_tool_call(name, arguments) do
          {:ok, result} ->
            Backplane.PubSubBroadcaster.broadcast_tools_call(:completed, %{tool: name})
            {:result, %{content: [%{type: "text", text: format_result(result)}]}}

          {:error, message} ->
            Backplane.PubSubBroadcaster.broadcast_tools_call(:failed, %{
              tool: name,
              reason: message
            })

            {:result, %{content: [%{type: "text", text: format_error(message)}], isError: true}}
        end

      {:error, reason} ->
        {:error, -32_602, "Invalid params: #{reason}"}
    end
  end

  defp compute_result("tools/call", _id, _params) do
    {:error, -32_602, "Invalid params: 'name' is required"}
  end

  defp compute_result("resources/list", _id, params) do
    cursor = if is_map(params), do: params["cursor"]
    {resources, next_cursor} = list_resources(cursor)
    result = %{resources: resources}
    result = if next_cursor, do: Map.put(result, :nextCursor, next_cursor), else: result
    {:result, result}
  end

  defp compute_result("resources/read", _id, %{"uri" => uri}) when is_binary(uri) do
    {:error, -32_602, "Resource not found: #{uri}"}
  end

  defp compute_result("resources/read", _id, _params) do
    {:error, -32_602, "Invalid params: 'uri' is required"}
  end

  defp compute_result("prompts/list", _id, _params), do: {:result, %{prompts: list_prompts()}}

  defp compute_result("prompts/get", _id, %{"name" => name}) when is_binary(name) do
    case get_prompt(name) do
      {:ok, prompt} -> {:result, prompt}
      {:error, reason} -> {:error, -32_602, "Prompt not found: #{reason}"}
    end
  end

  defp compute_result("prompts/get", _id, _params) do
    {:error, -32_602, "Invalid params: 'name' is required"}
  end

  defp compute_result("completion/complete", _id, %{"ref" => ref, "argument" => argument})
       when is_map(ref) and is_map(argument) do
    completions = compute_completions(ref, argument)
    {:result, %{completion: %{values: completions, hasMore: false, total: length(completions)}}}
  end

  defp compute_result("completion/complete", _id, _params) do
    {:error, -32_602, "Invalid params: 'ref' and 'argument' are required"}
  end

  defp compute_result("logging/setLevel", _id, %{"level" => level})
       when level in ~w(debug info notice warning error critical alert emergency) do
    Logger.configure(level: String.to_existing_atom(level))
    Logger.info("MCP client set log level to #{level}")
    {:result, %{}}
  end

  defp compute_result("logging/setLevel", _id, _params) do
    {:error, -32_602,
     "Invalid params: 'level' must be one of: debug, info, notice, warning, error, critical, alert, emergency"}
  end

  defp compute_result("ping", _id, _params), do: {:result, %{}}

  defp compute_result(_method, _id, _params), do: {:error, -32_601, "Method not found"}

  defp dispatch(conn, "initialize", id, params) do
    client_version = get_in(params || %{}, ["protocolVersion"])

    if client_version && client_version != Backplane.protocol_version() do
      Logger.warning(
        "Client requested unsupported protocol version: #{client_version} (server supports #{Backplane.protocol_version()})"
      )
    end

    session_id = generate_session_id()

    conn
    |> put_resp_header("mcp-session-id", session_id)
    |> json_rpc_result(id, initialize_result())
  end

  defp dispatch(conn, "tools/list", id, params) do
    {:result, %{tools: tools}} = compute_result("tools/list", id, params)
    scopes = conn.assigns[:tool_scopes] || ["*"]
    filtered = Clients.filter_tools(tools, scopes)
    result = %{tools: filtered}
    etag = tools_etag(filtered)
    client_etag = get_req_header(conn, "if-none-match")

    if client_etag == [etag] do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_header("etag", etag)
      |> json_rpc_result(id, result)
    end
  end

  defp dispatch(conn, "tools/call", id, %{"name" => name} = params)
       when is_binary(name) and name != "" do
    scopes = conn.assigns[:tool_scopes] || ["*"]

    if Clients.scope_matches?(scopes, name) do
      arguments = params["arguments"] || %{}

      case validate_tool_args(name, arguments) do
        :ok -> dispatch_validated_tool_call(conn, id, name, arguments)
        {:error, reason} -> json_rpc_error(conn, id, -32_602, "Invalid params: #{reason}")
      end
    else
      json_rpc_error(conn, id, -32_001, "Tool '#{name}' is not in scope for this client")
    end
  end

  # All remaining methods delegate to compute_result to avoid duplication
  defp dispatch(conn, method, id, params) do
    case compute_result(method, id, params) do
      {:result, result} -> json_rpc_result(conn, id, result)
      {:error, code, message} -> json_rpc_error(conn, id, code, message)
    end
  end

  defp dispatch_notification(conn, "notifications/initialized", _params) do
    # Client acknowledges initialization — no action needed for stateless server
    send_resp(conn, 202, "")
  end

  defp dispatch_notification(conn, "notifications/cancelled", _params) do
    # Client requests cancellation — stateless per-request, so just acknowledge
    send_resp(conn, 202, "")
  end

  defp dispatch_notification(conn, _method, _params) do
    send_resp(conn, 202, "")
  end

  defp dispatch_validated_tool_call(conn, id, name, arguments) do
    if SSE.streaming_requested?(conn) do
      dispatch_tool_call_sse(conn, id, name, arguments)
    else
      dispatch_tool_call_json(conn, id, name, arguments)
    end
  end

  defp dispatch_tool_call_json(conn, id, name, arguments) do
    case dispatch_tool_call(name, arguments) do
      {:ok, result} ->
        json_rpc_result(conn, id, %{
          content: [%{type: "text", text: format_result(result)}]
        })

      {:error, message} ->
        json_rpc_result(conn, id, %{
          content: [%{type: "text", text: format_error(message)}],
          isError: true
        })
    end
  end

  defp dispatch_tool_call_sse(conn, id, name, arguments) do
    start_time = System.monotonic_time()
    Telemetry.emit_sse_start(name)
    conn = SSE.start_stream(conn)

    conn =
      case dispatch_tool_call(name, arguments) do
        {:ok, result} ->
          SSE.send_event(conn, id, %{
            content: [%{type: "text", text: format_result(result)}]
          })

        {:error, message} ->
          SSE.send_event(conn, id, %{
            content: [%{type: "text", text: format_error(message)}],
            isError: true
          })
      end

    duration = System.monotonic_time() - start_time
    Telemetry.emit_sse_stop(name, duration)
    conn
  end

  defp validate_tool_args(name, arguments) do
    case ToolRegistry.lookup(name) do
      %{input_schema: schema} when is_map(schema) ->
        InputValidator.validate(arguments, schema)

      _ ->
        :ok
    end
  end

  @doc "Execute a tool call by name. Used by admin UI test call form."
  def dispatch_tool_call(name, args) do
    Telemetry.span_tool_call(name, fn ->
      name |> ToolRegistry.resolve() |> execute_tool(name, args)
    end)
  end

  defp execute_tool({:native, module, handler}, name, args) do
    call_args = if handler, do: Map.put(args, "_handler", to_string(handler)), else: args
    module.call(call_args)
  rescue
    e ->
      Logger.error(
        "Native tool crash: tool=#{name} module=#{inspect(module)} handler=#{inspect(handler)} error=#{Exception.message(e)}"
      )

      {:error, "Tool #{name} failed: #{Exception.message(e)}"}
  end

  defp execute_tool({:upstream, upstream_pid, original_tool_name, timeout}, name, args) do
    # Check if upstream tool caching is configured
    case upstream_cache_ttl(name) do
      nil ->
        forward_upstream(upstream_pid, original_tool_name, name, args, timeout)

      ttl_ms ->
        key = Backplane.Cache.KeyBuilder.upstream(upstream_prefix(name), name, args)

        case Backplane.Cache.get(key) do
          {:ok, cached} ->
            cached

          :miss ->
            result = forward_upstream(upstream_pid, original_tool_name, name, args, timeout)

            case result do
              {:ok, _} -> Backplane.Cache.put(key, result, ttl_ms)
              _ -> :ok
            end

            result
        end
    end
  end

  defp execute_tool({:managed, handler}, name, args) when is_function(handler, 1) do
    case handler.(args) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, "Managed tool #{name} failed: #{reason}"}
    end
  rescue
    e -> {:error, "Managed tool #{name} failed: #{Exception.message(e)}"}
  end

  defp execute_tool(:not_found, name, _args) do
    {:error, "Unknown tool: #{name}. Use tools/list to see available tools."}
  end

  defp forward_upstream(upstream_pid, original_tool_name, name, args, timeout) do
    case Upstream.forward(upstream_pid, original_tool_name, args, timeout) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        Logger.warning(
          "Upstream tool call failed: tool=#{name} original=#{original_tool_name} error=#{inspect(reason)}"
        )

        {:error, "Tool #{name} failed: #{reason}"}
    end
  end

  defp upstream_prefix(namespaced_name) do
    case String.split(namespaced_name, "::", parts: 2) do
      [prefix, _] -> prefix
      _ -> namespaced_name
    end
  end

  defp upstream_cache_ttl(tool_name) do
    prefix = upstream_prefix(tool_name)
    upstreams = Application.get_env(:backplane, :upstreams, [])

    case Enum.find(upstreams, fn u -> u[:prefix] == prefix || u["prefix"] == prefix end) do
      nil ->
        nil

      upstream ->
        cache_ttl = upstream[:cache_ttl] || upstream["cache_ttl"]
        cache_tools = upstream[:cache_tools] || upstream["cache_tools"]

        cond do
          is_nil(cache_ttl) -> nil
          is_nil(cache_tools) -> parse_ttl(cache_ttl)
          tool_name in cache_tools -> parse_ttl(cache_ttl)
          true -> nil
        end
    end
  end

  defp parse_ttl(ttl) when is_integer(ttl), do: ttl

  defp parse_ttl(ttl) when is_binary(ttl) do
    case Backplane.Utils.parse_interval(ttl) do
      {:ok, seconds} -> seconds * 1000
      :error -> nil
    end
  end

  defp parse_ttl(_), do: nil

  # Resources: no longer backed by doc chunks — return empty

  defp list_resources(_cursor), do: {[], nil}

  # Prompts: skills as MCP prompts

  defp list_prompts do
    SkillsRegistry.list()
    |> Enum.map(fn skill ->
      %{
        name: skill.name,
        description: skill.description,
        arguments: build_prompt_arguments(skill)
      }
    end)
  end

  defp get_prompt(name) do
    skills = SkillsRegistry.list()

    case Enum.find(skills, &(&1.name == name)) do
      nil ->
        {:error, "not found"}

      skill ->
        {:ok,
         %{
           description: skill.description,
           messages: [
             %{
               role: "user",
               content: %{type: "text", text: skill.content || ""}
             }
           ]
         }}
    end
  end

  defp build_prompt_arguments(skill) do
    tools = skill[:tools] || []

    Enum.map(tools, fn tool ->
      %{name: tool, description: "Tool required: #{tool}", required: false}
    end)
  end

  # Completion: provide auto-complete values for tool/prompt arguments
  defp compute_completions(
         %{"type" => "ref/tool", "name" => tool_name},
         %{"name" => arg_name} = arg
       ) do
    value = arg["value"] || ""
    complete_tool_argument(tool_name, arg_name, value)
  end

  defp compute_completions(
         %{"type" => "ref/prompt", "name" => prompt_name},
         %{"name" => _} = arg
       ) do
    value = arg["value"] || ""
    complete_prompt_argument(prompt_name, value)
  end

  defp compute_completions(_ref, _argument), do: []

  defp complete_tool_argument(tool_name, arg_name, prefix) do
    case {tool_name, arg_name} do
      {_, "skill_id"} ->
        SkillsRegistry.list()
        |> Enum.map(& &1.id)
        |> filter_by_prefix(prefix)

      {_, "tool_name"} ->
        ToolRegistry.list_all()
        |> Enum.map(& &1.name)
        |> filter_by_prefix(prefix)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp complete_prompt_argument(_prompt_name, _prefix), do: []

  defp filter_by_prefix(values, ""), do: Enum.take(values, 20)

  defp filter_by_prefix(values, prefix) do
    values
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.take(20)
  end

  defp tools_etag(tools) do
    hash = :erlang.phash2(tools)
    "\"bp-tools-#{hash}\""
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp format_result(result) when is_binary(result), do: result

  defp format_result(result) do
    case Jason.encode(result) do
      {:ok, json} -> json
      {:error, _} -> inspect(result)
    end
  end

  defp format_error(message) when is_binary(message), do: message
  defp format_error(message), do: inspect(message)

  defp json_rpc_result(conn, id, result) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: id,
        result: result
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp json_rpc_error(conn, id, code, message) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: id,
        error: %{code: code, message: message}
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end
end
