defmodule Backplane.Repo.Migrations.CreateObanTables do
  use Ecto.Migration

  # Preserve the historical v12 schema for migrations that backfill oban_jobs. The
  # later Styx migration renames this storage without requiring the Oban package.
  def up do
    schema = prefix() || "public"
    quoted = quote_name(schema)

    execute "CREATE SCHEMA IF NOT EXISTS #{quoted}"

    execute """
    CREATE TYPE #{quoted}.oban_job_state AS ENUM (
      'available', 'suspended', 'scheduled', 'executing', 'retryable',
      'completed', 'discarded', 'cancelled'
    )
    """

    create table(:oban_jobs, primary_key: false, prefix: schema) do
      add :id, :bigserial, primary_key: true
      add :state, :"#{quoted}.oban_job_state", null: false, default: "available"
      add :queue, :text, null: false, default: "default"
      add :worker, :text, null: false
      add :args, :map, null: false, default: %{}
      add :meta, :map, default: %{}
      add :tags, {:array, :text}, default: []
      add :errors, {:array, :map}, null: false, default: []
      add :attempt, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 20
      add :priority, :integer, null: false, default: 0
      add :attempted_by, {:array, :text}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('UTC', now())")

      add :scheduled_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('UTC', now())")

      add :attempted_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :discarded_at, :utc_datetime_usec
    end

    create index(:oban_jobs, [:state, :queue, :priority, :scheduled_at, :id], prefix: schema)
    create index(:oban_jobs, [:args], using: :gin, prefix: schema)
    create index(:oban_jobs, [:meta], using: :gin, prefix: schema)

    for {name, check} <- [
          attempt_range: "attempt between 0 and max_attempts",
          positive_max_attempts: "max_attempts > 0",
          non_negative_priority: "priority >= 0",
          queue_length: "char_length(queue) > 0 AND char_length(queue) < 128",
          worker_length: "char_length(worker) > 0 AND char_length(worker) < 128"
        ] do
      create constraint(:oban_jobs, name, check: check, prefix: schema)
    end

    create table(:oban_peers, primary_key: false, prefix: schema) do
      add :name, :text, null: false, primary_key: true
      add :node, :text, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    execute "ALTER TABLE #{quoted}.oban_peers SET UNLOGGED"
    execute "COMMENT ON TABLE #{quoted}.oban_jobs IS '12'"
  end

  def down do
    schema = prefix() || "public"
    drop table(:oban_peers, prefix: schema)
    drop table(:oban_jobs, prefix: schema)
    execute "DROP TYPE #{quote_name(schema)}.oban_job_state"
  end

  defp quote_name(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
end
