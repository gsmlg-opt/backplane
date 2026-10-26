Code.require_file("../migration_support/memory_legacy_cutover.exs", __DIR__)

defmodule Backplane.Repo.Migrations.RetireLegacyMemoryObservations do
  use Ecto.Migration

  def up do
    Backplane.Repo.MemoryLegacyCutover.migrate(repo(), prefix())
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "forward-only migration: canonical event identities must not return to retired storage"
  end
end
