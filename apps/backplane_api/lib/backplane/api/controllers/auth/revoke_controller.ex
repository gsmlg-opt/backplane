defmodule Backplane.Api.Auth.RevokeController do
  use Backplane.Api, :controller

  alias Backplane.Api.Auth.Helpers
  alias Backplane.Auth

  def revoke(conn, params) do
    with {:ok, client} <- Helpers.authenticate_client(conn, params),
         :ok <- Auth.Tokens.revoke(params["token"] || "", client) do
      send_resp(conn, 200, "")
    else
      {:error, :invalid_client} -> Helpers.json_error(conn, 401, "invalid_client")
      _error -> send_resp(conn, 200, "")
    end
  end
end
