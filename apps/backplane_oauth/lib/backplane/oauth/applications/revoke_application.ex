defmodule Backplane.Oauth.RevokeApplication do
  @moduledoc """
  OAuth application behaviour - revoke endpoint

  Implement this behaviour in the application layer of your OAuth provider. The callbacks are triggered while calling functions from `Backplane.Oauth` module.
  """

  @doc """
  This function will be triggered in case of success invoking `Backplane.Oauth.revoke/2`
  """
  @callback revoke_success(conn :: Plug.Conn.t()) :: any()
  @doc """
  This function will be triggered in case of failure invoking `Backplane.Oauth.revoke/2`
  """
  @callback revoke_error(conn :: Plug.Conn.t(), oauth_error :: Backplane.Oauth.Error.t()) :: any()
end
