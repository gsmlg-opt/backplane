defmodule Backplane.Repo.Migrations.CreateAgentTraceEvents do
  use Ecto.Migration

  def change do
    create table(:agent_trace_events) do
      add :host_id, references(:skill_hosts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_seq, :bigint, null: false
      add :trace_id, :text, null: false
      add :span_id, :text, null: false
      add :parent_id, :text
      add :event, :text, null: false
      add :measurements, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("now()")
    end

    create unique_index(:agent_trace_events, [:host_id, :agent_seq])
    create index(:agent_trace_events, [:trace_id])
    create index(:agent_trace_events, [:host_id, :occurred_at])
  end
end
