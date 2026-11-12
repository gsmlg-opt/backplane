defmodule Backplane.Oauth.Clients do
  @moduledoc """
  Client context
  """

  @doc """
  Returns a `Backplane.Oauth.Client` given id.
  """
  @callback get_client(id :: any()) :: client :: Backplane.Oauth.Client.t() | nil

  @doc """
  Returns client authorized scopes. The scopes will be granted for every requests to the given client.
  """
  @callback authorized_scopes(client :: Backplane.Oauth.Client.t()) ::
              list(Backplane.Oauth.Scope.t())

  @doc """
  Returns all clients jwk public keys
  """
  @callback list_clients_jwk() :: list(%JOSE.JWK{})

  @optional_callbacks [list_clients_jwk: 0]
end
