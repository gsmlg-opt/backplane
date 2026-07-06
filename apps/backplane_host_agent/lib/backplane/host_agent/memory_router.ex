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

  alias Backplane.HostAgent.HubProxy
  alias Backplane.HostAgent.Services
  alias Backplane.HostAgent.Trace

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

  post "/mcp" do
    handle_mcp(conn, nil)
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

    case Backplane.HostAgent.Services.Memory.call(method, args, %{agent_id: agent_id}) do
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
    ctx = trace_context(conn)

    Trace.with_ctx(ctx, fn ->
      span_mcp_request(conn, agent_id, body, fn ->
        handle_jsonrpc(conn, agent_id, body)
      end)
    end)
  end

  defp handle_jsonrpc(conn, agent_id, %{"jsonrpc" => "2.0", "id" => id, "method" => method} = req) do
    params = Map.get(req, "params", %{})

    case method do
      "tools/list" ->
        send_json(conn, 200, jsonrpc_result(id, %{"tools" => list_tools()}))

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
    case Services.resolve(name) do
      {:ok, service, bare} ->
        call_local_tool(conn, id, service, bare, args, tool_ctx(agent_id, args))

      :error ->
        route_unknown_tool(conn, id, name, args)
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

  defp call_local_tool(conn, id, service, method, args, ctx) do
    case service.call(method, args, ctx) do
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
          jsonrpc_error(id, -32_601, unknown_method_message(service, method))
        )

      {:error, {:memory_unavailable, _reason}} ->
        send_json(conn, 200, jsonrpc_error(id, -32_002, "local memory is not configured"))

      {:error, reason} ->
        send_json(conn, 200, jsonrpc_error(id, -32_000, format_error(reason)))
    end
  end

  defp route_unknown_tool(conn, id, name, args) do
    case hub_proxy().call_tool(name, args) do
      {:ok, result} ->
        send_json(conn, 200, jsonrpc_result(id, tool_result(result, false)))

      {:error, reason} ->
        send_json(
          conn,
          200,
          jsonrpc_result(id, tool_result(hub_unreachable_message(reason), true))
        )
    end
  end

  defp list_tools do
    local_tools = Services.list_tools()

    case hub_proxy().list_tools() do
      {:ok, hub_tools} -> local_tools ++ reject_local_prefixes(hub_tools)
      {:error, _reason} -> local_tools
    end
  end

  defp reject_local_prefixes(tools) do
    local_prefixes = Services.services() |> Enum.map(& &1.prefix()) |> MapSet.new()

    Enum.reject(tools, fn tool ->
      tool
      |> tool_name()
      |> local_prefix?()
      |> case do
        {:ok, prefix} -> MapSet.member?(local_prefixes, prefix)
        :error -> false
      end
    end)
  end

  defp tool_name(%{"name" => name}) when is_binary(name), do: name
  defp tool_name(%{name: name}) when is_binary(name), do: name
  defp tool_name(_tool), do: nil

  defp local_prefix?(name) when is_binary(name) do
    case String.split(name, "::", parts: 2) do
      [prefix, _bare] -> {:ok, prefix}
      _ -> :error
    end
  end

  defp local_prefix?(_name), do: :error

  defp tool_result(result, is_error) do
    %{
      "content" => [%{"type" => "text", "text" => format_tool_result(result)}],
      "isError" => is_error
    }
  end

  defp format_tool_result(result) when is_binary(result), do: result
  defp format_tool_result(result), do: Jason.encode!(result)

  defp hub_unreachable_message(reason), do: "hub unreachable: #{format_error(reason)}"

  defp hub_proxy do
    Application.get_env(:backplane_host_agent, :hub_proxy_module, HubProxy)
  end

  defp tool_ctx(nil, args), do: %{agent_id: Map.get(args, "agent_id", "local")}
  defp tool_ctx(agent_id, _args), do: %{agent_id: agent_id}

  defp trace_context(conn) do
    conn
    |> get_req_header("traceparent")
    |> List.first()
    |> Trace.parse_traceparent()
    |> case do
      {:ok, ctx} -> ctx
      :error -> Trace.new_ctx()
    end
  end

  defp span_mcp_request(conn, agent_id, body, fun) do
    metadata = mcp_metadata(conn, agent_id, body)

    :telemetry.span([:backplane, :host_agent, :mcp, :request], metadata, fn ->
      result = fun.()
      {result, Map.put(metadata, :status, result.status)}
    end)
  end

  defp mcp_metadata(conn, agent_id, %{"method" => method} = body) do
    params = Map.get(body, "params", %{})

    %{
      agent_id: agent_id,
      method: method,
      path: conn.request_path,
      tool_name: tool_name_from_params(params)
    }
  end

  defp mcp_metadata(conn, agent_id, _body) do
    %{
      agent_id: agent_id,
      method: nil,
      path: conn.request_path,
      tool_name: nil
    }
  end

  defp tool_name_from_params(%{"name" => name}) when is_binary(name), do: name
  defp tool_name_from_params(_params), do: nil

  defp unknown_method_message(Backplane.HostAgent.Services.Memory, method),
    do: "Unknown memory method: #{method}"

  defp unknown_method_message(service, method),
    do: "Unknown #{service.prefix()} method: #{method}"

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
  defp format_error({:invalid_args, message}) when is_binary(message), do: message
  defp format_error({:storage_error, _reason}), do: "local memory storage error"
  defp format_error(%{"reason" => reason}) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp negotiate_version(nil), do: @mcp_protocol_version
  defp negotiate_version(v) when v in @supported_versions, do: v
  defp negotiate_version(_), do: @mcp_protocol_version
end
