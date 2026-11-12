defmodule Backplane.Oauth.Codes do
  @moduledoc """
  Code context
  """

  @doc """
  Returns a `Backplane.Oauth.Token` by `value` and `redirect_uri`.
  """
  @callback get_by(params :: [value: String.t(), redirect_uri: String.t()]) ::
              token :: Backplane.Oauth.Token | nil

  @doc """
  Persists a token according to given params.
  """
  @callback create(
              params :: %{
                :client => Backplane.Oauth.Client.t(),
                :sub => String.t(),
                :redirect_uri => String.t(),
                :scope => String.t(),
                :state => String.t(),
                :code_challenge => String.t(),
                :code_challenge_method => String.t(),
                :resource_owner => Backplane.Oauth.ResourceOwner.t()
              }
            ) :: code :: Backplane.Oauth.Token.t() | {:error, reason :: term()}

  @doc """
  Revokes the given `Backplane.Oauth.Token` code.
  """
  @callback revoke(token :: Backplane.Oauth.Token.t()) ::
              {:ok, Backplane.Oauth.Token.t()} | {:error, reason :: term()}

  @doc """
  Revokes the the previouly issued token given `Backplane.Oauth.Token` code.
  """
  @callback revoke_previous_token(token :: Backplane.Oauth.Token.t()) ::
              {:ok, Backplane.Oauth.Token.t()} | {:error, reason :: term()}
end
