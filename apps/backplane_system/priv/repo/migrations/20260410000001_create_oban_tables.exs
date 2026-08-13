defmodule Backplane.Repo.Migrations.CreateObanTables do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 12, prefix: prefix() || "public")
  def down, do: Oban.Migration.down(version: 1, prefix: prefix() || "public")
end
