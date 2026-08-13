defmodule Backplane.Memory.Imports.ImportBatch do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "memory_import_batches" do
    field(:host_id, :binary_id)
    field(:integration, :string)
    field(:source_format, :string)
    field(:source_path_fingerprint, :string)
    field(:status, :string)
    field(:discovered_count, :integer, default: 0)
    field(:imported_count, :integer, default: 0)
    field(:duplicate_count, :integer, default: 0)
    field(:rejected_count, :integer, default: 0)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:error, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, __schema__(:fields) -- [:inserted_at, :updated_at])
    |> validate_required([
      :id,
      :host_id,
      :integration,
      :source_format,
      :source_path_fingerprint,
      :status,
      :started_at
    ])
    |> validate_inclusion(:status, ~w(started completed failed))
    |> validate_format(:source_path_fingerprint, ~r/^sha256:[0-9a-f]{64}$/)
    |> validate_number(:discovered_count, greater_than_or_equal_to: 0)
    |> validate_number(:imported_count, greater_than_or_equal_to: 0)
    |> validate_number(:duplicate_count, greater_than_or_equal_to: 0)
    |> validate_number(:rejected_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:host_id)
    |> check_constraint(:status, name: :memory_import_batches_status_check)
    |> check_constraint(:discovered_count, name: :memory_import_batches_counts_check)
  end
end
