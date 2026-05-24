defmodule Backplane.HostAgent.MemoryRouter do
  @moduledoc """
  Local HTTP API exposed by the host agent for managing agent memory.

  Two endpoint families, both scoped by `:agent_id`:

  * `POST /memory/:agent_id/call/:method` — direct method invocation. The
    JSON request body becomes the method's argument map; `agent_id` is
    injected automatically.

  * `POST /memory/:agent_id/mcp` — JSON-RPC subset speaking MCP. Supports
    `tools/list` (lists memory tools) and `tools/call` (routes to the same
    handler as `/call/:method`).

  All operations are forwarded to the Backplane hub through the
  host-agent WebSocket channel; the hub authenticates via the host's
  bearer token (established when the channel was joined).
  """

  use Plug.Router

  alias Backplane.HostAgent.MemoryProxy

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  post "/:agent_id/call/:method" do
    args =
      case conn.body_params do
        %Plug.Conn.Unfetched{} -> %{}
        map when is_map(map) -> map
        _ -> %{}
      end

    case MemoryProxy.call(method, args, agent_id: agent_id) do
      {:ok, result} ->
        send_json(conn, 200, %{"ok" => true, "result" => result})

      {:error, {:unknown_method, name}} ->
        send_json(conn, 404, %{"ok" => false, "error" => "unknown method: #{name}"})

      {:error, :not_connected} ->
        send_json(conn, 503, %{"ok" => false, "error" => "host agent is not connected"})

      {:error, reason} ->
        send_json(conn, 400, %{"ok" => false, "error" => format_error(reason)})
    end
  end

  post "/:agent_id/mcp" do
    body = conn.body_params || %{}
    handle_jsonrpc(conn, agent_id, body)
  end

  match _ do
    send_json(conn, 404, %{"ok" => false, "error" => "not found"})
  end

  defp handle_jsonrpc(conn, agent_id, %{"jsonrpc" => "2.0", "id" => id, "method" => method} = req) do
    params = Map.get(req, "params", %{})

    case method do
      "tools/list" ->
        send_json(conn, 200, jsonrpc_result(id, %{"tools" => tool_descriptors()}))

      "tools/call" ->
        tool_call(conn, id, agent_id, params)

      "initialize" ->
        send_json(
          conn,
          200,
          jsonrpc_result(id, %{
            "protocolVersion" => "2025-03-26",
            "serverInfo" => %{"name" => "backplane-host-agent-memory", "version" => "0.1.0"},
            "capabilities" => %{"tools" => %{}}
          })
        )

      "ping" ->
        send_json(conn, 200, jsonrpc_result(id, %{}))

      _ ->
        send_json(
          conn,
          200,
          jsonrpc_error(id, -32_601, "Method not found: #{method}")
        )
    end
  end

  defp handle_jsonrpc(conn, _agent_id, _other) do
    send_json(
      conn,
      400,
      %{"ok" => false, "error" => "invalid JSON-RPC request"}
    )
  end

  defp tool_call(conn, id, agent_id, %{"name" => name, "arguments" => args})
       when is_binary(name) and is_map(args) do
    method = strip_prefix(name)

    case MemoryProxy.call(method, args, agent_id: agent_id) do
      {:ok, result} ->
        send_json(
          conn,
          200,
          jsonrpc_result(id, %{
            "content" => [%{"type" => "text", "text" => Jason.encode!(result)}],
            "isError" => false
          })
        )

      {:error, {:unknown_method, _}} ->
        send_json(
          conn,
          200,
          jsonrpc_error(id, -32_601, "Unknown memory method: #{method}")
        )

      {:error, :not_connected} ->
        send_json(conn, 200, jsonrpc_error(id, -32_002, "host agent is not connected"))

      {:error, reason} ->
        send_json(conn, 200, jsonrpc_error(id, -32_000, format_error(reason)))
    end
  end

  defp tool_call(conn, id, _agent_id, _params) do
    send_json(conn, 200, jsonrpc_error(id, -32_602, "Invalid params for tools/call"))
  end

  defp strip_prefix("memory::" <> rest), do: rest
  defp strip_prefix(name), do: name

  defp tool_descriptors do
    Enum.map(MemoryProxy.methods(), fn method ->
      %{"name" => "memory::#{method}", "description" => "Memory operation: #{method}"}
    end)
  end

  defp jsonrpc_result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp jsonrpc_error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(%{"reason" => reason}) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
