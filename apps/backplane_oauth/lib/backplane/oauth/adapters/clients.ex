defmodule Backplane.Oauth.ClientsAdapter do
  @moduledoc """
  Encapsulate injected `Backplane.Oauth.Clients` adapter in context configuration
  """

  @behaviour Backplane.Oauth.Clients
  @behaviour Backplane.Oauth.Openid.Clients

  import Backplane.Oauth.Config, only: [clients: 0]

  def get_client(id), do: clients().get_client(id)
  def authorized_scopes(params), do: clients().authorized_scopes(params)
  def list_clients_jwk, do: clients().list_clients_jwk()
  def create_client(registration_params), do: clients().create_client(registration_params)
  def refresh_jwk_from_jwks_uri(client_id), do: clients().refresh_jwk_from_jwks_uri(client_id)
end
