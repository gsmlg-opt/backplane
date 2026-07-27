defmodule Backplane.Api.Auth.RawBodyReader do
  @moduledoc false

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        raw = (conn.private[:oauth_raw_form_body] || "") <> body
        {:ok, body, maybe_store_pairs(conn, raw)}

      {:more, body, conn} ->
        raw = (conn.private[:oauth_raw_form_body] || "") <> body
        {:more, body, Plug.Conn.put_private(conn, :oauth_raw_form_body, raw)}

      other ->
        other
    end
  end

  defp maybe_store_pairs(%Plug.Conn{request_path: "/oauth/token"} = conn, body) do
    if form_urlencoded?(conn) do
      Plug.Conn.put_private(conn, :oauth_form_pairs, Enum.to_list(URI.query_decoder(body)))
    else
      conn
    end
  rescue
    ArgumentError -> Plug.Conn.put_private(conn, :oauth_form_pairs, :malformed)
  end

  defp maybe_store_pairs(conn, _body), do: conn

  defp form_urlencoded?(conn) do
    conn
    |> Plug.Conn.get_req_header("content-type")
    |> Enum.any?(&String.starts_with?(&1, "application/x-www-form-urlencoded"))
  end
end
