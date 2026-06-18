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

  Memory operations are local-only and use the host-agent memory store. Hub-only
  memory operations return stable local errors.
  """

  use Plug.Router

  alias Backplane.HostAgent.{McpManager, Memory}
  alias Backplane.HostAgent.Memory.Store

  @mcp_protocol_version "2025-11-25"
  @supported_versions ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

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

    case call_memory(method, args, agent_id) do
      {:ok, result} ->
        send_json(conn, 200, %{"ok" => true, "result" => result})

      {:error, {:unknown_method, name}} ->
        send_json(conn, 404, %{"ok" => false, "error" => "unknown method: #{name}"})

      {:error, {:memory_unavailable, _reason}} ->
        send_json(conn, 503, %{"ok" => false, "error" => "local memory is not configured"})

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
        negotiated = negotiate_version(client_version)

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
      Enum.map(Memory.methods(), fn method ->
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
    case call_memory(method, args, agent_id) do
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

      {:error, {:memory_unavailable, _reason}} ->
        send_json(conn, 200, jsonrpc_error(id, -32_002, "local memory is not configured"))

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

  defp call_memory(method, args, agent_id) do
    if Memory.valid_method?(method) do
      do_call_memory(method, args, memory_opts(agent_id))
    else
      {:error, {:unknown_method, method}}
    end
  rescue
    error -> {:error, {:memory_unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:memory_unavailable, reason}}
  end

  defp do_call_memory("remember", args, opts), do: Memory.remember(args, opts)
  defp do_call_memory("recall", args, opts), do: Memory.recall(args, opts)
  defp do_call_memory("list", args, opts), do: Memory.list(args, opts)
  defp do_call_memory("forget", args, opts), do: Memory.forget(args, opts)
  defp do_call_memory("stats", args, opts), do: Memory.stats(args, opts)
  defp do_call_memory("slot_read", args, opts), do: Memory.slot_read(args, opts)
  defp do_call_memory("slot_write", args, opts), do: Memory.slot_write(args, opts)
  defp do_call_memory("slot_list", args, opts), do: Memory.slot_list(args, opts)
  defp do_call_memory("facet_tag", args, opts), do: Memory.facet_tag(args, opts)
  defp do_call_memory("facet_query", args, opts), do: Memory.facet_query(args, opts)

  defp memory_opts(agent_id) do
    [
      store: Application.get_env(:backplane_host_agent, :memory_store, Store),
      config: Application.get_env(:backplane_host_agent, :memory_config, %{}),
      agent_id: agent_id
    ]
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error({:invalid_args, message}) when is_binary(message), do: message
  defp format_error({:memory_unavailable, _reason}), do: "local memory is not configured"
  defp format_error({:storage_error, _reason}), do: "local memory storage error"
  defp format_error(%{"reason" => reason}) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp negotiate_version(nil), do: @mcp_protocol_version
  defp negotiate_version(v) when v in @supported_versions, do: v
  defp negotiate_version(_), do: @mcp_protocol_version
end
