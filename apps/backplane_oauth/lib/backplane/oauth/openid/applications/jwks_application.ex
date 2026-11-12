defmodule Backplane.Oauth.Openid.JwksApplication do
  @moduledoc """
  Implement this behaviour in the application layer of your OpenID Connect provider.
  This behaviour gives all callbacks triggered invoking `Backplane.Oauth.Openid.jwks/2` function.
  """

  @doc """
  This function will be triggered in case of success invoking `Backplane.Oauth.Opeind.jwks/2`
  """
  @callback jwk_list(conn :: Plug.Conn.t(), jwk_keys :: list(%JOSE.JWK{})) ::
              any()
end
