defmodule Backplane.Api.Auth.LoginController do
  use Backplane.Api, :controller

  alias Backplane.Api.Auth.AuthorizeController
  alias Backplane.Auth
  alias Boruta.Ecto.Client

  def new(conn, _params) do
    html(conn, login_form())
  end

  def create(conn, %{"email" => email, "password" => password}) do
    pending_params = get_session(conn, :pending_oauth_authorize)
    pending_client_id = get_session(conn, :pending_oauth_client_id)

    case Auth.Accounts.authenticate(email, password) do
      {:ok, user} ->
        case Auth.Accounts.create_session(user, session_attrs(conn)) do
          {:ok, %{token: session_token}} ->
            conn =
              conn
              |> configure_session(renew: true)
              |> put_session(:auth_session_token, session_token)

            case {pending_params, Auth.OAuth.get_enabled_client(pending_client_id || "")} do
              {%{} = params, %Client{} = client} ->
                conn
                |> delete_session(:pending_oauth_authorize)
                |> delete_session(:pending_oauth_client_id)
                |> AuthorizeController.authorize_for_user(params, user, client)

              _missing ->
                redirect(conn, to: "/")
            end

          {:error, _changeset} ->
            send_resp(conn, 500, "session_create_failed")
        end

      {:error, _reason} ->
        conn
        |> put_status(:unauthorized)
        |> html(login_form("Invalid email or password"))
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> html(login_form("Invalid email or password"))
  end

  def delete(conn, _params) do
    revoke_current_session(conn)

    conn
    |> configure_session(drop: true)
    |> send_resp(204, "")
  end

  defp login_form(error \\ nil) do
    error_html =
      if error do
        escaped_error =
          error
          |> Phoenix.HTML.html_escape()
          |> Phoenix.HTML.safe_to_string()

        ~s(<p class="error">#{escaped_error}</p>)
      else
        ""
      end

    """
    <!doctype html>
    <html>
      <head><title>Backplane Auth</title></head>
      <body>
        <main>
          <h1>Backplane Auth</h1>
          #{error_html}
          <form id="oauth-login-form" method="post" action="/oauth/login">
            <input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token()}">
            <label>Email <input type="email" name="email" autocomplete="username"></label>
            <label>Password <input type="password" name="password" autocomplete="current-password"></label>
            <button type="submit">Sign in</button>
          </form>
        </main>
      </body>
    </html>
    """
  end

  defp session_attrs(conn) do
    %{
      user_agent: conn |> get_req_header("user-agent") |> List.first(),
      ip: remote_ip(conn)
    }
  end

  defp remote_ip(%{remote_ip: remote_ip}) when is_tuple(remote_ip) do
    remote_ip
    |> :inet.ntoa()
    |> to_string()
  rescue
    _error -> nil
  end

  defp remote_ip(_conn), do: nil

  defp revoke_current_session(conn) do
    with token when is_binary(token) <- get_session(conn, :auth_session_token),
         {:ok, session} <- Auth.Accounts.get_session_by_token(token) do
      Auth.Accounts.revoke_session(session)
    else
      _missing -> :ok
    end
  end
end
