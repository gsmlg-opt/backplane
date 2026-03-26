defmodule Backplane.Transport.Compression do
  @moduledoc """
  Plug for gzip response compression.

  Compresses responses when:
  - Client sends `Accept-Encoding: gzip`
  - Response body exceeds the minimum size threshold

  ## Configuration

      config :backplane, Backplane.Transport.Compression,
        min_size: 1024

  Default: compress responses over 1024 bytes.
  """

  import Plug.Conn
  require Logger
  @behaviour Plug

  @default_min_size 1024

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if accepts_gzip?(conn) do
      Plug.Conn.register_before_send(conn, &maybe_compress/1)
    else
      conn
    end
  end

  defp accepts_gzip?(conn) do
    conn
    |> get_req_header("accept-encoding")
    |> Enum.any?(&String.contains?(&1, "gzip"))
  end

  defp maybe_compress(conn) do
    min_size = config(:min_size, @default_min_size)
    body = conn.resp_body

    if is_binary(body) and byte_size(body) >= min_size do
      try do
        compressed = :zlib.gzip(body)

        conn
        |> put_resp_header("content-encoding", "gzip")
        |> put_resp_header("vary", "Accept-Encoding")
        |> Map.put(:resp_body, compressed)
      rescue
        e ->
          Logger.debug("Gzip compression failed: #{Exception.message(e)}")
          conn
      end
    else
      conn
    end
  end

  defp config(key, default) do
    :backplane
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
