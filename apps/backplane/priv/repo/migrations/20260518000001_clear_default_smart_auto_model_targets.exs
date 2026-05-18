defmodule Backplane.Repo.Migrations.ClearDefaultSmartAutoModelTargets do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE system_settings
    SET value = '{"v":[]}'::jsonb,
        updated_at = now()
    WHERE key = 'llm.auto_models.smart.targets'
      AND value = '{"v":["minimax-m2.7","kimi-k2.6","glm-5.1"]}'::jsonb
    """)
  end

  def down do
    :ok
  end
end
