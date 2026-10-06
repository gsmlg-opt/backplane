defmodule Backplane.Repo.Migrations.CreateLlmAudioBindings do
  use Ecto.Migration

  def change do
    bindings_table = qualified_name("llm_audio_bindings")
    provider_models_table = qualified_name("llm_provider_models")

    create unique_index(:llm_provider_models, [:id, :provider_id],
             name: :llm_provider_models_id_provider_id_index
           )

    create table(:llm_audio_bindings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :provider_id, references(:llm_providers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :provider_model_id, :binary_id, null: false
      add :operation, :text, null: false
      add :native_protocol, :text, null: false
      add :api_origin, :text, null: false
      add :enabled, :boolean, null: false, default: false
      add :credential_override, :text
      add :billing_label, :text, null: false, default: "payg"
      add :capabilities, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      "ALTER TABLE #{bindings_table} ADD CONSTRAINT llm_audio_bindings_model_provider_fkey FOREIGN KEY (provider_model_id, provider_id) REFERENCES #{provider_models_table} (id, provider_id) ON DELETE CASCADE",
      "ALTER TABLE #{bindings_table} DROP CONSTRAINT llm_audio_bindings_model_provider_fkey"
    )

    create unique_index(:llm_audio_bindings, [:provider_model_id, :operation])
    create index(:llm_audio_bindings, [:provider_id, :operation, :enabled])

    create constraint(:llm_audio_bindings, :llm_audio_bindings_operation_check,
             check: "operation IN ('speech', 'transcription')"
           )

    create constraint(:llm_audio_bindings, :llm_audio_bindings_protocol_check,
             check: "native_protocol IN ('minimax')"
           )

    create constraint(:llm_audio_bindings, :llm_audio_bindings_billing_label_check,
             check: "billing_label IN ('subscription', 'payg')"
           )
  end

  defp qualified_name(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn part -> ~s("#{String.replace(part, "\"", "\"\"")}") end)
  end
end
