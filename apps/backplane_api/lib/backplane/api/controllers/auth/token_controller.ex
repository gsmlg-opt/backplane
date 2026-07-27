defmodule Backplane.Api.Auth.TokenController do
  use Backplane.Api, :controller

  @behaviour Boruta.Oauth.TokenApplication

  alias Backplane.Api.Auth.{Helpers, ResourceParams}
  alias Backplane.Auth
  alias Backplane.Auth.{Resources, TokenResources}
  alias Boruta.Oauth.Authorization.{Client, Code}
  alias Boruta.Oauth.{AuthorizationCodeRequest, RefreshTokenRequest}
  alias Boruta.Oauth.Error
  alias Boruta.Oauth.Request
  alias Boruta.Oauth.TokenResponse

  @supported_grant_types ["authorization_code", "refresh_token"]

  def token(conn, %{"grant_type" => grant_type} = params)
      when grant_type in @supported_grant_types do
    case Helpers.check_client_enabled(conn, params) do
      :ok -> preflight_token(conn, params)
      {:error, :invalid_client} -> Helpers.json_error(conn, 401, "invalid_client")
    end
  end

  def token(conn, _params) do
    Helpers.json_error(conn, 400, "unsupported_grant_type")
  end

  @impl Boruta.Oauth.TokenApplication
  def token_success(conn, %TokenResponse{} = response) do
    case conn.private[:backplane_oauth_resource] do
      nil ->
        send_token_response(conn, response)

      resource when resource in [:mcp, :v1] ->
        client_id = conn.private[:backplane_oauth_client_id]

        with {:ok, _binding} <-
               TokenResources.bind_issued(
                 "access_token",
                 client_id,
                 response.access_token,
                 resource
               ),
             :ok <- verify_issued_audience(response.access_token, resource) do
          send_token_response(conn, response)
        else
          _binding_or_audience_failure ->
            revoke_issued_token(client_id, response.access_token)
            Helpers.json_error(conn, 400, "server_error")
        end
    end
  end

  @impl Boruta.Oauth.TokenApplication
  def token_error(conn, %Error{} = error) do
    detect_refresh_reuse(conn)

    case normalize_error(error) do
      {401, error_name} ->
        Helpers.json_error(conn, 401, error_name)

      {status, error_name} ->
        Helpers.json_error(conn, status, error_name, error.error_description)
    end
  end

  defp token_body(%TokenResponse{} = response) do
    %{
      access_token: response.access_token,
      token_type: "Bearer",
      expires_in: response.expires_in,
      refresh_token: response.refresh_token,
      id_token: response.id_token,
      scope: response.token && response.token.scope
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp preflight_token(conn, params) do
    case Request.token_request(conn) do
      {:ok, request} ->
        with {:ok, client} <- authenticate_grant_client(request),
             :ok <- validate_grant_credential(request, client),
             {:ok, conn} <- resolve_grant_resource(conn, params, request, client.id) do
          issue_token(conn)
        else
          {:error, :invalid_target} ->
            Helpers.json_error(conn, 400, "invalid_target")

          {:error, %Error{} = error} ->
            token_error(conn, error)
        end

      {:error, %Error{}} ->
        issue_token(conn)
    end
  end

  defp authenticate_grant_client(%AuthorizationCodeRequest{} = request) do
    authorize_client(
      id: request.client_id,
      source: request.client_authentication,
      redirect_uri: request.redirect_uri,
      grant_type: request.grant_type,
      code_verifier: request.code_verifier
    )
  end

  defp authenticate_grant_client(%RefreshTokenRequest{} = request) do
    authorize_client(
      id: request.client_id,
      source: request.client_authentication,
      grant_type: request.grant_type
    )
  end

  defp authorize_client(options) do
    client_id = Keyword.fetch!(options, :id)

    with {:ok, _uuid} <- Ecto.UUID.cast(client_id),
         {:ok, client} <- Client.authorize(options) do
      {:ok, client}
    else
      :error ->
        {:error, invalid_client_error()}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_grant_credential(%AuthorizationCodeRequest{} = request, client) do
    case Code.authorize(%{
           value: request.code,
           redirect_uri: request.redirect_uri,
           client: client,
           code_verifier: request.code_verifier
         }) do
      {:ok, _code} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_grant_credential(%RefreshTokenRequest{}, _client), do: :ok

  defp resolve_grant_resource(
         conn,
         params,
         %AuthorizationCodeRequest{code: code},
         client_id
       ) do
    with {:ok, supplied} <- ResourceParams.form(conn, params) do
      case TokenResources.lookup_code(client_id, code) do
        {:ok, _token, nil} when is_nil(supplied) ->
          {:ok, conn}

        {:ok, _token, resource}
        when resource in [:mcp, :v1] and resource == supplied ->
          {:ok, put_resource_private(conn, client_id, resource)}

        {:ok, _token, _bound_or_unbound} ->
          {:error, :invalid_target}

        :not_found ->
          {:ok, conn}
      end
    end
  end

  defp resolve_grant_resource(
         conn,
         params,
         %RefreshTokenRequest{refresh_token: refresh_token},
         client_id
       ) do
    with {:ok, supplied} <- ResourceParams.form(conn, params) do
      case TokenResources.lookup_refresh(client_id, refresh_token) do
        {:ok, _token, nil} when is_nil(supplied) ->
          {:ok, conn}

        {:ok, _token, nil} ->
          {:error, :invalid_target}

        {:ok, _token, resource} when resource in [:mcp, :v1] and is_nil(supplied) ->
          {:ok, put_resource_private(conn, client_id, resource)}

        {:ok, _token, resource}
        when resource in [:mcp, :v1] and resource == supplied ->
          {:ok, put_resource_private(conn, client_id, resource)}

        {:ok, _token, _mismatch} ->
          {:error, :invalid_target}

        :not_found ->
          {:ok, conn}
      end
    end
  end

  defp put_resource_private(conn, client_id, resource) do
    conn
    |> put_private(:backplane_oauth_client_id, client_id)
    |> put_private(:backplane_oauth_resource, resource)
  end

  defp issue_token(conn) do
    Boruta.Oauth.token(conn, __MODULE__)
  rescue
    _error in TokenResources.LineageError ->
      Helpers.json_error(conn, 400, "server_error")
  end

  defp send_token_response(conn, response) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> json(token_body(response))
  end

  defp verify_issued_audience(access_token, resource) do
    expected_audience = Resources.uri(resource)

    case Auth.Tokens.verify_access_token(access_token) do
      {:ok, %{"aud" => ^expected_audience}} -> :ok
      _invalid -> {:error, :invalid_audience}
    end
  end

  defp revoke_issued_token(client_id, access_token) do
    case TokenResources.lookup_access_token(client_id, access_token) do
      {:ok, token, _resource} -> Auth.Tokens.revoke_token_by_id(token.id)
      :not_found -> :ok
    end
  end

  defp invalid_client_error do
    %Error{
      status: :unauthorized,
      error: :invalid_client,
      error_description: "Invalid client_id or client_secret."
    }
  end

  defp normalize_error(%Error{error: :invalid_client}), do: {401, "invalid_client"}

  # RFC 7636 mandates invalid_grant for missing or failed PKCE verification;
  # Boruta reports both as invalid_request.
  defp normalize_error(%Error{error: :invalid_request, error_description: description})
       when description in ["Code verifier is invalid.", "PKCE request invalid."],
       do: {400, "invalid_grant"}

  defp normalize_error(%Error{error: error, status: status}),
    do: {Plug.Conn.Status.code(status), to_string(error)}

  # A refresh grant that fails with an already-rotated refresh token is a
  # replay; revoke the whole token family for that client and subject.
  defp detect_refresh_reuse(
         %Plug.Conn{params: %{"grant_type" => "refresh_token", "refresh_token" => refresh_token}} =
           conn
       )
       when is_binary(refresh_token) do
    case Helpers.client_credentials(conn, conn.params) do
      {:ok, client_id, _secret} ->
        Auth.Tokens.detect_refresh_token_reuse(refresh_token, client_id)

      _missing ->
        :ok
    end
  end

  defp detect_refresh_reuse(_conn), do: :ok
end
