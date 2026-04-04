defmodule Relayixir.Proxy.WebSocket.Bridge do
  @moduledoc """
  Supervised GenServer managing a proxied WebSocket session.
  Relays frames bidirectionally between downstream (Bandit handler) and upstream (Mint.WebSocket).
  Implements explicit state machine: :connecting -> :open -> :closing -> :closed.
  """

  use GenServer

  require Logger

  alias Relayixir.Proxy.WebSocket.{UpstreamClient, Frame, Close}
  alias Relayixir.Proxy.Upstream
  alias Relayixir.Config.HookConfig

  defstruct [
    :session_id,
    :upstream,
    :downstream_pid,
    :downstream_monitor,
    :upstream_conn,
    :upstream_ref,
    :upstream_websocket,
    :started_at,
    :last_activity_at,
    :close_timer,
    status: :connecting,
    close_reason: nil,
    ws_headers: [],
    # Frames queued while upstream is still connecting
    pending_frames: []
  ]

  ## Public API

  @doc """
  Starts a bridge process under the DynamicSupervisor.
  """
  @spec start(pid(), Upstream.t(), [{String.t(), String.t()}]) :: {:ok, pid()} | {:error, term()}
  def start(downstream_pid, %Upstream{} = upstream, ws_headers \\ []) do
    session_id = generate_session_id()

    DynamicSupervisor.start_child(
      Relayixir.Proxy.WebSocket.BridgeSupervisor,
      {__MODULE__, {downstream_pid, upstream, ws_headers, session_id}}
    )
  end

  @spec start_link(tuple()) :: GenServer.on_start()
  def start_link({downstream_pid, upstream, ws_headers, session_id}) do
    GenServer.start_link(__MODULE__, {downstream_pid, upstream, ws_headers, session_id},
      name: via_registry(session_id)
    )
  end

  @doc """
  Sends a frame from downstream (client) to be relayed upstream.
  """
  @spec relay_from_downstream(pid(), Frame.t()) :: :ok
  def relay_from_downstream(bridge_pid, %Frame{} = frame) do
    GenServer.cast(bridge_pid, {:downstream_frame, frame})
  end

  @doc """
  Notifies the bridge that downstream has disconnected.
  """
  @spec downstream_closed(pid(), non_neg_integer(), String.t()) :: :ok
  def downstream_closed(bridge_pid, code \\ 1000, reason \\ "") do
    GenServer.cast(bridge_pid, {:downstream_closed, code, reason})
  end

  @spec child_spec(tuple()) :: Supervisor.child_spec()
  def child_spec({_downstream_pid, _upstream, _ws_headers, _session_id} = args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      type: :worker
    }
  end

  ## GenServer Callbacks

  @impl true
  def init({downstream_pid, upstream, ws_headers, session_id}) do
    now = System.monotonic_time(:millisecond)
    downstream_monitor = Process.monitor(downstream_pid)

    :telemetry.execute(
      [:relayixir, :websocket, :session, :start],
      %{system_time: System.system_time()},
      %{session_id: session_id, upstream: "#{upstream.host}:#{upstream.port}"}
    )

    state = %__MODULE__{
      session_id: session_id,
      upstream: upstream,
      downstream_pid: downstream_pid,
      downstream_monitor: downstream_monitor,
      started_at: now,
      last_activity_at: now,
      status: :connecting,
      ws_headers: ws_headers
    }

    {:ok, state, {:continue, :connect_upstream}}
  end

  @impl true
  def handle_continue(:connect_upstream, state) do
    :telemetry.execute(
      [:relayixir, :websocket, :upstream, :connect, :start],
      %{system_time: System.system_time()},
      %{session_id: state.session_id, upstream: "#{state.upstream.host}:#{state.upstream.port}"}
    )

    case UpstreamClient.connect(state.upstream, state.ws_headers) do
      {:ok, conn, ref, websocket} ->
        Logger.info("WebSocket bridge #{state.session_id}: upstream connected")

        :telemetry.execute(
          [:relayixir, :websocket, :upstream, :connect, :stop],
          %{system_time: System.system_time()},
          %{
            session_id: state.session_id,
            upstream: "#{state.upstream.host}:#{state.upstream.port}",
            result: :ok
          }
        )

        new_state = %{
          state
          | upstream_conn: conn,
            upstream_ref: ref,
            upstream_websocket: websocket,
            status: :open,
            last_activity_at: System.monotonic_time(:millisecond),
            pending_frames: []
        }

        flush_pending_frames(state.pending_frames, new_state)

      {:error, reason} ->
        Logger.error(
          "WebSocket bridge #{state.session_id}: upstream connect failed: #{inspect(reason)}"
        )

        :telemetry.execute(
          [:relayixir, :websocket, :upstream, :connect, :stop],
          %{system_time: System.system_time()},
          %{
            session_id: state.session_id,
            upstream: "#{state.upstream.host}:#{state.upstream.port}",
            result: :error,
            reason: reason
          }
        )

        emit_exception(state, {:upstream_connect_failed, reason})
        send_to_downstream(state, Close.upstream_connect_failed_frame())
        stop_with_reason(state, {:upstream_connect_failed, reason})
    end
  end

  @impl true
  def handle_cast({:downstream_frame, %Frame{type: :close} = frame}, %{status: :open} = state) do
    Logger.debug("WebSocket bridge #{state.session_id}: downstream close received")

    case Close.shutdown_action(:downstream_close, frame.close_code, frame.close_reason) do
      {:propagate_to_upstream, close_frame} ->
        case send_to_upstream(state, close_frame) do
          {:ok, new_state} ->
            timer = Process.send_after(self(), :close_timeout, Close.close_timeout())

            {:noreply,
             %{new_state | status: :closing, close_reason: :downstream_close, close_timer: timer}}

          {:error, state} ->
            stop_with_reason(state, :upstream_send_failed)
        end
    end
  end

  def handle_cast({:downstream_frame, %Frame{} = frame}, %{status: :open} = state) do
    :telemetry.execute(
      [:relayixir, :websocket, :frame, :out],
      %{system_time: System.system_time()},
      %{session_id: state.session_id, type: frame.type}
    )

    invoke_ws_hook(state.session_id, :outbound, frame)

    case send_to_upstream(state, frame) do
      {:ok, new_state} ->
        {:noreply, %{new_state | last_activity_at: System.monotonic_time(:millisecond)}}

      {:error, state} ->
        emit_exception(state, :upstream_send_failed)
        send_to_downstream(state, Close.internal_error_frame())
        stop_with_reason(state, :upstream_send_failed)
    end
  end

  def handle_cast({:downstream_frame, frame}, %{status: :connecting} = state) do
    # Queue frames that arrive before the upstream connection is established.
    # They will be flushed once the Bridge transitions to :open.
    {:noreply, %{state | pending_frames: state.pending_frames ++ [frame]}}
  end

  def handle_cast({:downstream_frame, _frame}, %{status: status} = state)
      when status not in [:open, :connecting] do
    Logger.debug("WebSocket bridge #{state.session_id}: dropping frame in #{status} state")
    {:noreply, state}
  end

  def handle_cast({:downstream_closed, code, reason}, %{status: :open} = state) do
    Logger.info(
      "WebSocket bridge #{state.session_id}: downstream closed with code #{code}: #{reason}"
    )

    case send_to_upstream(state, Frame.close(code, reason)) do
      {:ok, new_state} ->
        timer = Process.send_after(self(), :close_timeout, Close.close_timeout())

        {:noreply,
         %{new_state | status: :closing, close_reason: :downstream_close, close_timer: timer}}

      {:error, state} ->
        stop_with_reason(state, :upstream_send_failed)
    end
  end

  def handle_cast({:downstream_closed, _code, _reason}, state) do
    if state.close_timer, do: Process.cancel_timer(state.close_timer)
    stop_with_reason(state, :downstream_closed)
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{downstream_monitor: ref} = state
      ) do
    Logger.info("WebSocket bridge #{state.session_id}: downstream handler died")
    cleanup_upstream(state)
    stop_with_reason(state, :handler_death)
  end

  def handle_info(:close_timeout, %{status: :closing} = state) do
    Logger.warning("WebSocket bridge #{state.session_id}: close timeout, force terminating")
    cleanup_upstream(state)
    stop_with_reason(state, :close_timeout)
  end

  def handle_info(message, %{status: :open} = state) do
    case UpstreamClient.decode_message(state.upstream_conn, state.upstream_websocket, message) do
      {:ok, conn, websocket, frames} ->
        new_state = %{
          state
          | upstream_conn: conn,
            upstream_websocket: websocket,
            last_activity_at: System.monotonic_time(:millisecond)
        }

        handle_upstream_frames(frames, new_state)

      {:error, _conn, _websocket, reason} ->
        Logger.error(
          "WebSocket bridge #{state.session_id}: upstream decode error: #{inspect(reason)}"
        )

        emit_exception(state, {:upstream_error, reason})
        send_to_downstream(state, Close.internal_error_frame())
        stop_with_reason(state, {:upstream_error, reason})
    end
  end

  def handle_info(message, %{status: :closing} = state) do
    case UpstreamClient.decode_message(state.upstream_conn, state.upstream_websocket, message) do
      {:ok, conn, websocket, frames} ->
        new_state = %{state | upstream_conn: conn, upstream_websocket: websocket}

        has_close? = Enum.any?(frames, fn f -> f.type == :close end)

        if has_close? do
          if state.close_timer, do: Process.cancel_timer(state.close_timer)
          stop_with_reason(new_state, :normal_close)
        else
          {:noreply, new_state}
        end

      {:error, _conn, _websocket, _reason} ->
        stop_with_reason(state, :upstream_error_during_close)
    end
  end

  def handle_info(message, state) do
    Logger.debug(
      "WebSocket bridge #{state.session_id}: unexpected message in #{state.status}: #{inspect(message)}"
    )

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    if state.close_timer, do: Process.cancel_timer(state.close_timer)
    cleanup_upstream(state)

    close_code =
      case state.close_reason do
        :downstream_close -> 1000
        :upstream_close -> 1000
        :handler_death -> 1001
        _ -> 1011
      end

    :telemetry.execute(
      [:relayixir, :websocket, :session, :stop],
      %{
        duration: System.monotonic_time(:millisecond) - (state.started_at || 0),
        system_time: System.system_time()
      },
      %{
        session_id: state.session_id,
        close_code: close_code,
        close_reason: state.close_reason,
        status: state.status,
        terminate_reason: reason
      }
    )

    :ok
  end

  ## Private Helpers

  defp flush_pending_frames([], state), do: {:noreply, state}

  defp flush_pending_frames([frame | rest], state) do
    case send_to_upstream(state, frame) do
      {:ok, new_state} ->
        flush_pending_frames(rest, %{
          new_state
          | last_activity_at: System.monotonic_time(:millisecond)
        })

      {:error, state} ->
        emit_exception(state, :upstream_send_failed)
        send_to_downstream(state, Close.internal_error_frame())
        stop_with_reason(state, :upstream_send_failed)
    end
  end

  defp emit_exception(state, reason) do
    :telemetry.execute(
      [:relayixir, :websocket, :exception],
      %{system_time: System.system_time()},
      %{session_id: state.session_id, reason: reason}
    )
  end

  defp handle_upstream_frames([], state), do: {:noreply, state}

  defp handle_upstream_frames([%Frame{type: :close} = frame | _rest], state) do
    Logger.debug("WebSocket bridge #{state.session_id}: upstream close received")
    send_to_downstream(state, frame)

    case Close.shutdown_action(:upstream_close, frame.close_code, frame.close_reason) do
      {:propagate_to_downstream, _frame} ->
        stop_with_reason(%{state | close_reason: :upstream_close}, :normal_close)
    end
  end

  defp handle_upstream_frames([frame | rest], state) do
    :telemetry.execute(
      [:relayixir, :websocket, :frame, :in],
      %{system_time: System.system_time()},
      %{session_id: state.session_id, type: frame.type}
    )

    invoke_ws_hook(state.session_id, :inbound, frame)
    send_to_downstream(state, frame)
    handle_upstream_frames(rest, state)
  end

  defp send_to_upstream(state, %Frame{} = frame) do
    case UpstreamClient.send_frame(
           state.upstream_conn,
           state.upstream_websocket,
           state.upstream_ref,
           frame
         ) do
      {:ok, conn, websocket} ->
        {:ok, %{state | upstream_conn: conn, upstream_websocket: websocket}}

      {:error, _conn, _websocket, reason} ->
        Logger.error(
          "WebSocket bridge #{state.session_id}: upstream send failed: #{inspect(reason)}"
        )

        {:error, state}
    end
  end

  defp send_to_downstream(state, %Frame{} = frame) do
    websock_frame = Frame.to_websock(frame)
    send(state.downstream_pid, {:bridge_frame, websock_frame})
  end

  defp cleanup_upstream(%{upstream_conn: nil}), do: :ok

  defp cleanup_upstream(%{upstream_conn: conn}) do
    UpstreamClient.close(conn)
  rescue
    _ -> :ok
  end

  defp stop_with_reason(state, reason) do
    {:stop, :normal, %{state | status: :closed, close_reason: reason}}
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp via_registry(session_id) do
    {:via, Registry, {Relayixir.Proxy.WebSocket.BridgeRegistry, session_id}}
  end

  defp invoke_ws_hook(session_id, direction, frame) do
    case HookConfig.get_on_ws_frame() do
      nil -> :ok
      hook_fn -> hook_fn.(session_id, direction, frame)
    end
  rescue
    error ->
      Logger.warning("on_ws_frame hook raised: #{inspect(error)}")
      :ok
  end
end
