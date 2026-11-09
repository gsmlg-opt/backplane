defmodule Backplane.HostAgent.MemoryRouter do
  @moduledoc """
  Local HTTP API exposed by the host agent for agent memory and capture.

  Two memory endpoint families, both scoped by `:agent_id`:

  * `POST /memory/:agent_id/call/:method` — direct invocation of one of the
    five memory tools (`search`, `get`, `recent`, `remember`, `forget`). The
    JSON request body becomes the tool's argument map.

  * `POST /memory/:agent_id/mcp` — JSON-RPC subset speaking MCP. `tools/list`
    advertises the five `memory::*` tools alongside local host-agent services;
    `tools/call` forwards `memory::*` calls to the gateway over the host channel.

  `memory::remember` is stamped with `"agent" => agent_id` when the caller did
  not supply one. Reads are never implicitly filtered by agent. While the
  gateway channel is down, memory calls fail with `gateway_unavailable`.
  """

  use Plug.Router

  alias Backplane.HostAgent.HubProxy
  alias Backplane.HostAgent.Memory.Hooks
  alias Backplane.HostAgent.Memory.Local
  alias Backplane.HostAgent.Memory.Store
  alias Backplane.HostAgent.Memory.UUID7
  alias Backplane.HostAgent.Memory.Spool.Turso, as: CaptureSpool
  alias Backplane.HostAgent.Services
  alias Backplane.HostAgent.Trace
  alias Backplane.MemoryToolContract

  @mcp_protocol_version "2025-11-25"
  @supported_versions ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
  @transport_errors ["gateway_unavailable", "gateway_timeout"]
  @local_read_tools ["memory::search", "memory::get", "memory::recent"]
  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  post "/capture/v1/hooks/:integration/:hook" do
    handle_capture(conn, integration, hook)
  end

  post "/capture/v1/status" do
    handle_capture_status(conn)
  end

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

  defp handle_capture(conn, integration, hook) do
    with {:ok, runtime} <- capture_runtime(),
         {:ok, source} <- capture_body(conn.body_params),
         {:ok, envelope} <- Hooks.normalize(integration, hook, source, runtime),
         {:ok, status, persisted} <- append_capture(runtime, envelope) do
      response =
        %{
          "ok" => true,
          "status" => Atom.to_string(status),
          "event_id" => map_value(persisted, :event_id),
          "idempotency_key" => map_value(persisted, :idempotency_key)
        }

      send_json(conn, 202, response)
    else
      {:error, :unsupported_integration} ->
        send_json(conn, 400, %{"ok" => false, "error" => "unsupported integration"})

      {:error, :unsupported_hook} ->
        send_json(conn, 400, %{"ok" => false, "error" => "unsupported hook"})

      {:error, {:malformed, fields}} ->
        send_json(conn, 400, %{
          "ok" => false,
          "error" => "malformed capture payload",
          "fields" => Enum.map(fields, &Atom.to_string/1)
        })

      {:error, :identity_collision} ->
        send_json(conn, 400, %{"ok" => false, "error" => "capture identity collision"})

      {:error, {:invalid_envelope, fields}} ->
        send_json(conn, 400, %{
          "ok" => false,
          "error" => "malformed capture payload",
          "fields" => Enum.map(fields, &to_string/1)
        })

      {:error, :capture_unavailable} ->
        capture_unavailable(conn)

      {:error, {:persistence, _reason}} ->
        capture_unavailable(conn)
    end
  end

  defp capture_runtime do
    case Application.get_env(:backplane_host_agent, :capture_runtime) do
      %{host_id: host_id, spool: spool} = runtime
      when is_binary(host_id) and host_id != "" and not is_nil(spool) ->
        {:ok, Map.put_new(runtime, :spool_module, CaptureSpool)}

      _ ->
        {:error, :capture_unavailable}
    end
  end

  defp handle_capture_status(conn) do
    with %{"event_ids" => ids} = args <- conn.body_params,
         true <-
           Map.keys(args) -- ~w(event_ids protocol) == [] and is_list(ids) and
             length(ids) in 1..100,
         true <-
           Map.get(args, "protocol", "hermes_capture.v1") in ~w(hermes_capture.v1 openclaw_capture.v1),
         true <- Enum.all?(ids, &uuid?/1),
         {:ok, runtime} <- capture_runtime() do
      items =
        Enum.map(ids, fn id ->
          case runtime.spool_module.event_status(runtime.spool, id) do
            {:ok, %{state: :acknowledged}} ->
              %{"event_id" => id, "status" => "canonical_committed"}

            {:ok, %{state: :dead_letter, reason: reason}} ->
              %{
                "event_id" => id,
                "status" => "rejected",
                "error_code" => capture_error_code(reason)
              }

            {:ok, _} ->
              %{"event_id" => id, "status" => "host_accepted"}

            {:error, :not_found} ->
              %{"event_id" => id, "status" => "unknown"}

            {:error, _} ->
              %{"event_id" => id, "status" => "unknown"}
          end
        end)

      send_json(conn, 200, %{
        "ok" => true,
        "result" => %{
          "protocol" => Map.get(args, "protocol", "hermes_capture.v1"),
          "items" => items
        }
      })
    else
      {:error, :capture_unavailable} -> capture_unavailable(conn)
      _ -> send_json(conn, 400, %{"ok" => false, "error" => "invalid_arguments"})
    end
  end

  defp capture_error_code(reason)
       when reason in [:unauthorized, ":unauthorized"], do: "unauthorized"

  defp capture_error_code(reason)
       when reason in [
              "unauthorized",
              "invalid_event",
              "unsupported_schema",
              "oversized",
              "identity_collision"
            ],
       do: reason

  defp capture_error_code(_), do: "capture_rejected"

  defp uuid?(value), do: is_binary(value) and Regex.match?(@uuid_pattern, value)

  defp capture_body(body) when is_map(body), do: {:ok, body}
  defp capture_body(_body), do: {:error, {:malformed, [:payload]}}

  defp append_capture(runtime, envelope) do
    spool_module = Map.fetch!(runtime, :spool_module)
    spool = Map.fetch!(runtime, :spool)

    case safe_capture_append(spool_module, spool, envelope) do
      {:ok, persisted} -> {:ok, :accepted, persisted}
      {:duplicate, persisted} -> {:ok, :duplicate, persisted}
      {:error, :identity_collision} -> {:error, :identity_collision}
      {:error, fields} when is_list(fields) -> {:error, {:invalid_envelope, fields}}
      {:error, reason} -> {:error, {:persistence, reason}}
    end
  end

  defp safe_capture_append(spool_module, spool, envelope) do
    spool_module.append(spool, envelope)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp capture_unavailable(conn) do
    send_json(conn, 503, %{"ok" => false, "error" => "capture persistence unavailable"})
  end

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp handle_call(conn, agent_id, method) do
    args =
      case conn.body_params do
        map when is_map(map) and not is_struct(map) -> direct_call_args(map, method)
        _ -> %{}
      end

    name = "memory::" <> method

    if memory_tool?(name) do
      case forward_memory_tool(name, args, agent_id) do
        {:ok, result} ->
          send_json(conn, 200, %{"ok" => true, "result" => result})

        {:error, reason} ->
          send_json(conn, direct_error_status(reason), %{"ok" => false, "error" => reason})
      end
    else
      send_json(conn, 404, %{"ok" => false, "error" => "unknown method: #{method}"})
    end
  end

  defp direct_error_status("gateway_unavailable"), do: 503
  defp direct_error_status("gateway_timeout"), do: 504
  defp direct_error_status("not_found"), do: 404
  defp direct_error_status("unauthorized"), do: 403
  defp direct_error_status(_reason), do: 400

  defp direct_call_args(
         %{"jsonrpc" => "2.0", "method" => body_method, "params" => params} = body,
         path_method
       )
       when is_binary(body_method) and is_map(params) do
    if strip_prefix(body_method) == path_method, do: params, else: body
  end

  defp direct_call_args(args, _method), do: args

  defp strip_prefix("memory::" <> rest), do: rest
  defp strip_prefix(name), do: name

  defp memory_tool?(name), do: name in MemoryToolContract.tools()

  defp forward_memory_tool(name, args, agent_id) do
    case local_store() do
      nil -> forward_raw(name, args, agent_id)
      store -> forward_with_local(store, name, args, agent_id)
    end
  end

  defp forward_raw(name, args, agent_id) do
    case hub_proxy().call_tool(name, put_agent(name, args, agent_id)) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, memory_error(reason)}
    end
  end

  # Offline-capable path: successful writes are cached locally, transport
  # failures are queued (writes) or answered from the local cache (reads).
  defp forward_with_local(store, "memory::remember", args, agent_id) do
    request_key = args["request_key"] || "host-agent:" <> UUID7.generate()
    args = Map.put(args, "request_key", request_key)

    case forward_raw("memory::remember", args, agent_id) do
      {:ok, record} ->
        cache_remote(store, record)
        {:ok, record}

      {:error, reason} when reason in @transport_errors ->
        queued_write(
          Local.queue_remember(store, put_agent("memory::remember", args, agent_id), request_key),
          reason
        )

      error ->
        error
    end
  end

  defp forward_with_local(store, "memory::forget" = name, args, agent_id) do
    case forward_raw(name, args, agent_id) do
      {:ok, record} ->
        cache_remote(store, record)
        {:ok, record}

      {:error, reason} when reason in @transport_errors ->
        queued_write(
          Local.queue_forget(store, args["id"], args["reason"] || "forgotten"),
          "gateway_unavailable"
        )

      error ->
        error
    end
  end

  defp forward_with_local(store, name, args, agent_id) when name in @local_read_tools do
    case forward_raw(name, args, agent_id) do
      {:error, reason} when reason in @transport_errors -> local_read(store, name, args, reason)
      other -> other
    end
  end

  defp forward_with_local(_store, name, args, agent_id), do: forward_raw(name, args, agent_id)

  defp cache_remote(store, record) when is_map(record) do
    Local.upsert_remote(store, record)
    :ok
  end

  defp cache_remote(_store, _record), do: :ok

  # A record that cannot be forgotten offline (unknown locally) keeps the
  # original transport error.
  defp queued_write({:ok, record}, _reason), do: {:ok, record}
  defp queued_write({:error, _}, reason), do: {:error, reason}

  defp local_read(store, "memory::search", args, _reason) do
    results = Local.search(store, args["query"] || "", args)
    {:ok, %{"results" => results, "offline" => true, "source" => "local"}}
  end

  defp local_read(store, "memory::recent", args, _reason) do
    {:ok, %{"results" => Local.recent(store, args), "offline" => true, "source" => "local"}}
  end

  defp local_read(store, "memory::get", args, _reason) do
    case Local.get(store, args["id"]) do
      {:ok, record} ->
        {:ok, %{"record" => record, "history" => [], "offline" => true, "source" => "local"}}

      {:error, :not_found} ->
        {:error, "not_found"}
    end
  end

  defp local_store do
    store = Application.get_env(:backplane_host_agent, :local_store, Store)
    if is_atom(store) and Process.whereis(store), do: store
  end

  # Only writes are stamped with the calling agent; reads stay unfiltered
  # unless the caller passes an explicit `agent` filter.
  defp put_agent("memory::remember", args, agent_id)
       when is_binary(agent_id) and agent_id != "",
       do: Map.put_new(args, "agent", agent_id)

  defp put_agent(_name, args, _agent_id), do: args

  defp memory_error(reason) when is_binary(reason), do: reason
  defp memory_error(%{"reason" => reason}) when is_binary(reason), do: reason
  defp memory_error(%{"message" => reason}) when is_binary(reason), do: reason
  defp memory_error(%{"code" => code}) when is_binary(code), do: code
  # A timed-out write may still have been applied by the gateway.
  defp memory_error(:timeout), do: "gateway_timeout"

  defp memory_error(reason) do
    if transport_unavailable?(reason), do: "gateway_unavailable", else: format_error(reason)
  end

  defp transport_unavailable?(reason)
       when reason in [:not_connected, :closed, :disconnected, :noproc],
       do: true

  defp transport_unavailable?({:channel_exit, _reason}), do: true
  defp transport_unavailable?(_reason), do: false

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
            "serverInfo" => %{
              "name" => "backplane-host-agent-memory",
              "version" => Backplane.HostAgent.version()
            },
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

  defp tool_call(conn, id, agent_id, %{"name" => "memory::" <> _ = name, "arguments" => args})
       when is_map(args) do
    result =
      if memory_tool?(name) do
        case forward_memory_tool(name, args, agent_id) do
          {:ok, result} -> tool_result(result, false)
          {:error, reason} -> tool_result(reason, true)
        end
      else
        tool_result("unknown tool: #{name}", true)
      end

    send_json(conn, 200, jsonrpc_result(id, result))
  end

  defp tool_call(conn, id, agent_id, %{"name" => name, "arguments" => args})
       when is_binary(name) and is_map(args) do
    case Services.resolve(name) do
      {:ok, service, bare} ->
        call_local_tool(conn, id, service, bare, name, args, tool_ctx(agent_id, args))

      :error ->
        route_unknown_tool(conn, id, name, args)
    end
  end

  defp tool_call(conn, id, _agent_id, _params) do
    send_json(conn, 200, jsonrpc_error(id, -32_602, "Invalid params for tools/call"))
  end

  defp call_local_tool(conn, id, service, method, full_name, args, ctx) do
    case service.call(method, args, ctx) do
      {:ok, result} ->
        send_json(conn, 200, jsonrpc_result(id, tool_result(result, false)))

      {:error, {:unknown_method, _}} ->
        route_unknown_tool(conn, id, full_name, args)

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
    hub_tools =
      case hub_proxy().list_tools() do
        {:ok, tools} when is_list(tools) ->
          Enum.filter(tools, &match?({:ok, _}, valid_tool_name(&1)))

        _other ->
          []
      end

    hub_by_name = Map.new(hub_tools, &{tool_name(&1), &1})
    local_tools = Services.list_tools()
    local_names = MapSet.new(local_tools, &tool_name/1)

    memory_tools =
      Enum.map(MemoryToolContract.tools(), fn name ->
        Map.get_lazy(hub_by_name, name, fn -> static_memory_tool(name) end)
      end)

    other_hub_tools =
      hub_tools
      |> Enum.reject(fn tool ->
        name = tool_name(tool)
        String.starts_with?(name, "memory::") or MapSet.member?(local_names, name)
      end)
      |> Enum.uniq_by(&tool_name/1)

    memory_tools ++ local_tools ++ other_hub_tools
  end

  defp static_memory_tool(name) do
    %{
      "name" => name,
      "description" => Map.fetch!(MemoryToolContract.descriptions(), name),
      "inputSchema" => Map.fetch!(MemoryToolContract.schemas(), name)
    }
  end

  defp tool_name(%{"name" => name}) when is_binary(name), do: name
  defp tool_name(%{name: name}) when is_binary(name), do: name
  defp tool_name(_tool), do: nil

  defp valid_tool_name(tool) when is_map(tool) do
    case tool_name(tool) do
      name when is_binary(name) -> if(String.trim(name) == "", do: :error, else: {:ok, name})
      _other -> :error
    end
  end

  defp valid_tool_name(_tool), do: :error

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
  defp format_error(%{"reason" => reason}) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp negotiate_version(nil), do: @mcp_protocol_version
  defp negotiate_version(v) when v in @supported_versions, do: v
  defp negotiate_version(_), do: @mcp_protocol_version
end
