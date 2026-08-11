if Code.ensure_loaded?(Plug) do
  defmodule Backplane.McpProtocol.Server.Transport.StreamableHTTP.ModernSubscription do
    @moduledoc """
    Owns one modern subscriptions/listen POST and its request-scoped SSE stream.

    Validation and subscription establishment finish before chunked streaming
    begins, so every finite protocol failure remains a JSON response.
    """

    import Plug.Conn

    alias Backplane.McpProtocol.MCP.Error
    alias Backplane.McpProtocol.Protocol.Profile
    alias Backplane.McpProtocol.Server.Modern.Headers
    alias Backplane.McpProtocol.Server.Modern.RequestContext
    alias Backplane.McpProtocol.Server.Modern.Subscriptions
    alias Backplane.McpProtocol.Server.ProfileRouter
    alias Backplane.McpProtocol.SSE.Event
    alias Backplane.McpProtocol.SSE.Streaming

    @keepalive_interval to_timeout(second: 15)

    @spec call(Plug.Conn.t(), map(), map(), map()) :: Plug.Conn.t()
    def call(conn, request, transport_context, opts)
        when is_map(request) and is_map(transport_context) and is_map(opts) do
      with :ok <- require_event_stream(conn),
           {:ok, snapshot} <- snapshot_server(opts),
           routing_context = Map.put(transport_context, :supported_versions, snapshot.supported_versions),
           {:ok, {:modern, %Profile{} = profile}} <- ProfileRouter.route(request, routing_context),
           :ok <- Headers.validate(profile, request, routing_context),
           {:ok, _request_context} <- RequestContext.build(profile, request, routing_context),
           {:ok, conn} <- subscribe_and_stream(conn, request, snapshot, opts) do
        conn
      else
        {:error, :not_acceptable} ->
          send_protocol_error(conn, Error.protocol(:invalid_request), request["id"], 406)

        {:error, %Error{} = error} ->
          send_protocol_error(conn, error, request["id"], modern_http_status(error))

        _failure ->
          send_protocol_error(conn, Error.protocol(:internal_error), request["id"], 200)
      end
    catch
      :exit, _reason ->
        send_protocol_error(conn, Error.protocol(:internal_error), request["id"], 200)
    end

    defp subscribe_and_stream(conn, request, snapshot, opts) do
      with {:ok, hub, hub_monitor} <- monitor_hub(opts.subscriptions) do
        try do
          with {:ok, subscription_ref} <-
                 Subscriptions.subscribe(hub, self(), %{
                   request: request,
                   server_capabilities: snapshot.capabilities,
                   server_info: snapshot.server_info
                 }) do
            {:ok, stream(conn, hub, hub_monitor, subscription_ref)}
          end
        catch
          :exit, _reason -> {:error, Error.protocol(:internal_error)}
        after
          Process.demonitor(hub_monitor, [:flush])
        end
      end
    end

    defp snapshot_server(opts) do
      task =
        Task.Supervisor.async_nolink(opts.task_supervisor, fn ->
          supported_versions = opts.server.supported_protocol_versions()
          capabilities = opts.server.server_capabilities()

          if is_list(supported_versions) and Enum.all?(supported_versions, &is_binary/1) and
               is_map(capabilities) do
            {:ok,
             %{
               supported_versions: supported_versions,
               capabilities: capabilities,
               server_info: safe_server_info(opts.server)
             }}
          else
            {:error, Error.protocol(:internal_error)}
          end
        end)

      case Task.yield(task, opts.timeout) do
        {:ok, result} ->
          result

        {:exit, _reason} ->
          {:error, Error.protocol(:internal_error)}

        nil ->
          _ = Task.shutdown(task, :brutal_kill)
          {:error, Error.protocol(:internal_error)}
      end
    rescue
      _exception -> {:error, Error.protocol(:internal_error)}
    catch
      :exit, _reason -> {:error, Error.protocol(:internal_error)}
    end

    defp safe_server_info(server) do
      info = server.server_info()
      if is_map(info), do: info
    rescue
      _exception -> nil
    catch
      _kind, _reason -> nil
    end

    defp stream(conn, hub, hub_monitor, subscription_ref) do
      conn
      |> Streaming.prepare_connection()
      |> stream_loop(hub_monitor, subscription_ref)
    after
      try do
        Subscriptions.unsubscribe(hub, subscription_ref)
      catch
        :exit, _reason -> :ok
      end
    end

    defp stream_loop(conn, hub_monitor, subscription_ref) do
      receive do
        {:mcp_subscription, ^subscription_ref, envelope} ->
          case chunk_envelope(conn, envelope) do
            {:ok, conn} ->
              if complete?(envelope), do: conn, else: stream_loop(conn, hub_monitor, subscription_ref)

            {:error, _reason} ->
              conn
          end

        {:DOWN, ^hub_monitor, :process, _hub_pid, _reason} ->
          conn

        {:plug_conn, :sent} ->
          stream_loop(conn, hub_monitor, subscription_ref)

        _other ->
          stream_loop(conn, hub_monitor, subscription_ref)
      after
        @keepalive_interval ->
          case Plug.Conn.chunk(conn, ": keepalive\n\n") do
            {:ok, conn} -> stream_loop(conn, hub_monitor, subscription_ref)
            {:error, _reason} -> conn
          end
      end
    end

    defp chunk_envelope(conn, envelope) do
      event = %Event{event: "message", data: JSON.encode!(envelope)}
      Plug.Conn.chunk(conn, Event.encode(event))
    end

    defp complete?(%{"result" => %{"resultType" => "complete"}}), do: true
    defp complete?(_envelope), do: false

    defp monitor_hub(hub) do
      case GenServer.whereis(hub) do
        pid when is_pid(pid) -> {:ok, pid, Process.monitor(pid)}
        _missing -> {:error, Error.protocol(:internal_error)}
      end
    end

    defp require_event_stream(conn) do
      accepted? =
        conn
        |> get_req_header("accept")
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(fn media_range ->
          media_range
          |> String.split(";", parts: 2)
          |> hd()
          |> String.trim()
          |> String.downcase()
        end)
        |> Enum.any?(&(&1 == "text/event-stream"))

      if accepted?, do: :ok, else: {:error, :not_acceptable}
    end

    defp send_protocol_error(conn, error, id, status) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, JSON.encode!(Error.build_json_rpc(error, id)))
    end

    defp modern_http_status(%Error{code: -32_601}), do: 404

    defp modern_http_status(%Error{code: code}) when code in [-32_700, -32_600, -32_602, -32_020, -32_021, -32_022],
      do: 400

    defp modern_http_status(%Error{}), do: 200
  end
end
