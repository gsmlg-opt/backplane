defmodule Backplane.Web.AdminAuthPlug do
  @moduledoc """
  HTTP Basic authentication plug for the admin web UI.

  When `backplane.admin_username` and `backplane.admin_password` are configured,
  requests require basic auth credentials. Optional mode is the default and
  passes requests through when credentials are not configured. Required mode
  fails closed with 503 until both credentials are configured.
  """

  import Plug.Conn
  @behaviour Plug

  @realm "Backplane Admin"

  @impl true
  def init(opts) do
    opts = Keyword.validate!(opts, required: false)

    unless is_boolean(opts[:required]) do
      raise ArgumentError, ":required must be a boolean"
    end

    opts
  end

  @impl true
  def call(conn, opts) do
    required? = Keyword.fetch!(opts, :required)

    case get_admin_credentials() do
      {:ok, {username, password}} ->
        verify_basic_auth(conn, username, password)

      :error when required? ->
        conn
        |> send_resp(503, "Admin authentication is not configured")
        |> halt()

      :error ->
        conn
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
      {:ok, {username, password}}
    else
      :error
    end
  end
end
