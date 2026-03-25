defmodule Backplane.Transport.McpHandler do
  @moduledoc """
  JSON-RPC dispatcher for MCP protocol messages.

  Handles: initialize, tools/list, tools/call, ping.
  """

  import Plug.Conn

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
        json_rpc_error(conn, nil, -32600, "Invalid Request: missing jsonrpc field")

      _ ->
        json_rpc_error(conn, nil, -32600, "Invalid Request")
    end
  end

  defp dispatch(conn, "initialize", id, _params) do
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

    json_rpc_result(conn, id, result)
  end

  defp dispatch(conn, "tools/list", id, _params) do
    tools =
      Backplane.Registry.ToolRegistry.list_all()
      |> Enum.map(fn tool ->
        %{
          name: tool.name,
          description: tool.description,
          inputSchema: tool.input_schema
        }
      end)

    json_rpc_result(conn, id, %{tools: tools})
  end

  defp dispatch(conn, "tools/call", id, params) do
    name = params["name"]
    arguments = params["arguments"] || %{}

    case dispatch_tool_call(name, arguments) do
      {:ok, result} ->
        json_rpc_result(conn, id, %{
          content: [%{type: "text", text: format_result(result)}]
        })

      {:error, message} ->
        json_rpc_result(conn, id, %{
          content: [%{type: "text", text: message}],
          isError: true
        })
    end
  end

  defp dispatch(conn, "ping", id, _params) do
    json_rpc_result(conn, id, %{})
  end

  defp dispatch(conn, _method, id, _params) do
    json_rpc_error(conn, id, -32601, "Method not found")
  end

  defp dispatch_notification(conn, _method, _params) do
    send_resp(conn, 202, "")
  end

  defp dispatch_tool_call(name, args) do
    case Backplane.Registry.ToolRegistry.resolve(name) do
      {:native, module} ->
        module.call(args)

      {:upstream, upstream_pid, original_tool_name} ->
        Backplane.Proxy.Upstream.forward(upstream_pid, original_tool_name, args)

      :not_found ->
        {:error, "Unknown tool: #{name}"}
    end
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
