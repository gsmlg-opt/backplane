defmodule Backplane.Repo do
  use Ecto.Repo,
    otp_app: :backplane,
    adapter: Ecto.Adapters.Postgres
end
