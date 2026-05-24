defmodule Backplane.Repo do
  @moduledoc "Ecto repository backed by PostgreSQL."

  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end
