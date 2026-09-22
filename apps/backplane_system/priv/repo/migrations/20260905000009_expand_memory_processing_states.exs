defmodule Backplane.Repo.Migrations.ExpandMemoryProcessingStates do
  use Ecto.Migration

  @constraint "bpm_projection_states_status_check"

  def up do
    table = quoted_table("bpm_projection_states")
    drop_constraint(table)

    execute("""
    UPDATE #{table}
    SET status = CASE
      WHEN lower(coalesce(last_error, '')) IN ('no_llm', 'no_model', 'llm_model_missing', 'model_not_configured')
        THEN 'skipped_no_model'
      WHEN lower(coalesce(last_error, '')) IN ('disabled', 'feature_disabled', 'crystal_disabled')
        THEN 'skipped_disabled'
      ELSE 'failed'
    END
    WHERE status = 'skipped'
    """)

    add_constraint(
      table,
      ~w(pending enqueued running complete skipped_no_model skipped_disabled failed dead_letter)
    )
  end

  def down do
    table = quoted_table("bpm_projection_states")
    drop_constraint(table)

    execute("""
    UPDATE #{table}
    SET status = 'skipped'
    WHERE status IN ('skipped_no_model', 'skipped_disabled')
    """)

    add_constraint(table, ~w(pending enqueued running complete skipped failed dead_letter))
  end

  defp drop_constraint(table) do
    constraint = quote_name(@constraint)
    execute("ALTER TABLE #{table} DROP CONSTRAINT #{constraint}")
  end

  defp add_constraint(table, statuses) do
    constraint = quote_name(@constraint)
    values = Enum.map_join(statuses, ", ", &"'#{&1}'")

    execute("ALTER TABLE #{table} ADD CONSTRAINT #{constraint} CHECK (status IN (#{values}))")
  end

  defp quoted_table(name),
    do: Enum.map_join(Enum.reject([prefix(), name], &is_nil/1), ".", &quote_name/1)

  defp quote_name(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
end
