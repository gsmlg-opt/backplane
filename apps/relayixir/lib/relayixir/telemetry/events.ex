defmodule Relayixir.Telemetry.Events do
  @moduledoc """
  Attaches telemetry handlers for logging proxy lifecycle events.
  """

  use GenServer
  require Logger

  @events [
    [:relayixir, :http, :request, :start],
    [:relayixir, :http, :request, :stop],
    [:relayixir, :http, :request, :exception],
    [:relayixir, :http, :upstream, :connect, :start],
    [:relayixir, :http, :upstream, :connect, :stop],
    [:relayixir, :http, :downstream, :disconnect],
    [:relayixir, :websocket, :session, :start],
    [:relayixir, :websocket, :session, :stop],
    [:relayixir, :websocket, :frame, :in],
    [:relayixir, :websocket, :frame, :out],
    [:relayixir, :websocket, :upstream, :connect, :start],
    [:relayixir, :websocket, :upstream, :connect, :stop],
    [:relayixir, :websocket, :exception]
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    :telemetry.attach_many(
      "relayixir-telemetry-logger",
      @events,
      &__MODULE__.handle_event/4,
      nil
    )

    {:ok, %{}}
  end

  def handle_event([:relayixir, :http, :request, :start], measurements, metadata, _config) do
    Logger.info("HTTP request started",
      method: metadata[:method],
      path: metadata[:path],
      upstream: metadata[:upstream],
      system_time: measurements[:system_time]
    )
  end

  def handle_event([:relayixir, :http, :request, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements[:duration], :native, :millisecond)

    Logger.info("HTTP request completed",
      method: metadata[:method],
      path: metadata[:path],
      upstream: metadata[:upstream],
      status: metadata[:status],
      duration_ms: duration_ms
    )
  end

  def handle_event([:relayixir, :http, :request, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements[:duration], :native, :millisecond)

    Logger.error("HTTP request failed",
      method: metadata[:method],
      path: metadata[:path],
      upstream: metadata[:upstream],
      reason: inspect(metadata[:reason]),
      duration_ms: duration_ms
    )
  end

  def handle_event(
        [:relayixir, :http, :upstream, :connect, :start],
        _measurements,
        metadata,
        _config
      ) do
    Logger.debug("Upstream connection starting", upstream: metadata[:upstream])
  end

  def handle_event(
        [:relayixir, :http, :upstream, :connect, :stop],
        _measurements,
        metadata,
        _config
      ) do
    Logger.debug("Upstream connection completed",
      upstream: metadata[:upstream],
      result: metadata[:result]
    )
  end

  def handle_event(
        [:relayixir, :http, :downstream, :disconnect],
        _measurements,
        _metadata,
        _config
      ) do
    Logger.info("Downstream client disconnected during streaming")
  end

  def handle_event([:relayixir, :websocket, :session, :start], _measurements, metadata, _config) do
    Logger.info("WebSocket session started", session_id: metadata[:session_id])
  end

  def handle_event([:relayixir, :websocket, :session, :stop], measurements, metadata, _config) do
    Logger.info("WebSocket session stopped",
      session_id: metadata[:session_id],
      close_code: metadata[:close_code],
      close_reason: inspect(metadata[:close_reason]),
      duration_ms: measurements[:duration]
    )
  end

  def handle_event([:relayixir, :websocket, :frame, :in], _measurements, metadata, _config) do
    Logger.debug("WebSocket frame received",
      session_id: metadata[:session_id],
      type: metadata[:type]
    )
  end

  def handle_event([:relayixir, :websocket, :frame, :out], _measurements, metadata, _config) do
    Logger.debug("WebSocket frame sent", session_id: metadata[:session_id], type: metadata[:type])
  end

  def handle_event(
        [:relayixir, :websocket, :upstream, :connect, :start],
        _measurements,
        metadata,
        _config
      ) do
    Logger.debug("WebSocket upstream connection starting",
      session_id: metadata[:session_id],
      upstream: metadata[:upstream]
    )
  end

  def handle_event(
        [:relayixir, :websocket, :upstream, :connect, :stop],
        _measurements,
        metadata,
        _config
      ) do
    Logger.debug("WebSocket upstream connection completed",
      session_id: metadata[:session_id],
      upstream: metadata[:upstream],
      result: metadata[:result]
    )
  end

  def handle_event([:relayixir, :websocket, :exception], _measurements, metadata, _config) do
    Logger.error("WebSocket exception",
      session_id: metadata[:session_id],
      reason: inspect(metadata[:reason])
    )
  end
end
