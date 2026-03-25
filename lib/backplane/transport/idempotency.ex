defmodule Backplane.Transport.Idempotency do
  @moduledoc """
  Idempotency key support for MCP requests.

  When a client includes the `Idempotency-Key` header, the response body is
  cached in ETS for a configurable TTL. Repeated requests with the same key
  return the cached response without re-executing. This enables safe retries.

  Cache entries are stored per-key with a timestamp and cleaned up
  probabilistically (same pattern as RateLimiter).
  """

  import Plug.Conn
  @behaviour Plug

  @table __MODULE__
  @default_ttl_ms 300_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "idempotency-key") do
      [key] when byte_size(key) > 0 ->
        ensure_table()
        check_cache(conn, key)

      _ ->
        conn
    end
  end

  defp check_cache(conn, key) do
    now = System.monotonic_time(:millisecond)
    ttl = config(:ttl_ms, @default_ttl_ms)

    case :ets.lookup(@table, key) do
      [{^key, {body, status, content_type, timestamp}}] when now - timestamp < ttl ->
        conn
        |> put_resp_content_type(content_type)
        |> send_resp(status, body)
        |> halt()

      _ ->
        # Clean stale entry if present
        :ets.delete(@table, key)
        maybe_sweep(now - ttl)
        register_cache_callback(conn, key, now)
    end
  end

  defp register_cache_callback(conn, key, now) do
    Plug.Conn.register_before_send(conn, fn conn ->
      content_type = response_content_type(conn)
      :ets.insert(@table, {key, {conn.resp_body, conn.status, content_type, now}})
      conn
    end)
  end

  defp response_content_type(conn) do
    case get_resp_header(conn, "content-type") do
      [ct] -> ct
      _ -> "application/json"
    end
  end

  defp maybe_sweep(cutoff) do
    if :rand.uniform(50) == 1, do: do_sweep(cutoff)
  end

  defp do_sweep(cutoff) do
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {key, {_body, _status, _ct, timestamp}} ->
      if timestamp < cutoff, do: :ets.delete(@table, key)
    end)
  end

  defp ensure_table do
    case :ets.info(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp config(key, default) do
    :backplane
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
