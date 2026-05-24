defmodule Backplane.Transport.CacheBodyReader do
  @moduledoc """
  Custom body reader that caches the raw request body in `conn.assigns[:raw_body]`.

  This is used by proxy routes that need the exact request bytes after parsing,
  for example when extracting and rewriting LLM model names.

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
