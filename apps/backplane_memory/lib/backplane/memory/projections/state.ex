defmodule Backplane.Memory.Projections.State do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending enqueued running complete skipped failed dead_letter)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "bpm_projection_states" do
    field(:projector, :string)
    field(:subject_type, :string)
    field(:subject_id, :string)
    field(:processing_version, :string)
    field(:input_revision, :string)
    field(:output_revision, :string)
    field(:status, :string, default: "pending")
    field(:attempt_count, :integer, default: 0)
    field(:last_error, :string)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :projector,
      :subject_type,
      :subject_id,
      :processing_version,
      :input_revision,
      :output_revision,
      :status,
      :attempt_count,
      :last_error,
      :started_at,
      :completed_at
    ])
    |> validate_required([
      :projector,
      :subject_type,
      :subject_id,
      :processing_version,
      :status,
      :attempt_count
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:projector, :subject_type, :subject_id],
      name: :bpm_projection_states_subject_uniq
    )
    |> check_constraint(:status, name: :bpm_projection_states_status_check)
    |> check_constraint(:attempt_count, name: :bpm_projection_states_attempt_count_check)
  end
end
