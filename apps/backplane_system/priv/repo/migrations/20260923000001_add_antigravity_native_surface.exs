defmodule Backplane.Repo.Migrations.AddAntigravityNativeSurface do
  use Ecto.Migration

  def up do
    alter table(:llm_provider_apis) do
      add(:backend_config, :map, null: false, default: %{})
    end

    replace_surface_constraint("api_surface IN ('openai', 'anthropic', 'google', 'antigravity')")

    execute("""
    INSERT INTO #{qualified("llm_auto_model_routes")}
      (id, auto_model_id, api_surface, strategy, enabled, inserted_at, updated_at)
    SELECT gen_random_uuid(), id, 'antigravity', 'first_available', true, now(), now()
    FROM #{qualified("llm_auto_models")}
    ON CONFLICT (auto_model_id, api_surface) DO NOTHING
    """)
  end

  def down do
    refuse_configured_antigravity_apis!()
    execute("DELETE FROM #{qualified("llm_auto_model_routes")} WHERE api_surface = 'antigravity'")
    replace_surface_constraint("api_surface IN ('openai', 'anthropic', 'google')")

    alter table(:llm_provider_apis) do
      remove(:backend_config)
    end
  end

  defp refuse_configured_antigravity_apis! do
    [[count]] =
      repo().query!(
        "SELECT count(*) FROM #{qualified("llm_provider_apis")} WHERE api_surface = 'antigravity'"
      ).rows

    if count > 0 do
      raise Ecto.MigrationError,
            "remove Antigravity provider APIs before rollback; refusing to discard configured native subscription bindings"
    end
  end

  defp replace_surface_constraint(check) do
    for table <- ["llm_provider_apis", "llm_auto_model_routes"] do
      constraint = table <> "_api_surface_check"
      execute("ALTER TABLE #{qualified(table)} DROP CONSTRAINT #{quote_identifier(constraint)}")

      execute(
        "ALTER TABLE #{qualified(table)} ADD CONSTRAINT #{quote_identifier(constraint)} CHECK (#{check})"
      )
    end
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", &quote_identifier/1)
  end

  defp quote_identifier(identifier), do: ~s("#{String.replace(identifier, "\"", "\"\"")}")
end
