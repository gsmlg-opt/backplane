defmodule Backplane.Repo.Migrations.AlignMemoryV2ConfigurationDefaults do
  use Ecto.Migration

  def up do
    schema = quote_identifier(prefix() || "public")

    execute("""
    UPDATE #{schema}.system_settings
    SET value = '{"v":200}'::jsonb,
        description = 'Maximum files per host-local replay import (1..1000)'
    WHERE key = 'memory.replay_import_max_files'
      AND value = '{"v":100}'::jsonb
    """)

    execute("""
    UPDATE #{schema}.system_settings
    SET value = '{"v":1073741824}'::jsonb,
        description = 'Maximum bytes per host-local replay import (1..1073741824)'
    WHERE key = 'memory.replay_import_max_bytes'
      AND value = '{"v":100000000}'::jsonb
    """)
  end

  def down do
    schema = quote_identifier(prefix() || "public")

    execute("""
    UPDATE #{schema}.system_settings
    SET value = '{"v":100}'::jsonb,
        description = 'Maximum files per host-local replay import (1..1000)'
    WHERE key = 'memory.replay_import_max_files'
      AND value = '{"v":200}'::jsonb
    """)

    execute("""
    UPDATE #{schema}.system_settings
    SET value = '{"v":100000000}'::jsonb,
        description = 'Maximum bytes per host-local replay import (1..1000000000)'
    WHERE key = 'memory.replay_import_max_bytes'
      AND value = '{"v":1073741824}'::jsonb
    """)
  end

  defp quote_identifier(identifier), do: ~s("#{String.replace(identifier, "\"", "\"\"")}")
end
