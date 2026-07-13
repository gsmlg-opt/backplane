defmodule Backplane.Repo.Migrations.CreateMemoryEventStream do
  use Ecto.Migration

  def up do
    create table(:bpm_streams, primary_key: false) do
      add :stream_id, :text, primary_key: true
      add :project, :text
      add :agent_id, :text
      add :host_id, :text
      add :client_id, :text
      add :session_id, :text
      add :run_id, :text
      add :next_sequence, :bigint, null: false, default: 1
      add :last_window_sequence, :bigint, null: false, default: 0
      add :last_event_at, :utc_datetime_usec
      add :closed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create table(:bpm_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :stream_id,
          references(:bpm_streams, column: :stream_id, type: :text, on_delete: :restrict),
          null: false
      add :sequence, :bigint, null: false
      add :project, :text
      add :namespace, :text, null: false, default: "private"
      add :agent_id, :text
      add :host_id, :text
      add :client_id, :text
      add :session_id, :text
      add :run_id, :text
      add :event_type, :text, null: false
      add :actor_type, :text
      add :role, :text
      add :status, :text
      add :tool_name, :text
      add :content, :text
      add :correlation_id, :text
      add :idempotency_key, :text
      add :importance, :integer, null: false, default: 0
      add :payload, :map, null: false, default: %{}
      add :causation_id, :binary_id
      add :occurred_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:bpm_events, [:stream_id, :sequence], name: :bpm_events_stream_sequence_uniq)
    create unique_index(:bpm_events, [:stream_id, :idempotency_key],
             name: :bpm_events_idempotency_key_uniq,
             where: "idempotency_key IS NOT NULL"
           )
    create index(:bpm_events, [:session_id, :sequence])
    create index(:bpm_events, [:run_id, :sequence])
    execute(
      "CREATE INDEX bpm_events_project_occurred_at_idx ON bpm_events (project ASC, occurred_at DESC)",
      "DROP INDEX bpm_events_project_occurred_at_idx"
    )

    execute(
      "CREATE INDEX bpm_events_event_type_occurred_at_idx ON bpm_events (event_type ASC, occurred_at DESC)",
      "DROP INDEX bpm_events_event_type_occurred_at_idx"
    )
  end

  def down do
    drop table(:bpm_events)
    drop table(:bpm_streams)
  end
end
