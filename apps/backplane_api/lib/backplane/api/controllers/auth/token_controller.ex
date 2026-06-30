defmodule Backplane.Api.Auth.TokenController do
  use Backplane.Api, :controller

  alias Backplane.Api.Auth.Helpers
  alias Backplane.Auth
  alias Boruta.Ecto.Client

  def token(conn, %{"grant_type" => "authorization_code"} = params) do
    with {:ok, %Client{} = client} <- Helpers.authenticate_client(conn, params),
         {:ok, tokens} <- Auth.Tokens.exchange_authorization_code(params["code"], client, params) do
      json(conn, token_response(tokens))
    else
      {:error, :invalid_client} -> Helpers.json_error(conn, 401, "invalid_client")
      {:error, reason} -> Helpers.json_error(conn, 400, "invalid_grant", to_string(reason))
    end
  end

  def token(conn, %{"grant_type" => "refresh_token"} = params) do
    with {:ok, %Client{} = client} <- Helpers.authenticate_client(conn, params),
         {:ok, tokens} <- Auth.Tokens.rotate_refresh_token(params["refresh_token"], client) do
      json(conn, token_response(tokens))
    else
      {:error, :invalid_client} ->
        Helpers.json_error(conn, 401, "invalid_client")

      {:error, :reuse_detected} ->
        Helpers.json_error(conn, 400, "invalid_grant", "reuse_detected")

      {:error, reason} ->
        Helpers.json_error(conn, 400, "invalid_grant", to_string(reason))
    end
  end

  def token(conn, _params) do
    Helpers.json_error(conn, 400, "unsupported_grant_type")
  end

  defp token_response(tokens) do
    tokens
    |> Map.take([:access_token, :refresh_token, :id_token, :token_type, :expires_in, :scope])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
