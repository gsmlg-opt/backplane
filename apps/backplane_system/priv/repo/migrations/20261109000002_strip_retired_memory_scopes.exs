defmodule Backplane.Repo.Migrations.StripRetiredMemoryScopes do
  use Ecto.Migration

  def up do
    p = ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}")

    execute("""
    UPDATE #{p}.clients
    SET scopes = ARRAY(
      SELECT s FROM unnest(scopes) AS s
      WHERE s <> ALL (ARRAY['memory.coordinate', 'memory.replay', 'memory.admin']::text[])
    )
    WHERE scopes && ARRAY['memory.coordinate', 'memory.replay', 'memory.admin']::text[]
    """)

    # Clients left with no scopes fail closed: deactivate them so they stay visible in admin.
    execute("""
    UPDATE #{p}.clients SET active = false
    WHERE scopes = ARRAY[]::text[] AND active
    """)
  end

  def down, do: :ok
end
