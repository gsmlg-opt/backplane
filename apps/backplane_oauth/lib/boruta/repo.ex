defmodule Boruta.Repo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :backplane_oauth,
    adapter: Ecto.Adapters.Postgres
end
