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

  Core memory operations use the canonical memory facade. Host-only slot, facet,
  and replay operations remain local, while Hub-only memory tools are forwarded.
  """

  use Plug.Router

  alias Backplane.HostAgent.HubProxy
  alias Backplane.HostAgent.Memory.Hooks
  alias Backplane.HostAgent.Memory.RecallCache
  alias Backplane.HostAgent.Memory.Spool.Turso, as: CaptureSpool
  alias Backplane.HostAgent.MemoryProxy
  alias Backplane.HostAgent.Services
  alias Backplane.HostAgent.Services.Memory, as: MemoryService
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

  post "/capture/v1/hooks/:integration/:hook" do
    handle_capture(conn, integration, hook)
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
        |> maybe_add_lifecycle_context(runtime, envelope)

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

  defp maybe_add_lifecycle_context(response, runtime, envelope) do
    with {:ok, request} <- lifecycle_request(runtime, envelope),
         {:ok, context} <- request_lifecycle_context(runtime, request) do
      Map.put(response, "lifecycle_context", context)
    else
      _ -> response
    end
  end

  defp lifecycle_request(runtime, envelope) do
    config = Map.get(runtime, :config, %{})

    with true <- Map.get(config, :inject_context, false) == true,
         {:ok, kind} <- lifecycle_kind(map_value(envelope, :event_type)),
         session_id when is_binary(session_id) and session_id != "" <-
           map_value(envelope, :session_id),
         project when is_binary(project) and project != "" <- map_value(envelope, :project),
         agent_id when is_binary(agent_id) and agent_id != "" <- map_value(envelope, :agent_id) do
      timeout = config |> Map.get(:context_timeout_ms, 1_200) |> bounded_context_timeout()

      {:ok,
       %{
         kind: kind,
         agent_id: agent_id,
         timeout: timeout,
         key: lifecycle_cache_key(kind, project, agent_id, session_id),
         arguments: %{
           "kind" => kind,
           "session_id" => session_id,
           "project" => project
         }
       }}
    else
      _ -> :skip
    end
  end

  defp lifecycle_kind("agent.session.started"), do: {:ok, "session_start"}
  defp lifecycle_kind("agent.context.pre_compact"), do: {:ok, "pre_compact"}
  defp lifecycle_kind(_event_type), do: :skip

  defp lifecycle_cache_key("session_start", project, agent_id, _session_id),
    do: {"session_start", project, agent_id}

  defp lifecycle_cache_key("pre_compact", project, agent_id, session_id),
    do: {"pre_compact", project, agent_id, session_id}

  defp request_lifecycle_context(runtime, request) do
    proxy = Map.get(runtime, :memory_proxy_module, MemoryProxy)

    task =
      Task.async(fn ->
        try do
          proxy.call("lifecycle_context", request.arguments,
            agent_id: request.agent_id,
            timeout: request.timeout
          )
        rescue
          error -> {:error, {:proxy_exception, error}}
        catch
          kind, reason -> {:error, {:proxy_exception, kind, reason}}
        end
      end)

    case Task.yield(task, request.timeout) do
      {:ok, {:ok, result}} ->
        live_context(runtime, request, result)

      {:ok, {:error, reason}} ->
        maybe_cached_context(runtime, request.key, reason)

      {:ok, _other} ->
        :skip

      {:exit, reason} ->
        maybe_cached_context(runtime, request.key, {:task_exit, reason})

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        :timeout
    end
  rescue
    _error -> :skip
  catch
    :exit, _reason -> :skip
  end

  defp live_context(runtime, request, result) when is_map(result) do
    case {map_value(result, :kind), map_value(result, :context)} do
      {kind, context} when kind == request.kind and is_binary(context) ->
        if String.trim(context) == "" do
          :skip
        else
          normalized = stringify_context_metadata(result)

          if cacheable_context?(normalized) do
            maybe_cache_context(runtime, request.key, normalized)
            {:ok, normalized}
          else
            :skip
          end
        end

      _ ->
        :skip
    end
  end

  defp live_context(_runtime, _request, _result), do: :skip

  defp stringify_context_metadata(result) do
    %{
      "kind" => map_value(result, :kind),
      "context" => map_value(result, :context),
      "source_revision" => map_value(result, :source_revision),
      "generated_at" => map_value(result, :generated_at),
      "expires_at" => map_value(result, :expires_at),
      "cached" => false,
      "stale" => false
    }
  end

  defp cacheable_context?(context) do
    strings_present? =
      Enum.all?(~w(context source_revision generated_at expires_at), fn key ->
        case Map.get(context, key) do
          value when is_binary(value) -> String.trim(value) != ""
          _ -> false
        end
      end)

    with true <- strings_present?,
         {:ok, generated_at, _offset} <- DateTime.from_iso8601(context["generated_at"]),
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(context["expires_at"]),
         :gt <- DateTime.compare(expires_at, generated_at),
         :gt <- DateTime.compare(expires_at, DateTime.utc_now()) do
      true
    else
      _ -> false
    end
  end

  defp maybe_cache_context(runtime, key, context) do
    case Map.get(runtime, :recall_cache) do
      nil -> :ok
      cache -> RecallCache.put(cache, key, context)
    end
  catch
    :exit, _reason -> :ok
  end

  defp maybe_cached_context(runtime, key, reason) do
    if transport_unavailable?(reason) do
      cached_context(runtime, key)
    else
      :skip
    end
  end

  defp cached_context(runtime, key) do
    with cache when not is_nil(cache) <- Map.get(runtime, :recall_cache),
         {:ok, %{context: context, age_seconds: age_seconds}} <- RecallCache.get(cache, key),
         cached_text when is_binary(cached_text) <- map_value(context, :context) do
      revision = map_value(context, :source_revision) || "unknown"

      label =
        "[Cached memory context (stale); revision=#{revision}; age=#{age_seconds}s]"

      {:ok,
       context
       |> Map.put("context", label <> "\n\n" <> cached_text)
       |> Map.put("cached", true)
       |> Map.put("stale", true)
       |> Map.put("age_seconds", age_seconds)}
    else
      _ -> :skip
    end
  catch
    :exit, _reason -> :skip
  end

  defp transport_unavailable?(reason)
       when reason in [
              :not_connected,
              :closed,
              :disconnected,
              :econnrefused,
              :econnreset,
              :enetunreach,
              :nxdomain,
              :hub_down
            ],
       do: true

  defp transport_unavailable?({:reconnect_failed, reason}), do: transport_unavailable?(reason)
  defp transport_unavailable?({:reconnect_lock_failed, _reason}), do: true
  defp transport_unavailable?({:transport, reason}), do: transport_unavailable?(reason)
  defp transport_unavailable?({:task_exit, {:noproc, _}}), do: true
  defp transport_unavailable?({:task_exit, :noproc}), do: true
  defp transport_unavailable?({:channel_exit, reason}), do: transport_exit?(reason)
  defp transport_unavailable?({:socket_closed, _reason}), do: true
  defp transport_unavailable?(_reason), do: false

  defp transport_exit?(reason)
       when reason in [
              :noproc,
              :closed,
              :disconnected,
              :econnrefused,
              :econnreset,
              :enetdown,
              :enetunreach,
              :nxdomain
            ],
       do: true

  defp transport_exit?({:noproc, _detail}), do: true
  defp transport_exit?({:socket_closed, _detail}), do: true
  defp transport_exit?({:transport, reason}), do: transport_exit?(reason)
  defp transport_exit?({:shutdown, reason}), do: transport_exit?(reason)
  defp transport_exit?(_reason), do: false

  defp bounded_context_timeout(timeout) when is_integer(timeout) and timeout > 0,
    do: min(timeout, 1_500)

  defp bounded_context_timeout(_timeout), do: 1_200

  defp handle_call(conn, agent_id, method) do
    args =
      case conn.body_params do
        %Plug.Conn.Unfetched{} -> %{}
        map when is_map(map) -> direct_call_args(map, method)
        _ -> %{}
      end

    case Backplane.HostAgent.Services.Memory.call(
           method,
           args,
           memory_service_ctx(conn, agent_id, args)
         ) do
      {:ok, result} ->
        send_json(conn, 200, %{"ok" => true, "result" => result})

      {:error, {:unknown_method, name}} ->
        send_json(conn, 404, %{"ok" => false, "error" => "unknown method: #{name}"})

      {:error, {:memory_unavailable, _reason}} ->
        send_json(conn, 503, %{"ok" => false, "error" => "local memory is not configured"})

      {:error, {:memory_facade_unavailable, _reason}} ->
        send_json(conn, 503, %{
          "ok" => false,
          "error" => "canonical memory facade is unavailable"
        })

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
        call_local_tool(
          conn,
          id,
          service,
          bare,
          name,
          args,
          local_service_ctx(service, conn, agent_id, args)
        )

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

  defp call_local_tool(conn, id, service, method, full_name, args, ctx) do
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
        route_unknown_tool(conn, id, full_name, args)

      {:error, {:memory_unavailable, _reason}} ->
        send_json(conn, 200, jsonrpc_error(id, -32_002, "local memory is not configured"))

      {:error, {:memory_facade_unavailable, _reason}} ->
        send_json(
          conn,
          200,
          jsonrpc_error(id, -32_003, "canonical memory facade is unavailable")
        )

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
      {:ok, hub_tools} when is_list(hub_tools) -> merge_hub_tools(local_tools, hub_tools)
      {:error, _reason} -> local_tools
      _other -> local_tools
    end
  end

  defp merge_hub_tools(local_tools, hub_tools) do
    seen =
      Enum.reduce(local_tools, MapSet.new(), fn tool, names ->
        case valid_tool_name(tool) do
          {:ok, name} -> MapSet.put(names, name)
          :error -> names
        end
      end)

    {_seen, accepted} =
      Enum.reduce(hub_tools, {seen, []}, fn tool, {names, accepted} ->
        case valid_tool_name(tool) do
          {:ok, name} ->
            if MapSet.member?(names, name) do
              {names, accepted}
            else
              {MapSet.put(names, name), [tool | accepted]}
            end

          :error ->
            {names, accepted}
        end
      end)

    local_tools ++ Enum.reverse(accepted)
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

  defp local_service_ctx(MemoryService, conn, agent_id, args),
    do: memory_service_ctx(conn, agent_id, args)

  defp local_service_ctx(_service, _conn, agent_id, args), do: tool_ctx(agent_id, args)

  defp memory_service_ctx(conn, agent_id, args) do
    context = tool_ctx(agent_id, args)

    case conn.private[:backplane_memory_facade] do
      facade when is_atom(facade) and not is_nil(facade) ->
        Map.put(context, :memory_facade, facade)

      _other ->
        context
    end
  end

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
  defp format_error({:storage_error, _reason}), do: "local memory storage error"
  defp format_error(%{"reason" => reason}) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp negotiate_version(nil), do: @mcp_protocol_version
  defp negotiate_version(v) when v in @supported_versions, do: v
  defp negotiate_version(_), do: @mcp_protocol_version
end
