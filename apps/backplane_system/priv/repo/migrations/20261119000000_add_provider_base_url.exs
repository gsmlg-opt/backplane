defmodule Backplane.Repo.Migrations.AddProviderBaseUrl do
  use Ecto.Migration

  def up do
    alter table(:llm_providers) do
      add :base_url, :text
    end

    # Preserve every existing API URL and header. The provider URL is a default
    # for new configurations, not a rewrite of already configured endpoints.
    execute """
    UPDATE #{qualified("llm_providers")} AS provider
    SET base_url = (
      SELECT api.base_url FROM #{qualified("llm_provider_apis")} AS api
      WHERE api.provider_id = provider.id
      ORDER BY CASE api.api_surface WHEN 'openai' THEN 0 ELSE 1 END, api.api_surface
      LIMIT 1
    )
    """
  end

  def down do
    alter table(:llm_providers) do
      remove :base_url
    end
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{String.replace(to_string(identifier), "\"", "\"\"")}")
    end)
  end
end
