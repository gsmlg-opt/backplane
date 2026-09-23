defmodule Backplane.Repo.Migrations.ExpandLlmGoogleApiSurface do
  use Ecto.Migration

  def up do
    replace_surface_constraint(
      "llm_provider_apis",
      "llm_provider_apis_api_surface_check",
      "api_surface IN ('openai', 'anthropic', 'google')"
    )

    replace_surface_constraint(
      "llm_auto_model_routes",
      "llm_auto_model_routes_api_surface_check",
      "api_surface IN ('openai', 'anthropic', 'google')"
    )

    execute("""
    INSERT INTO #{qualified("llm_auto_model_routes")} (
      id,
      auto_model_id,
      api_surface,
      strategy,
      enabled,
      inserted_at,
      updated_at
    )
    SELECT
      gen_random_uuid(),
      auto_model.id,
      'google',
      'first_available',
      true,
      now(),
      now()
    FROM #{qualified("llm_auto_models")} AS auto_model
    ON CONFLICT (auto_model_id, api_surface) DO NOTHING
    """)
  end

  def down do
    refuse_configured_google_apis!()

    execute("""
    DELETE FROM #{qualified("llm_auto_model_routes")}
    WHERE api_surface = 'google'
    """)

    replace_surface_constraint(
      "llm_auto_model_routes",
      "llm_auto_model_routes_api_surface_check",
      "api_surface IN ('openai', 'anthropic')"
    )

    replace_surface_constraint(
      "llm_provider_apis",
      "llm_provider_apis_api_surface_check",
      "api_surface IN ('openai', 'anthropic')"
    )
  end

  defp refuse_configured_google_apis! do
    [[count]] =
      repo().query!(
        "SELECT count(*) FROM #{qualified("llm_provider_apis")} WHERE api_surface = 'google'"
      ).rows

    if count > 0 do
      raise Ecto.MigrationError,
            "remove Google provider APIs before rollback; refusing to discard configured endpoints or credential bindings"
    end
  end

  defp replace_surface_constraint(table, constraint, check) do
    execute("""
    ALTER TABLE #{qualified(table)}
    DROP CONSTRAINT #{quote_identifier(constraint)}
    """)

    execute("""
    ALTER TABLE #{qualified(table)}
    ADD CONSTRAINT #{quote_identifier(constraint)} CHECK (#{check})
    """)
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", &quote_identifier/1)
  end

  defp quote_identifier(identifier) do
    ~s("#{String.replace(identifier, "\"", "\"\"")}")
  end
end
