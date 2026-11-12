defmodule Backplane.Oauth.CodesAdapter do
  @moduledoc """
  Encapsulate injected `Backplane.Oauth.Codes` adapter in context configuration
  """

  @behaviour Backplane.Oauth.Codes

  import Backplane.Oauth.Config, only: [codes: 0]

  def get_by(params), do: codes().get_by(params)
  def create(params), do: codes().create(params)
  def revoke(code), do: codes().revoke(code)
  def revoke_previous_token(code), do: codes().revoke_previous_token(code)
end
