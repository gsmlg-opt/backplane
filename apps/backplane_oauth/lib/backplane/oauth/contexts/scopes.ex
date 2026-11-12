defmodule Backplane.Oauth.Scopes do
  @moduledoc """
  Scope context
  """

  @callback public() :: list(Backplane.Oauth.Scope.t())
end
