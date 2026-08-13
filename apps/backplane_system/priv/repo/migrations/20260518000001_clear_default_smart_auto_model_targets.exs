defmodule Backplane.Repo.Migrations.ClearDefaultSmartAutoModelTargets do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE #{qualified("system_settings")}
    SET value = '{"v":[]}'::jsonb,
        updated_at = now()
    WHERE key = 'llm.auto_models.smart.targets'
      AND value = '{"v":["minimax-m2.7","kimi-k2.6","glm-5.1"]}'::jsonb
    """)
  end

  def down do
    :ok
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{identifier |> to_string() |> String.replace("\"", "\"\"")}")
    end)
  end
end
