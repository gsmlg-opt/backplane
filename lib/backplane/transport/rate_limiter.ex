defmodule Backplane.Transport.RateLimiter do
  @moduledoc """
  ETS-based rate limiting plug using a sliding window counter.

  Limits requests per IP address within a configurable time window.
  When the limit is exceeded, responds with 429 Too Many Requests.

  The /health endpoint is exempt from rate limiting.

  ## Configuration

      config :backplane, Backplane.Transport.RateLimiter,
        max_requests: 100,
        window_ms: 60_000

  Defaults: 100 requests per 60 seconds per IP.
  """

  require Logger

  import Plug.Conn
  @behaviour Plug

  @table __MODULE__
  @default_max_requests 100
  @default_window_ms 60_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: "/health"} = conn, _opts), do: conn

  def call(conn, _opts) do
    ensure_table()

    ip = client_ip(conn)
    now = System.monotonic_time(:millisecond)
    window_ms = config(:window_ms, @default_window_ms)
    max_requests = config(:max_requests, @default_max_requests)
    cutoff = now - window_ms

    # Probabilistic cleanup: ~1% of requests trigger a full sweep
    if :rand.uniform(100) == 1, do: sweep_stale(cutoff)

    # Clean old entries and count current window
    clean_and_count(ip, cutoff, now, max_requests, conn)
  end

  defp clean_and_count(ip, cutoff, now, max_requests, conn) do
    # Get existing timestamps for this IP
    timestamps =
      case :ets.lookup(@table, ip) do
        [{^ip, ts_list}] -> ts_list
        [] -> []
      end

    # Remove entries outside the window
    current = Enum.filter(timestamps, &(&1 > cutoff))

    if length(current) >= max_requests do
      :ets.insert(@table, {ip, current})
      reject(conn)
    else
      :ets.insert(@table, {ip, [now | current]})
      conn
    end
  end

  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(429, Jason.encode!(%{error: "Too many requests"}))
    |> halt()
  end

  defp sweep_stale(cutoff) do
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {ip, timestamps} ->
      case Enum.filter(timestamps, &(&1 > cutoff)) do
        [] -> :ets.delete(@table, ip)
        current -> :ets.insert(@table, {ip, current})
      end
    end)
  end

  defp config(key, default) do
    :backplane
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp ensure_table do
    case :ets.info(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        rescue
          ArgumentError ->
            Logger.debug("RateLimiter ETS table already created by another process")
            :ok
        end

      _ ->
        :ok
    end
  end
end
