defmodule Backplane.Web.AdminAuthPlug do
  @moduledoc """
  Optional HTTP Basic authentication plug for the admin web UI.

  When `backplane.admin_username` and `backplane.admin_password` are configured,
  requests to /admin/* require basic auth credentials. When not configured, all
  requests pass through (useful for local development).
  """

  import Plug.Conn
  @behaviour Plug

  @realm "Backplane Admin"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_admin_credentials() do
      nil -> conn
      {username, password} -> verify_basic_auth(conn, username, password)
    end
  end

  defp verify_basic_auth(conn, expected_user, expected_pass) do
    with [header] <- get_req_header(conn, "authorization"),
         {:ok, {user, pass}} <- parse_basic_auth(header),
         true <- Plug.Crypto.secure_compare(user, expected_user),
         true <- Plug.Crypto.secure_compare(pass, expected_pass) do
      conn
    else
      _ -> challenge(conn)
    end
  end

  defp parse_basic_auth("Basic " <> encoded) do
    case Base.decode64(encoded) do
      {:ok, decoded} ->
        case String.split(decoded, ":", parts: 2) do
          [user, pass] -> {:ok, {user, pass}}
          _ -> :error
        end

      :error ->
        :error
    end
  end

  defp parse_basic_auth(_), do: :error

  defp challenge(conn) do
    conn
    |> put_resp_header("www-authenticate", "Basic realm=\"#{@realm}\"")
    |> send_resp(401, "Unauthorized")
    |> halt()
  end

  defp get_admin_credentials do
    username = Application.get_env(:backplane, :admin_username)
    password = Application.get_env(:backplane, :admin_password)

    if is_binary(username) and is_binary(password) and username != "" and password != "" do
      {username, password}
    end
  end
end
