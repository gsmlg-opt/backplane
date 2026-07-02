defmodule Backplane.Api.Auth.RevokeController do
  use Backplane.Api, :controller

  @behaviour Boruta.Oauth.RevokeApplication

  alias Backplane.Api.Auth.Helpers
  alias Boruta.Oauth.Error

  def revoke(conn, params) do
    case Helpers.check_client_enabled(conn, params) do
      :ok -> Boruta.Oauth.revoke(conn, __MODULE__)
      {:error, :invalid_client} -> Helpers.json_error(conn, 401, "invalid_client")
    end
  end

  @impl Boruta.Oauth.RevokeApplication
  def revoke_success(conn) do
    send_resp(conn, 200, "")
  end

  @impl Boruta.Oauth.RevokeApplication
  def revoke_error(conn, %Error{error: :invalid_client}) do
    Helpers.json_error(conn, 401, "invalid_client")
  end

  # RFC 7009: revocation of unknown or already-revoked tokens succeeds.
  def revoke_error(conn, %Error{}) do
    send_resp(conn, 200, "")
  end
end
