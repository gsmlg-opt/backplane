defmodule Backplane.Repo.Migrations.AddCaptureFieldsToMemoryEvents do
  use Ecto.Migration

  def change do
    alter table(:bpm_events) do
      add(:schema_version, :integer)
      add(:integration, :text)
      add(:scope, :text)
      add(:parent_session_id, :text)
      add(:source_sequence, :bigint)
      add(:captured_at, :utc_datetime_usec)
      add(:payload_hash, :text)
      add(:privacy, :map, null: false, default: %{})
      add(:trace, :map, null: false, default: %{})
      add(:raw_envelope, :map, null: false, default: %{})
      add(:ingest_auth_token_id, :text)
    end
  end
end
