defmodule Backplane.Oauth.Ecto.Admin do
  @moduledoc """
  Administration of Backplane OAuth resources.
  """

  defdelegate list_clients, to: Backplane.Oauth.Ecto.Admin.Clients
  defdelegate get_client!(id), to: Backplane.Oauth.Ecto.Admin.Clients
  defdelegate create_client(attrs), to: Backplane.Oauth.Ecto.Admin.Clients
  defdelegate update_client(client, attrs), to: Backplane.Oauth.Ecto.Admin.Clients
  defdelegate regenerate_client_secret(client), to: Backplane.Oauth.Ecto.Admin.Clients
  defdelegate regenerate_client_secret(client, secret), to: Backplane.Oauth.Ecto.Admin.Clients
  defdelegate regenerate_client_key_pair(client), to: Backplane.Oauth.Ecto.Admin.Clients

  defdelegate regenerate_client_key_pair(client, public_key, private_key),
    to: Backplane.Oauth.Ecto.Admin.Clients

  defdelegate delete_client(client), to: Backplane.Oauth.Ecto.Admin.Clients

  defdelegate list_scopes, to: Backplane.Oauth.Ecto.Admin.Scopes
  defdelegate get_scope!(id), to: Backplane.Oauth.Ecto.Admin.Scopes
  defdelegate get_scopes_by_ids(ids), to: Backplane.Oauth.Ecto.Admin.Scopes
  defdelegate get_scopes_by_names(names), to: Backplane.Oauth.Ecto.Admin.Scopes
  defdelegate create_scope(attrs), to: Backplane.Oauth.Ecto.Admin.Scopes
  defdelegate update_scope(scope, attrs), to: Backplane.Oauth.Ecto.Admin.Scopes
  defdelegate delete_scope(scope), to: Backplane.Oauth.Ecto.Admin.Scopes

  defdelegate list_active_tokens(), to: Backplane.Oauth.Ecto.Admin.Tokens
  defdelegate list_active_tokens(queryable), to: Backplane.Oauth.Ecto.Admin.Tokens
  defdelegate delete_inactive_tokens(), to: Backplane.Oauth.Ecto.Admin.Tokens
  defdelegate delete_inactive_tokens(until), to: Backplane.Oauth.Ecto.Admin.Tokens
end
