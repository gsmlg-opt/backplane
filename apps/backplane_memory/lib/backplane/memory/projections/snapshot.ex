defmodule Backplane.Memory.Projections.Snapshot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "bpm_projection_snapshots" do
    field(:host_id, :string)
    field(:source_client_id, :string)
    field(:projector, :string)
    field(:subject_type, :string)
    field(:subject_id, :string)
    field(:input_revision, :string)
    field(:output_revision, :string)
    field(:read_model, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :projector,
      :host_id,
      :source_client_id,
      :subject_type,
      :subject_id,
      :input_revision,
      :output_revision,
      :read_model
    ])
    |> validate_required([
      :projector,
      :subject_type,
      :subject_id,
      :input_revision,
      :output_revision,
      :read_model
    ])
    |> unique_constraint([:projector, :subject_type, :subject_id],
      name: :bpm_projection_snapshots_subject_uniq
    )
  end
end
