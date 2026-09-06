defmodule Backplane.MemorySpaces.BackfillIssue do
  @moduledoc "Recorded ambiguity that prevents safe memory identity backfill."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "bpm_memory_space_backfill_issues" do
    field(:source_table, :string)
    field(:source_id, :string)
    field(:reason, :string)
    field(:disposition, :string, default: "pending")
    field(:details, :map, default: %{})
    field(:resolved_at, :utc_datetime_usec)
    timestamps()
  end

  @doc false
  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [
      :source_table,
      :source_id,
      :reason,
      :disposition,
      :details,
      :resolved_at
    ])
    |> validate_required([:source_table, :source_id, :reason, :disposition, :details])
    |> validate_inclusion(:disposition, ["pending", "resolved", "approved_waiver"])
    |> unique_constraint([:source_table, :source_id],
      name: :bpm_memory_space_backfill_issues_source_index
    )
  end
end
