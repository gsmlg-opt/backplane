defmodule Backplane.Oauth.IntrospectApplication do
  @moduledoc """
  OAuth application behaviour - introspect endpoint

  Implement this behaviour in the application layer of your OAuth provider. The callbacks are triggered while calling functions from `Backplane.Oauth` module.
  """

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
end
