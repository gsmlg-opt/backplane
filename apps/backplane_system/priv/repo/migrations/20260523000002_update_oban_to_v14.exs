defmodule Backplane.Repo.Migrations.UpdateObanToV14 do
  use Ecto.Migration

  def up do
    schema = prefix() || "public"
    quoted = quote_name(schema)

    create_if_not_exists index(:oban_jobs, [:state, :cancelled_at], prefix: schema)
    create_if_not_exists index(:oban_jobs, [:state, :discarded_at], prefix: schema)

    execute """
    ALTER TYPE #{quoted}.oban_job_state ADD VALUE IF NOT EXISTS 'suspended' BEFORE 'scheduled'
    """

    execute "COMMENT ON TABLE #{quoted}.oban_jobs IS '14'"
  end

  def down do
    schema = prefix() || "public"
    quoted = quote_name(schema)

    execute "UPDATE #{quoted}.oban_jobs SET state = 'scheduled' WHERE state = 'suspended'"
    drop_if_exists index(:oban_jobs, [:state, :discarded_at], prefix: schema)
    drop_if_exists index(:oban_jobs, [:state, :cancelled_at], prefix: schema)
    execute "COMMENT ON TABLE #{quoted}.oban_jobs IS '12'"
  end

  defp quote_name(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
end
