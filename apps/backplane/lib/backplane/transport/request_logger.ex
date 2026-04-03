defmodule Backplane.Transport.RequestLogger do
  @moduledoc """
  Plug for structured request logging with metadata.

  Logs each request with method, path, status, and duration.
  MCP requests include the JSON-RPC method name.
  """

  require Logger
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    start_time = System.monotonic_time()

    Plug.Conn.register_before_send(conn, fn conn ->
      duration_us =
        System.convert_time_unit(
          System.monotonic_time() - start_time,
          :native,
          :microsecond
        )

      metadata = build_metadata(conn, duration_us)
      level = if conn.status >= 500, do: :error, else: :info

      Logger.log(level, fn -> log_message(conn, duration_us) end, metadata)

      conn
    end)
  end

  defp build_metadata(conn, duration_us) do
    base = [
      method: conn.method,
      path: conn.request_path,
      status: conn.status,
      duration_us: duration_us,
      remote_ip: format_ip(conn.remote_ip)
    ]

    case extract_rpc_method(conn) do
      nil -> base
      rpc_method -> [{:rpc_method, rpc_method} | base]
    end
  end

  defp extract_rpc_method(conn) do
    case conn.body_params do
      %{"method" => method} when is_binary(method) -> method
      _ -> nil
    end
  end

  defp log_message(conn, duration_us) do
    duration_ms = Float.round(duration_us / 1_000, 2)

    case extract_rpc_method(conn) do
      nil ->
        "#{conn.method} #{conn.request_path} - #{conn.status} in #{duration_ms}ms"

      rpc_method ->
        "MCP #{rpc_method} - #{conn.status} in #{duration_ms}ms"
    end
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip), do: inspect(ip)
end
