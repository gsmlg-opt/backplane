defmodule Backplane.Repo.Migrations.AddEnqueuedProjectionState do
  use Ecto.Migration

  @constraint "bpm_projection_states_status_check"

  def up do
    replace_constraint(~w(pending enqueued running complete skipped failed dead_letter))
  end

  def down do
    # Older releases do not understand `enqueued`. Map those derived states to
    # `pending` before restoring the old constraint so their workers retry from
    # the immutable canonical events. No accepted event rows are changed.
    execute(
      "UPDATE #{quoted_table("bpm_projection_states")} SET status = 'pending' WHERE status = 'enqueued'"
    )

    replace_constraint(~w(pending running complete skipped failed dead_letter))
  end

  defp replace_constraint(statuses) do
    table = quoted_table("bpm_projection_states")
    constraint = quote_name(@constraint)
    values = Enum.map_join(statuses, ", ", &"'#{&1}'")

    execute("ALTER TABLE #{table} DROP CONSTRAINT #{constraint}")
    execute("ALTER TABLE #{table} ADD CONSTRAINT #{constraint} CHECK (status IN (#{values}))")
  end

  defp quoted_table(name),
    do: Enum.map_join(Enum.reject([prefix(), name], &is_nil/1), ".", &quote_name/1)

  defp quote_name(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
end
