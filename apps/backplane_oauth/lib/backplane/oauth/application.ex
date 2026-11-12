defmodule Backplane.Oauth.Application do
  @moduledoc """
  Implement this behaviour in the application layer of your OAuth / OpenID Connect provider.
  This behaviour gives all callbacks triggered invoking `Backplane.Oauth` module functions.

  > __Note__: This behaviour is split into `Backplane.Oauth.AuthorizeApplication`, `Backplane.Oauth.TokenApplication`, `Backplane.Oauth.IntrospectApplication`, and `Backplane.Oauth.RevokeApplication` providing utilities to implement the different OAuth / OpenID Connect endpoints independently.
  """

  @doc """
  This function will be triggered in case of success invoking `Backplane.Oauth.token/2`
  """
  @callback token_success(
              conn :: Plug.Conn.t(),
              token_response :: Backplane.Oauth.TokenResponse.t()
            ) ::
              any()
  @doc """
  This function will be triggered in case of failure invoking `Backplane.Oauth.token/2`
  """
  @callback token_error(conn :: Plug.Conn.t(), oauth_error :: Backplane.Oauth.Error.t()) :: any()

  @doc """
  This function will be triggered in case of success invoking `Backplane.Oauth.preauthorize/3`
  """
  @callback preauthorize_success(
              conn :: Plug.Conn.t(),
              authorization :: Backplane.Oauth.AuthorizationSuccess.t()
            ) :: any()
  @doc """
  This function will be triggered in case of failure invoking `Backplane.Oauth.preauthorize/3`
  """
  @callback preauthorize_error(conn :: Plug.Conn.t(), oauth_error :: Backplane.Oauth.Error.t()) ::
              any()

  @doc """
  This function will be triggered in case of success invoking `Backplane.Oauth.authorize/3`
  """
  @callback authorize_success(
              conn :: Plug.Conn.t(),
              authorize_response :: Backplane.Oauth.AuthorizeResponse.t()
            ) :: any()
  @doc """
  This function will be triggered in case of failure invoking `Backplane.Oauth.authorize/3`
  """
  @callback authorize_error(conn :: Plug.Conn.t(), oauth_error :: Backplane.Oauth.Error.t()) ::
              any()

  @doc """
  This function will be triggered in case of success invoking `Backplane.Oauth.introspect/2`
  """
  @callback introspect_success(
              conn :: Plug.Conn.t(),
              introspect_response :: Backplane.Oauth.IntrospectResponse.t()
            ) :: any()
  @doc """
  This function will be triggered in case of failure invoking `Backplane.Oauth.introspect/2`
  """
  @callback introspect_error(conn :: Plug.Conn.t(), oauth_error :: Backplane.Oauth.Error.t()) ::
              any()

  @doc """
  This function will be triggered in case of success invoking `Backplane.Oauth.revoke/2`
  """
  @callback revoke_success(conn :: Plug.Conn.t()) :: any()
  @doc """
  This function will be triggered in case of failure invoking `Backplane.Oauth.revoke/2`
  """
  @callback revoke_error(conn :: Plug.Conn.t(), oauth_error :: Backplane.Oauth.Error.t()) :: any()

  @optional_callbacks preauthorize_success: 2, preauthorize_error: 2
end
