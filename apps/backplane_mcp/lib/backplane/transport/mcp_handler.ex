defmodule Backplane.Transport.McpHandler do
  @moduledoc """
  JSON-RPC dispatcher for MCP protocol messages.

  Handles: initialize, tools/list, tools/call, resources/list, resources/read,
  prompts/list, prompts/get, completion/complete, logging/setLevel, ping,
  elicitation/create, tasks/create, tasks/get, tasks/result, tasks/cancel.

  Adapts responses based on the negotiated MCP protocol version:
  - 2024-11-05: Base capabilities (no completions)
  - 2025-03-26: Adds completions, tool annotations
  - 2025-06-18: Adds outputSchema, structuredContent, elicitation
  - 2025-11-25: Adds icon metadata, experimental tasks, extensions
  """

  import Plug.Conn

  require Logger

  alias Backplane.Clients
  alias Backplane.MCP.Info
  alias Backplane.McpProtocol.{JsonRpc, Message}
  alias Backplane.Proxy.Upstream
  alias Backplane.Registry.{InputValidator, ToolRegistry}
  alias Backplane.Skills.Registry, as: SkillsRegistry
  alias Backplane.Telemetry
  alias Backplane.Transport.{Extensions, Session, SSE, TaskManager}

  @server_name "backplane"

  defp initialize_result(version, params) do
    capabilities = Info.capabilities_for_version(version)

    # For 2025-11-25, include negotiated extensions
    capabilities =
      if Info.version_gte?(version, "2025-11-25") do
        client_extensions = get_in(params || %{}, ["capabilities", "extensions"]) || %{}
        negotiated = Extensions.negotiate(client_extensions)

        if map_size(negotiated) > 0 do
          Map.put(capabilities, :extensions, negotiated)
        else
          capabilities
        end
      else
        capabilities
      end

    result = %{
      protocolVersion: version,
      serverInfo: %{name: @server_name, version: Info.version()},
      capabilities: capabilities
    }

    # Add instructions for 2025-03-26+ (optional server guidance)
    if Info.version_gte?(version, "2025-03-26") do
      Map.put(result, :instructions, server_instructions())
    else
      result
    end
  end

  defp server_instructions do
    "Backplane is an MCP hub. Tools are namespaced as prefix::tool_name. " <>
      "Use hub::discover to find tools by keyword."
  end

  @spec handle(Plug.Conn.t()) :: Plug.Conn.t()
  def handle(conn) do
    case conn.body_params do
      %{"_json" => batch} when is_list(batch) ->
        handle_batch(conn, batch)

      params when is_map(params) ->
        handle_message(conn, params)

      _ ->
        json_rpc_error(conn, nil, -32_600, "Invalid Request")
    end
  end

  defp handle_message(conn, %{"method" => method} = params) do
    cond do
      Message.request?(params) ->
        Telemetry.emit_mcp_request(method)
        dispatch(conn, method, params["id"], params["params"])

      Message.notification?(params) ->
        # Notification (no id) — acknowledge but don't respond with result
        dispatch_notification(conn, method, params["params"])

      not Map.has_key?(params, "jsonrpc") ->
        json_rpc_error(conn, nil, -32_600, "Invalid Request: missing jsonrpc field")

      true ->
        json_rpc_error(conn, nil, -32_600, "Invalid Request")
    end
  end

  defp handle_message(conn, _params), do: json_rpc_error(conn, nil, -32_600, "Invalid Request")

  defp handle_batch(conn, []) do
    json_rpc_error(conn, nil, -32_600, "Invalid Request: empty batch")
  end

  defp handle_batch(conn, requests) do
    scopes = conn.assigns[:tool_scopes] || ["*"]
    client = conn.assigns[:client]

    # Partition into requests needing responses vs notifications
    {to_dispatch, notifications_count} =
      Enum.reduce(requests, {[], 0}, fn request, {items, notif_count} ->
        cond do
          Message.request?(request) ->
            {[{:request, request["method"], request["id"], request["params"]} | items],
             notif_count}

          Message.notification?(request) ->
            {items, notif_count + 1}

          true ->
            invalid = JsonRpc.error(nil, -32_600, "Invalid Request")

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
            dispatch_single(method, id, params, scopes, client)

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
          JsonRpc.error(id, -32_603, "Internal error")

        {{:exit, reason}, _} ->
          Logger.warning("MCP dispatch task crashed: #{inspect(reason)}")
          JsonRpc.error(nil, -32_603, "Internal error")
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
  defp dispatch_single("tools/list", id, params, scopes, _client) do
    case compute_result("tools/list", id, params) do
      {:result, %{tools: tools} = result} ->
        filtered = Clients.filter_tools(tools, scopes)
        JsonRpc.result(id, %{result | tools: filtered})
    end
  end

  defp dispatch_single("tools/call", id, %{"name" => name} = params, scopes, client)
       when is_binary(name) and name != "" do
    if Clients.scope_matches?(scopes, name) do
      case compute_tool_call_result(params, client) do
        {:result, result} ->
          JsonRpc.result(id, result)

        {:error, code, message} ->
          JsonRpc.error(id, code, message)
      end
    else
      JsonRpc.error(id, -32_001, "Tool '#{name}' is not in scope for this client")
    end
  end

  defp dispatch_single(method, id, params, _scopes, _client) do
    case compute_result(method, id, params) do
      {:result, result} -> JsonRpc.result(id, result)
      {:error, code, message} -> JsonRpc.error(id, code, message)
    end
  end

  defp compute_result("initialize", _id, params) do
    client_version = get_in(params || %{}, ["protocolVersion"])
    negotiated = Info.negotiate_version(client_version)
    {:result, initialize_result(negotiated, params)}
  end

  defp compute_result("tools/list", _id, params) do
    # Determine version from session if available
    version = session_version_from_params(params)

    tools =
      ToolRegistry.list_all()
      |> Enum.reject(fn tool -> management_tool?(tool.name) end)
      |> Enum.map(fn tool -> tool_to_json(tool, version) end)

    {:result, %{tools: tools}}
  end

  defp compute_result("tools/call", _id, %{"name" => name} = params)
       when is_binary(name) and name != "" do
    compute_tool_call_result(params, nil)
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

  # Elicitation (2025-06-18+) — stub that always declines
  defp compute_result("elicitation/create", _id, _params) do
    {:result, %{action: "decline", content: %{}}}
  end

  # Tasks (2025-11-25 experimental)
  defp compute_result("tasks/create", _id, %{"name" => tool_name} = params)
       when is_binary(tool_name) and tool_name != "" do
    arguments = params["arguments"] || %{}
    session_id = params["_session_id"]

    case TaskManager.create(tool_name, arguments, session_id) do
      {:ok, task_id} ->
        {:result, %{id: task_id, status: "working"}}

      {:error, reason} ->
        {:error, -32_603, "Failed to create task: #{reason}"}
    end
  end

  defp compute_result("tasks/create", _id, _params) do
    {:error, -32_602, "Invalid params: 'name' is required"}
  end

  defp compute_result("tasks/get", _id, %{"id" => task_id}) when is_binary(task_id) do
    case TaskManager.get(task_id) do
      nil -> {:error, -32_602, "Task not found: #{task_id}"}
      task -> {:result, format_task(task)}
    end
  end

  defp compute_result("tasks/get", _id, _params) do
    {:error, -32_602, "Invalid params: 'id' is required"}
  end

  defp compute_result("tasks/result", _id, %{"id" => task_id}) when is_binary(task_id) do
    case TaskManager.result(task_id) do
      {:ok, result} -> {:result, result}
      {:error, reason} -> {:error, -32_602, reason}
    end
  end

  defp compute_result("tasks/result", _id, _params) do
    {:error, -32_602, "Invalid params: 'id' is required"}
  end

  defp compute_result("tasks/cancel", _id, %{"id" => task_id}) when is_binary(task_id) do
    case TaskManager.cancel(task_id) do
      :ok -> {:result, %{id: task_id, status: "cancelled"}}
      {:error, reason} -> {:error, -32_602, reason}
    end
  end

  defp compute_result("tasks/cancel", _id, _params) do
    {:error, -32_602, "Invalid params: 'id' is required"}
  end

  defp compute_result(_method, _id, _params), do: {:error, -32_601, "Method not found"}

  defp compute_tool_call_result(%{"name" => name} = params, client)
       when is_binary(name) and name != "" do
    arguments = params["arguments"] || %{}

    case validate_tool_args(name, arguments) do
      :ok ->
        Backplane.PubSubBroadcaster.broadcast_tools_call(:dispatched, %{tool: name})

        case dispatch_tool_call(name, arguments) do
          {:ok, result} ->
            maybe_log_skill_load(client, name, result)
            Backplane.PubSubBroadcaster.broadcast_tools_call(:completed, %{tool: name})
            {:result, build_tool_call_result(name, result)}

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

  defp dispatch(conn, "initialize", id, params) do
    client_version = get_in(params || %{}, ["protocolVersion"])
    negotiated = Info.negotiate_version(client_version)
    session_id = generate_session_id()

    # Store session state for version-aware responses
    client_info = get_in(params || %{}, ["clientInfo"]) || %{}
    client_capabilities = get_in(params || %{}, ["capabilities"]) || %{}
    Session.create(session_id, negotiated, client_info, client_capabilities)

    result = initialize_result(negotiated, params)

    conn
    |> put_resp_header("mcp-session-id", session_id)
    |> json_rpc_result(id, result)
  end

  defp dispatch(conn, "tools/list", id, _params) do
    version = session_version(conn)

    tools =
      ToolRegistry.list_all()
      |> Enum.reject(fn tool -> management_tool?(tool.name) end)
      |> Enum.map(fn tool -> tool_to_json(tool, version) end)

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
        maybe_log_skill_load(conn, name, result)
        json_rpc_result(conn, id, build_tool_call_result(name, result))

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
          maybe_log_skill_load(conn, name, result)
          SSE.send_event(conn, id, build_tool_call_result(name, result))

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
      {:ok, result} ->
        {:ok, result}

      {:error, %{message: message}} ->
        {:error, "Managed tool #{name} failed: #{message}"}

      {:error, reason} when is_binary(reason) ->
        {:error, "Managed tool #{name} failed: #{reason}"}

      {:error, reason} ->
        {:error, "Managed tool #{name} failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Managed tool #{name} failed: #{Exception.message(e)}"}
  end

  defp execute_tool(:not_found, name, _args) do
    {:error, "Unknown tool: #{name}. Use tools/list to see available tools."}
  end

  defp maybe_log_skill_load(%Plug.Conn{} = conn, "skill::load", result) when is_map(result) do
    maybe_log_skill_load(conn.assigns[:client], "skill::load", result)
  end

  defp maybe_log_skill_load(client, "skill::load", result) when is_map(result) do
    case result[:name] || result["name"] do
      skill_name when is_binary(skill_name) ->
        result
        |> skill_load_attrs(client, skill_name)
        |> Backplane.Audit.log_skill_load()

      _ ->
        :ok
    end
  end

  defp maybe_log_skill_load(_conn, _name, _result), do: :ok

  defp skill_load_attrs(result, client, skill_name) do
    %{
      skill_name: skill_name,
      loaded_deps: result[:loaded_deps] || result["loaded_deps"] || []
    }
    |> maybe_put_client(client)
  end

  defp maybe_put_client(attrs, %{id: id, name: name}) do
    attrs
    |> Map.put(:client_id, id)
    |> Map.put(:client_name, name)
  end

  defp maybe_put_client(attrs, _client), do: attrs

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
        case SkillsRegistry.fetch(skill.id) do
          {:ok, full_skill} ->
            {:ok,
             %{
               description: full_skill.description,
               messages: [
                 %{
                   role: "user",
                   content: %{type: "text", text: full_skill.content || ""}
                 }
               ]
             }}

          {:error, :not_found} ->
            {:error, "not found"}
        end
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

  defp management_tool?(name) when is_binary(name) do
    String.starts_with?(name, "admin::") or String.starts_with?(name, "hub::")
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  # Version-aware tool serialization

  defp tool_to_json(tool, version) do
    base = %{name: tool.name, description: tool.description, inputSchema: tool.input_schema}

    base =
      if Info.version_gte?(version, "2025-03-26") && tool.annotations do
        Map.put(base, :annotations, tool.annotations)
      else
        base
      end

    base =
      if Info.version_gte?(version, "2025-06-18") && tool.output_schema do
        Map.put(base, :outputSchema, tool.output_schema)
      else
        base
      end

    base =
      if Info.version_gte?(version, "2025-11-25") && tool.icon do
        Map.put(base, :icon, tool.icon)
      else
        base
      end

    base
  end

  # Build tool call result, preserving structuredContent from upstream results

  defp build_tool_call_result(name, result) do
    cond do
      # Upstream result already has content array (passthrough)
      is_map(result) && is_list(result["content"]) ->
        base = %{content: result["content"]}

        base =
          if result["structuredContent"],
            do: Map.put(base, :structuredContent, result["structuredContent"]),
            else: base

        base = if result["isError"], do: Map.put(base, :isError, true), else: base
        base

      # Check if tool has output_schema — include structuredContent
      true ->
        tool = ToolRegistry.lookup(name)

        base = %{content: [%{type: "text", text: format_result(result)}]}

        if tool && tool.output_schema && is_map(result) do
          Map.put(base, :structuredContent, result)
        else
          base
        end
    end
  end

  # Session version helpers

  defp session_version(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [session_id | _] -> Session.protocol_version(session_id)
      [] -> Info.protocol_version()
    end
  end

  defp session_version_from_params(_params) do
    # In batch mode we don't have conn, use latest version
    Info.protocol_version()
  end

  # Task formatting

  defp format_task(task) do
    %{
      id: task.id,
      status: to_string(task.status),
      toolName: task.tool_name
    }
    |> maybe_put(:createdAt, task[:created_at])
    |> maybe_put(:updatedAt, task[:updated_at])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
    body = Jason.encode!(JsonRpc.result(id, result))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp json_rpc_error(conn, id, code, message) do
    body = Jason.encode!(JsonRpc.error(id, code, message))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end
end
