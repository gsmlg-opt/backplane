defmodule Backplane.Repo.Migrations.UpdateObanToV14 do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14, prefix: prefix() || "public")
  def down, do: Oban.Migration.down(version: 12, prefix: prefix() || "public")
end
