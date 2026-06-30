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
        conn =
          conn
          |> configure_session(renew: true)
          |> put_session(:auth_user_id, user.id)

        case {pending_params, Auth.OAuth.get_client(pending_client_id || "")} do
          {%{} = params, %Client{} = client} ->
            conn
            |> delete_session(:pending_oauth_authorize)
            |> delete_session(:pending_oauth_client_id)
            |> AuthorizeController.redirect_with_code(params, user, client)

          _missing ->
            redirect(conn, to: "/")
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
    conn
    |> configure_session(drop: true)
    |> send_resp(204, "")
  end

  defp login_form(error \\ nil) do
    error_html =
      if error do
        ~s(<p class="error">#{Phoenix.HTML.html_escape(error)}</p>)
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
end
