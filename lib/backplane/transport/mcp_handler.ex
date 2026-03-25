defmodule Backplane.Transport.McpHandler do
  @moduledoc """
  JSON-RPC dispatcher for MCP protocol messages.

  Handles: initialize, tools/list, tools/call, ping.
  """

  import Plug.Conn

  alias Backplane.Proxy.Upstream
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Telemetry
  alias Backplane.Transport.SSE

  @protocol_version "2025-03-26"
  @server_name "backplane"
  @server_version "0.1.0"

  def handle(conn) do
    case conn.body_params do
      %{"jsonrpc" => "2.0", "method" => method, "id" => id} = params ->
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

  defp dispatch(conn, "initialize", id, _params) do
    session_id = generate_session_id()

    result = %{
      protocolVersion: @protocol_version,
      serverInfo: %{
        name: @server_name,
        version: @server_version
      },
      capabilities: %{
        tools: %{listChanged: true}
      }
    }

    conn
    |> put_resp_header("mcp-session-id", session_id)
    |> json_rpc_result(id, result)
  end

  defp dispatch(conn, "tools/list", id, _params) do
    tools =
      ToolRegistry.list_all()
      |> Enum.map(fn tool ->
        %{
          name: tool.name,
          description: tool.description,
          inputSchema: tool.input_schema
        }
      end)

    json_rpc_result(conn, id, %{tools: tools})
  end

  defp dispatch(conn, "tools/call", id, params) when is_map(params) do
    name = params["name"]
    arguments = params["arguments"] || %{}

    if is_binary(name) and name != "" do
      if SSE.streaming_requested?(conn) do
        dispatch_tool_call_sse(conn, id, name, arguments)
      else
        dispatch_tool_call_json(conn, id, name, arguments)
      end
    else
      json_rpc_error(conn, id, -32_602, "Invalid params: 'name' is required")
    end
  end

  defp dispatch(conn, "tools/call", id, _params) do
    json_rpc_error(conn, id, -32_602, "Invalid params: 'params' object is required")
  end

  defp dispatch(conn, "ping", id, _params) do
    json_rpc_result(conn, id, %{})
  end

  defp dispatch(conn, _method, id, _params) do
    json_rpc_error(conn, id, -32_601, "Method not found")
  end

  defp dispatch_notification(conn, _method, _params) do
    send_resp(conn, 202, "")
  end

  defp dispatch_tool_call_json(conn, id, name, arguments) do
    case dispatch_tool_call(name, arguments) do
      {:ok, result} ->
        json_rpc_result(conn, id, %{
          content: [%{type: "text", text: format_result(result)}]
        })

      {:error, message} ->
        json_rpc_result(conn, id, %{
          content: [%{type: "text", text: to_string(message)}],
          isError: true
        })
    end
  end

  defp dispatch_tool_call_sse(conn, id, name, arguments) do
    conn = SSE.start_stream(conn)

    case dispatch_tool_call(name, arguments) do
      {:ok, result} ->
        SSE.send_event(conn, id, %{
          content: [%{type: "text", text: format_result(result)}]
        })

      {:error, message} ->
        SSE.send_event(conn, id, %{
          content: [%{type: "text", text: to_string(message)}],
          isError: true
        })
    end
  end

  defp dispatch_tool_call(name, args) do
    Telemetry.span_tool_call(name, fn ->
      name |> ToolRegistry.resolve() |> execute_tool(args)
    end)
  end

  defp execute_tool({:native, module, handler}, args) do
    call_args = if handler, do: Map.put(args, "_handler", to_string(handler)), else: args
    module.call(call_args)
  end

  defp execute_tool({:upstream, upstream_pid, original_tool_name}, args) do
    Upstream.forward(upstream_pid, original_tool_name, args)
  end

  defp execute_tool(:not_found, _args) do
    {:error, "Unknown tool"}
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp format_result(result) when is_binary(result), do: result
  defp format_result(result), do: Jason.encode!(result)

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
