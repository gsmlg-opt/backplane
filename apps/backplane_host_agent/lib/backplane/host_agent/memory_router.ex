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

  alias Backplane.HostAgent.{McpManager, MemoryProxy}

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  post "/memory/:agent_id/call/:method" do
    handle_call(conn, agent_id, method)
  end

  post "/:agent_id/call/:method" do
    handle_call(conn, agent_id, method)
  end

  post "/memory/:agent_id/mcp" do
    handle_mcp(conn, agent_id)
  end

  post "/:agent_id/mcp" do
    handle_mcp(conn, agent_id)
  end

  match _ do
    send_json(conn, 404, %{"ok" => false, "error" => "not found"})
  end

  defp handle_call(conn, agent_id, method) do
    args =
      case conn.body_params do
        %Plug.Conn.Unfetched{} -> %{}
        map when is_map(map) -> direct_call_args(map, method)
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

  defp handle_mcp(conn, agent_id) do
    body = conn.body_params || %{}
    handle_jsonrpc(conn, agent_id, body)
  end

  defp handle_jsonrpc(conn, agent_id, %{"jsonrpc" => "2.0", "id" => id, "method" => method} = req) do
    params = Map.get(req, "params", %{})

    case method do
      "tools/list" ->
        send_json(conn, 200, jsonrpc_result(id, %{"tools" => tool_descriptors()}))

      "tools/call" ->
        tool_call(conn, id, agent_id, params)

      "initialize" ->
        client_version = params["protocolVersion"]
        negotiated = Backplane.MCP.Info.negotiate_version(client_version)

        send_json(
          conn,
          200,
          jsonrpc_result(id, %{
            "protocolVersion" => negotiated,
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

    # Try memory proxy first for memory:: tools, otherwise route to McpManager
    if String.starts_with?(name, "memory::") do
      call_memory_tool(conn, id, agent_id, method, args)
    else
      call_mcp_tool(conn, id, name, args)
    end
  end

  defp tool_call(conn, id, _agent_id, _params) do
    send_json(conn, 200, jsonrpc_error(id, -32_602, "Invalid params for tools/call"))
  end

  defp strip_prefix("memory::" <> rest), do: rest
  defp strip_prefix(name), do: name

  defp direct_call_args(
         %{"jsonrpc" => "2.0", "method" => body_method, "params" => params} = body,
         path_method
       )
       when is_binary(body_method) and is_map(params) do
    if strip_prefix(body_method) == path_method do
      params
    else
      body
    end
  end

  defp direct_call_args(args, _method), do: args

  defp tool_descriptors do
    memory_tools =
      Enum.map(MemoryProxy.methods(), fn method ->
        %{"name" => "memory::#{method}", "description" => "Memory operation: #{method}"}
      end)

    mcp_tools =
      try do
        McpManager.list_tools()
      catch
        _, _ -> []
      end

    memory_tools ++ mcp_tools
  end

  defp call_memory_tool(conn, id, agent_id, method, args) do
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

  defp call_mcp_tool(conn, id, name, args) do
    case McpManager.call_tool(name, args) do
      {:ok, result} ->
        send_json(
          conn,
          200,
          jsonrpc_result(id, %{
            "content" => [%{"type" => "text", "text" => Jason.encode!(result)}],
            "isError" => false
          })
        )

      {:error, reason} ->
        send_json(
          conn,
          200,
          jsonrpc_result(id, %{
            "content" => [%{"type" => "text", "text" => format_error(reason)}],
            "isError" => true
          })
        )
    end
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
