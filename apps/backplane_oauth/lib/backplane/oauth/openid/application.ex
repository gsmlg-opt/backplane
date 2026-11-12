defmodule Backplane.Oauth.Openid.Application do
  @moduledoc """
  Implement this behaviour in the application layer of your OpenID Connect provider.
  This behaviour gives all callbacks triggered invoking `Backplane.Oauth.Openid` module functions.

  > __Note__: This behaviour is split into `Backplane.Oauth.Openid.JwksApplication` and `Backplane.Oauth.Openid.UserinfoApplication` providing utilities to implement the different OpenID Connect endpoints independently.
  """

  @doc """
  This function will be triggered in case of success invoking `Backplane.Oauth.Openid.jwks/2`
  """
  @callback jwk_list(conn :: Plug.Conn.t(), jwk_keys :: list(%JOSE.JWK{})) ::
              any()
  @doc """
  This function will be triggered in case of success invoking `Backplane.Oauth.Openid.userinfo/2`
  """
  @callback userinfo_fetched(conn :: Plug.Conn.t(), userinfo :: map()) ::
              any()
  @doc """
  This function will be triggered when request is unauthorized invoking `Backplane.Oauth.Openid.userinfo/2`
  """
  @callback unauthorized(conn :: Plug.Conn.t(), error :: Backplane.Oauth.Error.t()) ::
              any()
  @doc """
  This function will be triggered when request is unauthorized invoking `Backplane.Oauth.Openid.register_client/3`
  """
  @callback client_registered(conn :: Plug.Conn.t(), client :: Backplane.Oauth.Client.t()) ::
              any()
  @doc """
  This function will be triggered when request is unauthorized invoking `Backplane.Oauth.Openid.register_client/3`
  """
  @callback registration_failure(conn :: Plug.Conn.t(), changeset :: Ecto.Changeset.t()) ::
              any()
end
