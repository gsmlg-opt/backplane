defmodule Backplane.Api.Auth.AuthorizeController do
  use Backplane.Api, :controller

  @behaviour Boruta.Oauth.AuthorizeApplication

  alias Backplane.Api.Auth.{AuthorizationRequest, ResourceParams}
  alias Backplane.Auth
  alias Backplane.Auth.Schemas.User
  alias Boruta.Ecto.Client
  alias Boruta.Oauth.AuthorizeResponse
  alias Boruta.Oauth.Error

  def authorize(conn, params) do
    with :ok <- validate_untrusted_parameter_shapes(conn, params),
         {:ok, client} <- enabled_client(params),
         :ok <- validate_redirect_uri(client, params) do
      case prepare_before_login(conn, client, params) do
        {:ok, normalized_params} -> continue_authorize(conn, client, normalized_params)
        {:error, error} -> redirect_authorize_error(conn, params, error)
      end
    else
      _untrusted -> send_resp(conn, 400, "invalid_request")
    end
  end

  @doc """
  Runs the Boruta authorization for an authenticated user. Also invoked by
  the login controller when resuming a pending authorize request.

  RBAC scopes are validated here because Boruta treats public scopes as
  authorized for every resource owner.
  """
  def authorize_for_user(conn, params, %User{} = user, %Client{} = client) do
    with {:ok, resource} <- ResourceParams.saved(params),
         {:ok, params} <- AuthorizationRequest.preflight(client, params, resource),
         {:ok, normalized_params} <-
           AuthorizationRequest.for_user(client, user, params, resource) do
      conn
      |> put_private(:backplane_oauth_resource, resource)
      |> put_private(:backplane_oauth_client_id, client.id)
      |> Map.put(:query_params, normalized_params)
      |> Boruta.Oauth.authorize(Auth.ResourceOwners.from_user(user), __MODULE__)
    else
      {:error, error} -> redirect_authorize_error(conn, params, error)
    end
  end

  @impl Boruta.Oauth.AuthorizeApplication
  def authorize_success(conn, %AuthorizeResponse{} = response) do
    case conn.private[:backplane_oauth_resource] do
      nil ->
        redirect(conn, external: AuthorizeResponse.redirect_to_url(response))

      resource ->
        client_id = conn.private[:backplane_oauth_client_id]

        case Auth.TokenResources.bind_issued("code", client_id, response.code, resource) do
          {:ok, _binding} ->
            redirect(conn, external: AuthorizeResponse.redirect_to_url(response))

          {:error, _reason} ->
            redirect_response_error(conn, response, "server_error")
        end
    end
  end

  @impl Boruta.Oauth.AuthorizeApplication
  def authorize_error(conn, %Error{error: error}) do
    redirect_authorize_error(conn, conn.query_params, error)
  end

  defp enabled_client(%{"client_id" => client_id}) when is_binary(client_id) do
    case Auth.OAuth.get_enabled_client(client_id) do
      %Client{} = client -> {:ok, client}
      nil -> {:error, :invalid_client}
    end
  end

  defp enabled_client(_params), do: {:error, :invalid_request}

  defp validate_redirect_uri(client, %{"redirect_uri" => redirect_uri})
       when is_binary(redirect_uri),
       do: Auth.OAuth.validate_redirect_uri(client, redirect_uri)

  defp validate_redirect_uri(_client, _params), do: {:error, :invalid_request}

  defp validate_untrusted_parameter_shapes(conn, params) do
    if structured_query_parameter?(conn, "client_id") or
         structured_query_parameter?(conn, "redirect_uri") or
         not is_binary(params["client_id"]) or
         not is_binary(params["redirect_uri"]) do
      {:error, :invalid_request}
    else
      :ok
    end
  end

  defp prepare_before_login(conn, client, params) do
    with :ok <- validate_trusted_parameter_shapes(conn),
         {:ok, resource} <- ResourceParams.query(conn, params),
         {:ok, normalized_params} <- AuthorizationRequest.preflight(client, params, resource) do
      {:ok, normalized_params}
    end
  end

  defp validate_trusted_parameter_shapes(conn) do
    cond do
      structured_query_parameter?(conn, "state") -> {:error, :invalid_request}
      structured_query_parameter?(conn, "scope") -> {:error, :invalid_scope}
      true -> :ok
    end
  end

  defp structured_query_parameter?(conn, name),
    do: ResourceParams.structured_query_parameter?(conn, name)

  defp continue_authorize(conn, client, params) do
    case current_user(conn) do
      {:ok, user} ->
        authorize_for_user(conn, params, user, client)

      :login_required ->
        conn
        |> put_session(:pending_oauth_authorize, params)
        |> put_session(:pending_oauth_client_id, client.id)
        |> redirect(to: "/oauth/login")
    end
  end

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

  defp redirect_response_error(conn, %AuthorizeResponse{} = response, error) do
    redirect_authorize_error(
      conn,
      %{"redirect_uri" => response.redirect_uri, "state" => response.state},
      error
    )
  end

  defp redirect_authorize_error(conn, params, error) do
    uri = URI.parse(params["redirect_uri"])
    state = if structured_query_parameter?(conn, "state"), do: nil, else: params["state"]

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.drop(["code", "error_description", "state"])
      |> Map.put("error", to_string(error))
      |> maybe_put_state(state)

    redirect(conn, external: URI.to_string(%{uri | query: URI.encode_query(query)}))
  end

  defp maybe_put_state(query, state) when is_binary(state), do: Map.put(query, "state", state)
  defp maybe_put_state(query, _state), do: query
end
