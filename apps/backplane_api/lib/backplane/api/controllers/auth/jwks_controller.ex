defmodule Backplane.Api.Auth.JwksController do
  use Backplane.Api, :controller

  alias Backplane.Auth

  def index(conn, _params) do
    %{"keys" => signing_keys} = Auth.Tokens.jwks()

    # Access tokens are signed with the Backplane signing keys; ID tokens are
    # signed by Boruta with per-client keys. Serve both key sets.
    json(conn, %{"keys" => signing_keys ++ Boruta.ClientsAdapter.list_clients_jwk()})
  end
end
