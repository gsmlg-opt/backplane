defmodule Backplane.Repo.Migrations.CreateLlmCodexCatalogEntries do
  use Ecto.Migration

  def change do
    create table(:llm_codex_catalog_entries, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:public_model_id, :text, null: false)
      add(:source_model, :text, null: false)
      add(:display_name, :text)
      add(:description, :text)
      add(:enabled, :boolean, null: false, default: false)
      add(:priority, :integer, null: false, default: 100)
      add(:context_window_override, :bigint)
      add(:reasoning_metadata, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_codex_catalog_entries, [:public_model_id])
    create index(:llm_codex_catalog_entries, [:enabled, :priority, :public_model_id],
             name: :llm_codex_catalog_enabled_priority_idx
           )

    create constraint(:llm_codex_catalog_entries, :llm_codex_catalog_priority_check,
             check: "priority >= 0 AND priority <= 2147483647"
           )

    create constraint(:llm_codex_catalog_entries, :llm_codex_catalog_context_window_check,
             check: "context_window_override IS NULL OR context_window_override > 0"
           )
  end
end
