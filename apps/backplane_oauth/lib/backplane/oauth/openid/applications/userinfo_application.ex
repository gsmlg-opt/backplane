defmodule Backplane.Oauth.Openid.UserinfoApplication do
  @moduledoc """
  Implement this behaviour in the application layer of your OpenID Connect provider.
  This behaviour gives all callbacks triggered invoking `Backplane.Oauth.Openid.userinfo/2` function.
  """

  @doc """
  This function will be triggered in case of success invoking `Backplane.Oauth.Openid.userinfo/2`
  """
  @callback userinfo_fetched(conn :: Plug.Conn.t(), userinfo :: map()) :: any()

  @doc """
  This function will be triggered when request is unauthorized invoking `Backplane.Oauth.Openid.userinfo/2`
  """
  @callback unauthorized(conn :: Plug.Conn.t(), error :: Backplane.Oauth.Error.t()) :: any()
end
