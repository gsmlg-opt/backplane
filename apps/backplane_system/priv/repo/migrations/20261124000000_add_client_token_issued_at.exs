defmodule Backplane.Repo.Migrations.AddClientTokenIssuedAt do
  use Ecto.Migration

  def change do
    alter table(:clients) do
      add(:token_issued_at, :utc_datetime_usec)
    end
  end
end
