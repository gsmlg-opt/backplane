defmodule Backplane.Api.Auth.TokenController do
  use Backplane.Api, :controller

  @behaviour Boruta.Oauth.TokenApplication

  alias Backplane.Api.Auth.Helpers
  alias Backplane.Auth
  alias Boruta.Oauth.Error
  alias Boruta.Oauth.TokenResponse

  @supported_grant_types ["authorization_code", "refresh_token"]

  def token(conn, %{"grant_type" => grant_type} = params)
      when grant_type in @supported_grant_types do
    case Helpers.check_client_enabled(conn, params) do
      :ok -> Boruta.Oauth.token(conn, __MODULE__)
      {:error, :invalid_client} -> Helpers.json_error(conn, 401, "invalid_client")
    end
  end

  def token(conn, _params) do
    Helpers.json_error(conn, 400, "unsupported_grant_type")
  end

  @impl Boruta.Oauth.TokenApplication
  def token_success(conn, %TokenResponse{} = response) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> json(token_body(response))
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
