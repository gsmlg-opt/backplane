defmodule Backplane.Memory.Crystals.Crystal do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "memory_crystals" do
    field(:memory_id, :binary_id)
    field(:subject_id, :string)
    field(:host_id, :string)
    field(:client_id, :string)
    field(:scope, :string)
    field(:namespace, :string)
    field(:source_session_id, :string)
    field(:source_kind, :string, default: "session")
    field(:action_chain_key, :string)
    field(:title, :string)
    field(:project, :string)
    field(:narrative, :string)
    field(:key_outcomes, {:array, :string}, default: [])
    field(:decisions, {:array, :string}, default: [])
    field(:files_affected, {:array, :string}, default: [])
    field(:unresolved_items, {:array, :string}, default: [])
    field(:processing_version, :string)
    field(:model, :string)
    field(:prompt_version, :string)
    field(:input_revision, :string)
    field(:output_revision, :string)
    field(:status, :string)
    field(:last_error, :string)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(crystal, attrs) do
    crystal
    |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> validate_required([
      :memory_id,
      :subject_id,
      :host_id,
      :client_id,
      :scope,
      :namespace,
      :source_session_id,
      :source_kind,
      :title,
      :narrative,
      :processing_version,
      :prompt_version,
      :input_revision,
      :output_revision,
      :status
    ])
    |> validate_inclusion(:status, ~w(pending running complete failed))
    |> validate_inclusion(:source_kind, ~w(session action_chain))
    |> validate_length(:title, max: 500)
    |> validate_length(:narrative, max: 65_536)
    |> validate_length(:key_outcomes, max: 100)
    |> validate_length(:decisions, max: 100)
    |> validate_length(:files_affected, max: 500)
    |> validate_length(:unresolved_items, max: 100)
    |> unique_constraint(
      [:client_id, :scope, :namespace, :host_id, :source_session_id, :processing_version],
      name: :memory_crystals_partition_session_version_uniq
    )
  end
end
