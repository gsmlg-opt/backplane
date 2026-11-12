defmodule Backplane.Oauth.Cache do
  @moduledoc """
  Backplane OAuth Ecto adapter uses [Nebulex](https://github.com/cabol/nebulex) in order to cache entities
  """

  use Nebulex.Cache,
    otp_app: :backplane_oauth,
    adapter: Nebulex.Adapters.Replicated
end
