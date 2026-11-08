defmodule Backplane.Repo.Migrations.StripRetiredMemoryScopesTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.Repo
  alias Backplane.Repo.Migrations.StripRetiredMemoryScopes, as: Migration

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20261109000002_strip_retired_memory_scopes.exs",
                    __DIR__
                  )
  @version 20_261_109_000_002

  setup do
    Code.require_file(@migration_path)
    prefix = "strip_scopes_#{System.unique_integer([:positive])}"
    Repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    Repo.query!(~s|CREATE TABLE "#{prefix}".clients (name text, scopes text[], active boolean)|)

    on_exit(fn -> Repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|) end)
    %{prefix: prefix}
  end

  test "strips retired scopes and deactivates clients left with none", %{prefix: prefix} do
    Repo.query!("""
    INSERT INTO "#{prefix}".clients (name, scopes, active) VALUES
      ('mixed', ARRAY['memory.read','memory.replay','docs::*'], true),
      ('only_retired', ARRAY['memory.admin','memory.coordinate'], true),
      ('untouched', ARRAY['memory.write'], true),
      ('already_empty_inactive', ARRAY[]::text[], false)
    """)

    Ecto.Migration.Runner.run(Repo, Repo.config(), @version, Migration, :forward, :up, :up,
      log: false,
      prefix: prefix
    )

    rows =
      Repo.query!(~s|SELECT name, scopes, active FROM "#{prefix}".clients ORDER BY name|).rows

    assert rows == [
             ["already_empty_inactive", [], false],
             ["mixed", ["memory.read", "docs::*"], true],
             ["only_retired", [], false],
             ["untouched", ["memory.write"], true]
           ]
  end
end
