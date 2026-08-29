defmodule Backplane.Transport.McpHandler do
  @moduledoc """
  JSON-RPC dispatcher for MCP protocol messages.

  Handles: initialize, tools/list, tools/call, resources/list, resources/templates/list, resources/read,
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
  alias Backplane.MCP.{Dispatch, Info, JsonRpc}
  alias Backplane.Registry.{InputValidator, ToolRegistry}
  alias Backplane.Telemetry
  alias Backplane.Transport.{Extensions, Session, SSE, TaskManager}

  @server_name "backplane"
  @application_methods ~w(
    tools/list tools/call
    resources/list resources/templates/list resources/read
    prompts/list prompts/get completion/complete
  )

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
    conn = assign(conn, :mcp_protocol_version, session_version(conn))

    case conn.body_params do
      %{"_json" => batch} when is_list(batch) ->
        handle_batch(conn, batch)

      params when is_map(params) ->
        handle_message(conn, params)
    end
  end

  defp handle_message(conn, %{"method" => method} = params) do
    cond do
      request?(params) ->
        Telemetry.emit_mcp_request(method)
        dispatch(conn, method, params["id"], params["params"])

      notification?(params) ->
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
    auth = trusted_auth_context(conn)

    # Partition into requests needing responses vs notifications
    {to_dispatch, notifications_count} =
      Enum.reduce(requests, {[], 0}, fn request, {items, notif_count} ->
        cond do
          request?(request) ->
            {[{:request, request["method"], request["id"], request["params"]} | items],
             notif_count}

          notification?(request) ->
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
            dispatch_single(method, id, params, scopes, client, auth)

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
          Logger.warning("MCP dispatch task crashed", failure: failure_category(reason))
          JsonRpc.error(id, -32_603, "Internal error")

        {{:exit, reason}, _} ->
          Logger.warning("MCP dispatch task crashed", failure: failure_category(reason))
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

  defp request?(%{"jsonrpc" => "2.0", "method" => method} = message) when is_binary(method) do
    Map.has_key?(message, "id")
  end

  defp request?(_message), do: false

  defp notification?(%{"jsonrpc" => "2.0", "method" => method} = message)
       when is_binary(method) do
    not Map.has_key?(message, "id")
  end

  defp notification?(_message), do: false

  # Batch dispatch: returns a JSON-RPC response map (no conn)
  defp dispatch_single(method, id, params, scopes, client, auth)
       when method in @application_methods do
    method
    |> Dispatch.execute(
      params,
      application_context(Info.protocol_version(), scopes, auth, client)
    )
    |> application_json_rpc_response(id)
  end

  defp dispatch_single("tasks/create", id, %{"name" => name} = params, scopes, _client, auth)
       when is_binary(name) and name != "" do
    if Clients.scope_matches?(scopes, name) do
      case create_task(params, auth) do
        {:result, result} -> JsonRpc.result(id, result)
        {:error, code, message} -> JsonRpc.error(id, code, message)
      end
    else
      JsonRpc.error(id, -32_001, "Tool '#{name}' is not in scope for this client")
    end
  end

  defp dispatch_single(method, id, params, _scopes, _client, auth)
       when method in ["tasks/get", "tasks/result", "tasks/cancel"] do
    case task_operation(method, params || %{}, auth) do
      {:result, result} -> JsonRpc.result(id, result)
      {:error, code, message} -> JsonRpc.error(id, code, message)
    end
  end

  defp dispatch_single("logging/setLevel", id, params, scopes, _client, _auth) do
    if logging_authorized?(scopes) do
      result_response(id, compute_result("logging/setLevel", id, params))
    else
      JsonRpc.error(id, -32_001, "logging/setLevel requires an administrative scope")
    end
  end

  defp dispatch_single(method, id, params, _scopes, _client, _auth) do
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

  defp compute_result("logging/setLevel", _id, %{"level" => level})
       when level in ~w(debug info notice warning error critical alert emergency) do
    Logger.info("MCP logging preference accepted", requested_level: level)
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
    _params = params
    {:error, -32_603, "Task creation requires authenticated dispatch"}
  end

  defp compute_result("tasks/create", _id, _params) do
    {:error, -32_602, "Invalid params: 'name' is required"}
  end

  defp compute_result("tasks/get", _id, %{"id" => task_id}) when is_binary(task_id) do
    _task_id = task_id
    {:error, -32_603, "Task access requires authenticated dispatch"}
  end

  defp compute_result("tasks/get", _id, _params) do
    {:error, -32_602, "Invalid params: 'id' is required"}
  end

  defp compute_result("tasks/result", _id, %{"id" => task_id}) when is_binary(task_id) do
    _task_id = task_id
    {:error, -32_603, "Task access requires authenticated dispatch"}
  end

  defp compute_result("tasks/result", _id, _params) do
    {:error, -32_602, "Invalid params: 'id' is required"}
  end

  defp compute_result("tasks/cancel", _id, %{"id" => task_id}) when is_binary(task_id) do
    _task_id = task_id
    {:error, -32_603, "Task access requires authenticated dispatch"}
  end

  defp compute_result("tasks/cancel", _id, _params) do
    {:error, -32_602, "Invalid params: 'id' is required"}
  end

  defp compute_result(_method, _id, _params), do: {:error, -32_601, "Method not found"}

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
    |> assign(:mcp_protocol_version, negotiated)
    |> put_resp_header("mcp-session-id", session_id)
    |> json_rpc_result(id, result)
  end

  defp dispatch(conn, "tools/list", id, params) do
    case Dispatch.execute("tools/list", params, application_context(conn)) do
      {:ok, %{"tools" => tools} = result} ->
        etag = tools_etag(tools)
        client_etag = get_req_header(conn, "if-none-match")

        if client_etag == [etag] do
          send_resp(conn, 304, "")
        else
          conn
          |> put_resp_header("etag", etag)
          |> json_rpc_result(id, result)
        end

      {:error, _reason, _message} = error ->
        application_error_response(conn, id, params, error)
    end
  end

  defp dispatch(conn, "tools/call", id, params) do
    context = application_context(conn)

    if SSE.streaming_requested?(conn) do
      case Dispatch.validate_tool_call(params, context) do
        :ok ->
          name = params["name"]
          start_time = System.monotonic_time()
          Telemetry.emit_sse_start(name)
          conn = SSE.start_stream(conn)

          conn =
            case Dispatch.execute("tools/call", params, context) do
              {:ok, result} ->
                SSE.send_event(conn, id, result)

              {:error, reason, message} ->
                SSE.send_error_event(conn, id, semantic_error_code(reason), message)
            end

          Telemetry.emit_sse_stop(name, System.monotonic_time() - start_time)
          conn

        {:error, _reason, _message} = error ->
          application_error_response(conn, id, params, error)
      end
    else
      result = Dispatch.execute("tools/call", params, context)
      render_application_response(conn, "tools/call", id, params, result)
    end
  end

  defp dispatch(conn, method, id, params) when method in @application_methods do
    result = Dispatch.execute(method, params, application_context(conn))
    render_application_response(conn, method, id, params, result)
  end

  defp dispatch(conn, "tasks/create", id, %{"name" => name} = params)
       when is_binary(name) and name != "" do
    scopes = conn.assigns[:tool_scopes] || ["*"]

    if Clients.scope_matches?(scopes, name) do
      case create_task(params, trusted_auth_context(conn)) do
        {:result, result} -> json_rpc_result(conn, id, result)
        {:error, code, message} -> json_rpc_error(conn, id, code, message)
      end
    else
      application_error_response(
        conn,
        id,
        params,
        {:error, :insufficient_scope, "Tool '#{name}' is not in scope for this client"}
      )
    end
  end

  defp dispatch(conn, method, id, params)
       when method in ["tasks/get", "tasks/result", "tasks/cancel"] do
    case task_operation(method, params || %{}, trusted_auth_context(conn)) do
      {:result, result} -> json_rpc_result(conn, id, result)
      {:error, code, message} -> json_rpc_error(conn, id, code, message)
    end
  end

  defp dispatch(conn, "logging/setLevel", id, params) do
    scopes = conn.assigns[:tool_scopes] || []

    if logging_authorized?(scopes) do
      case compute_result("logging/setLevel", id, params) do
        {:result, result} -> json_rpc_result(conn, id, result)
        {:error, code, message} -> json_rpc_error(conn, id, code, message)
      end
    else
      json_rpc_error(conn, id, -32_001, "logging/setLevel requires an administrative scope")
    end
  end

  # All remaining methods delegate to compute_result to avoid duplication
  defp dispatch(conn, method, id, params) do
    case compute_result(method, id, params) do
      {:result, result} -> json_rpc_result(conn, id, result)
      {:error, code, message} -> json_rpc_error(conn, id, code, message)
    end
  end

  defp render_application_response(conn, _method, id, _params, {:ok, result}) do
    json_rpc_result(conn, id, result)
  end

  defp render_application_response(
         conn,
         _method,
         id,
         params,
         {:error, _reason, _message} = error
       ) do
    application_error_response(conn, id, params, error)
  end

  defp application_error_response(
         conn,
         id,
         params,
         {:error, :insufficient_scope, message}
       ) do
    name = if is_map(params), do: params["name"]

    case conn.assigns[:resource_auth] do
      %{kind: :oauth} ->
        conn
        |> Backplane.Auth.BearerChallenge.put(:mcp,
          error: "insufficient_scope",
          scope: name
        )
        |> json_rpc_error(id, -32_001, message, 403)

      _other ->
        json_rpc_error(conn, id, -32_001, message)
    end
  end

  defp application_error_response(conn, id, _params, {:error, reason, message}) do
    json_rpc_error(conn, id, semantic_error_code(reason), message)
  end

  defp application_json_rpc_response({:ok, result}, id), do: JsonRpc.result(id, result)

  defp application_json_rpc_response({:error, reason, message}, id) do
    JsonRpc.error(id, semantic_error_code(reason), message)
  end

  defp semantic_error_code(:method_not_found), do: -32_601
  defp semantic_error_code(:insufficient_scope), do: -32_001
  defp semantic_error_code(reason) when reason in [:invalid_params, :not_found], do: -32_602
  defp semantic_error_code(:internal_error), do: -32_603

  defp application_context(conn) do
    application_context(
      session_version(conn),
      conn.assigns[:tool_scopes] || ["*"],
      trusted_auth_context(conn),
      conn.assigns[:client]
    )
  end

  defp application_context(protocol_version, scopes, auth, client) do
    %{
      protocol_version: protocol_version,
      scopes: scopes,
      auth: auth,
      client: client
    }
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

  defp validate_tool_args(name, arguments) do
    case ToolRegistry.lookup(name) do
      %{input_schema: schema} when is_map(schema) ->
        InputValidator.validate(arguments, schema)

      _ ->
        :ok
    end
  end

  @doc "Execute a tool call by name. Used by admin UI test call form."
  def dispatch_tool_call(name, args), do: dispatch_tool_call(name, args, %{})

  def dispatch_tool_call(name, args, auth) when is_map(auth) do
    Dispatch.call_tool(name, args, auth)
  end

  defp create_task(%{"name" => tool_name} = params, auth) do
    arguments = params["arguments"] || %{}

    case validate_tool_args(tool_name, arguments) do
      :ok ->
        case TaskManager.create(tool_name, arguments, params["_session_id"], auth) do
          {:ok, task_id} -> {:result, %{id: task_id, status: "working"}}
          {:error, reason} -> {:error, -32_603, "Failed to create task: #{reason}"}
        end

      {:error, reason} ->
        {:error, -32_602, "Invalid params: #{reason}"}
    end
  end

  defp task_operation("tasks/get", %{"id" => task_id}, auth) when is_binary(task_id) do
    case TaskManager.get(task_id, auth) do
      nil -> {:error, -32_602, "Task not found"}
      task -> {:result, format_task(task)}
    end
  end

  defp task_operation("tasks/result", %{"id" => task_id}, auth) when is_binary(task_id) do
    case TaskManager.result(task_id, auth) do
      {:ok, result} -> {:result, result}
      {:error, "task not found"} -> {:error, -32_602, "Task not found"}
      {:error, reason} -> {:error, -32_602, reason}
    end
  end

  defp task_operation("tasks/cancel", %{"id" => task_id}, auth) when is_binary(task_id) do
    case TaskManager.cancel(task_id, auth) do
      :ok -> {:result, %{id: task_id, status: "cancelled"}}
      {:error, "task not found"} -> {:error, -32_602, "Task not found"}
      {:error, reason} -> {:error, -32_602, reason}
    end
  end

  defp task_operation(_method, _params, _auth) do
    {:error, -32_602, "Invalid params: 'id' is required"}
  end

  defp trusted_auth_context(conn) do
    case conn.assigns[:resource_auth] do
      auth when is_map(auth) ->
        Map.take(auth, [:kind, :client_id, :scopes, :subject, :principal_metadata])

      _ ->
        %{kind: :open, client_id: nil, scopes: [], subject: nil, principal_metadata: %{}}
    end
  end

  defp logging_authorized?(scopes) when is_list(scopes) do
    Enum.any?(scopes, &(&1 in ["*", "memory.admin", "admin::*"]))
  end

  defp logging_authorized?(_scopes), do: false

  defp failure_category(%module{}), do: inspect(module)
  defp failure_category(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_category(_reason), do: "runtime_failure"

  defp result_response(id, {:result, result}), do: JsonRpc.result(id, result)
  defp result_response(id, {:error, code, message}), do: JsonRpc.error(id, code, message)

  defp tools_etag(tools) do
    hash = :erlang.phash2(tools)
    "\"bp-tools-#{hash}\""
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  # Session version helpers

  defp session_version(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [session_id | _] -> Session.protocol_version(session_id)
      [] -> Info.protocol_version()
    end
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

  defp json_rpc_result(conn, id, result) do
    body = Jason.encode!(JsonRpc.result(id, result))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp json_rpc_error(conn, id, code, message, status \\ 200) do
    body = Jason.encode!(JsonRpc.error(id, code, message))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end
end
