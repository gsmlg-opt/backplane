defmodule Backplane.Oauth.ScopesAdapter do
  @moduledoc """
  Encapsulate injected `Backplane.Oauth.Scopes` adapter in context configuration
  """
  @behaviour Backplane.Oauth.Scopes

  import Backplane.Oauth.Config, only: [scopes: 0]

  def public, do: scopes().public()
end
