defmodule Backplane.Transport.CacheBodyReader do
  @moduledoc """
  Custom body reader that caches the raw request body in `conn.assigns[:raw_body]`.

  This is needed for webhook signature verification, where the HMAC must be
  computed over the exact bytes sent by the client — not a re-serialized version
  of the parsed JSON (which may differ in key ordering or whitespace).

  Used as the `:body_reader` option for `Plug.Parsers`.
  """

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        existing = conn.assigns[:raw_body] || ""
        conn = Plug.Conn.assign(conn, :raw_body, existing <> body)
        {:ok, body, conn}

      {:more, body, conn} ->
        existing = conn.assigns[:raw_body] || ""
        conn = Plug.Conn.assign(conn, :raw_body, existing <> body)
        {:more, body, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
