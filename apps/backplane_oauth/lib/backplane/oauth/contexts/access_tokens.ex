defmodule Backplane.Oauth.AccessTokens do
  @moduledoc """
  Access token context
  """

  @doc """
  Returns a `Backplane.Oauth.Token` either by `value` or `refresh_token`.
  """
  @callback get_by(
              [value: String.t()]
              | [refresh_token: String.t()]
            ) :: token :: Backplane.Oauth.Token.t() | nil

  @doc """
  Persists a token with the given params.
  """
  @callback create(
              params :: %{
                :client => Backplane.Oauth.Client.t(),
                :sub => String.t(),
                optional(:redirect_uri) => String.t(),
                :scope => String.t(),
                optional(:state) => String.t(),
                optional(:previous_token) => String.t(),
                optional(:resource_owner) => Backplane.Oauth.ResourceOwner.t()
              },
              options :: [
                refresh_token: boolean()
              ]
            ) :: token :: Backplane.Oauth.Token.t() | {:error, reason :: term()}

  @doc """
  Revokes the given `Backplane.Oauth.Token`.
  """
  @callback revoke(token :: Backplane.Oauth.Token.t()) ::
              {:ok, Backplane.Oauth.Token.t()} | {:error, reason :: term()}

  @doc """
  Revokes only the given `Backplane.Oauth.Token` refresh token.
  """
  @callback revoke_refresh_token(token :: Backplane.Oauth.Token.t()) ::
              {:ok, Backplane.Oauth.Token.t()} | {:error, reason :: term()}
end
