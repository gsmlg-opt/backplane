defmodule Backplane.Api.Auth.IntrospectController do
  use Backplane.Api, :controller

  alias Backplane.Api.Auth.Helpers
  alias Backplane.Auth

  def introspect(conn, params) do
    with {:ok, client} <- Helpers.authenticate_client(conn, params),
         {:ok, result} <- Auth.Tokens.introspect(params["token"] || "", client) do
      json(conn, result)
    else
      {:error, :invalid_client} -> Helpers.json_error(conn, 401, "invalid_client")
      _error -> json(conn, %{active: false})
    end
  end
end
