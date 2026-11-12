defmodule Backplane.Oauth.Openid.DynamicRegistrationApplication do
  @moduledoc """
  Implement this behaviour in the application layer of your OpenID Connect provider.
  This behaviour gives all callbacks triggered invoking `Backplane.Oauth.Openid.register_client/3` function.
  """

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
