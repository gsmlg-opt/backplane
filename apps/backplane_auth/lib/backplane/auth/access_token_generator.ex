defmodule Backplane.Auth.AccessTokenGenerator do
  @moduledoc """
  Boruta token generator that issues RS256 JWT access tokens signed with the
  Backplane Auth signing key, so resource servers can verify them against
  `/oauth/jwks` without introspection.

  Authorization codes and refresh tokens stay opaque random strings. Boruta
  routes code values through the `:access_token` generator type, so the token
  `type` field is used to tell them apart.
  """

  @behaviour Boruta.Oauth.TokenGenerator

  alias Backplane.Auth.Tokens

  @impl Boruta.Oauth.TokenGenerator
  def generate(:access_token, %{type: "access_token"} = token) do
    Tokens.sign_access_token!(token)
  end

  def generate(_type, _token), do: random_token()

  @impl Boruta.Oauth.TokenGenerator
  def secret(_client), do: random_token()

  defp random_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
