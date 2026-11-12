defmodule Backplane.Oauth.AccessTokensAdapter do
  @moduledoc """
  Encapsulate injected `Backplane.Oauth.AccessTokens` adapter in context configuration
  """

  @behaviour Backplane.Oauth.AccessTokens

  import Backplane.Oauth.Config, only: [access_tokens: 0]

  def get_by(params), do: access_tokens().get_by(params)
  def create(params, opts), do: access_tokens().create(params, opts)
  def revoke(token), do: access_tokens().revoke(token)
  def revoke_refresh_token(token), do: access_tokens().revoke_refresh_token(token)
end
