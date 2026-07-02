defmodule Backplane.Api.Auth.AuthorizeController do
  use Backplane.Api, :controller

  @behaviour Boruta.Oauth.AuthorizeApplication

  alias Backplane.Auth
  alias Backplane.Auth.Schemas.User
  alias Boruta.Ecto.Client
  alias Boruta.Oauth.AuthorizeResponse
  alias Boruta.Oauth.Error

  def authorize(conn, params) do
    case validate_authorize_request(params) do
      {:ok, client} ->
        case current_user(conn) do
          {:ok, user} ->
            authorize_for_user(conn, params, user, client)

          :login_required ->
            conn
            |> put_session(:pending_oauth_authorize, params)
            |> put_session(:pending_oauth_client_id, client.id)
            |> redirect(to: "/oauth/login")
        end

      {:error, reason} ->
        send_resp(conn, 400, to_string(reason))
    end
  end

  @doc """
  Runs the Boruta authorization for an authenticated user. Also invoked by
  the login controller when resuming a pending authorize request.

  RBAC scopes are validated here because Boruta treats public scopes as
  authorized for every resource owner.
  """
  def authorize_for_user(conn, params, %User{} = user, %Client{}) do
    case Auth.RBAC.validate_user_scopes(user, params["scope"] || "") do
      :ok ->
        conn
        |> Map.put(:query_params, params)
        |> Boruta.Oauth.authorize(Auth.ResourceOwners.from_user(user), __MODULE__)

      {:error, reason} ->
        send_resp(conn, 400, to_string(reason))
    end
  end

  @impl Boruta.Oauth.AuthorizeApplication
  def authorize_success(conn, %AuthorizeResponse{} = response) do
    redirect(conn, external: AuthorizeResponse.redirect_to_url(response))
  end

  @impl Boruta.Oauth.AuthorizeApplication
  def authorize_error(conn, %Error{error: error}) do
    send_resp(conn, 400, to_string(error))
  end

  defp validate_authorize_request(%{"client_id" => client_id} = params) do
    with %Client{} = client <- Auth.OAuth.get_enabled_client(client_id),
         :ok <- validate_response_type(params),
         :ok <- Auth.OAuth.validate_redirect_uri(client, params["redirect_uri"]),
         :ok <- validate_pkce(params),
         :ok <- validate_scopes(client, params["scope"]) do
      {:ok, client}
    else
      nil -> {:error, :invalid_client}
      {:error, :invalid_redirect_uri} -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_authorize_request(_params), do: {:error, :invalid_request}

  defp current_user(conn) do
    case get_session(conn, :auth_session_token) do
      token when is_binary(token) ->
        with {:ok, session} <- Auth.Accounts.get_session_by_token(token),
             %User{active: true} = user <- Auth.Accounts.get_user(session.user_id) do
          {:ok, user}
        else
          _invalid -> :login_required
        end

      _missing ->
        :login_required
    end
  end

  defp validate_response_type(%{"response_type" => "code"}), do: :ok
  defp validate_response_type(_params), do: {:error, :unsupported_response_type}

  defp validate_pkce(%{
         "code_challenge" => challenge,
         "code_challenge_method" => "S256"
       })
       when is_binary(challenge) and challenge != "" do
    :ok
  end

  defp validate_pkce(%{"code_challenge_method" => "plain"}),
    do: {:error, :unsupported_code_challenge_method}

  defp validate_pkce(_params), do: {:error, :invalid_request}

  defp validate_scopes(%Client{} = client, scope) do
    requested = String.split(scope || "", " ", trim: true)
    allowed = Enum.map(client.authorized_scopes, & &1.name)

    if Enum.all?(requested, &(&1 in allowed)) do
      :ok
    else
      {:error, :invalid_scope}
    end
  end
end
