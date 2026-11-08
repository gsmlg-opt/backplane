defmodule Backplane.Repo.Migrations.StripRetiredMemoryScopes do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE clients
    SET scopes = ARRAY(
      SELECT s FROM unnest(scopes) AS s
      WHERE s <> ALL (ARRAY['memory.coordinate', 'memory.replay', 'memory.admin']::text[])
    )
    WHERE scopes && ARRAY['memory.coordinate', 'memory.replay', 'memory.admin']::text[]
    """)
  end

  def down, do: :ok
end
