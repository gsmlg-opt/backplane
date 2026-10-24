defmodule Backplane.Memory.Sources.Source do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "bpm_memory_sources" do
    field(:memory_space_id, :binary_id)
    field(:scope, :string)
    field(:namespace, :string)
    field(:host_id, :string)
    field(:integration, :string)
    field(:installation_id, :binary_id)
    field(:profile_id, :string)
    field(:target, :string)
    field(:revision_floor, :integer, default: 0)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Backplane.Memory.Sources.Entry do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "bpm_memory_source_entries" do
    field(:source_id, :binary_id)
    field(:entry_id, :binary_id)
    field(:revision, :integer)
    field(:mutation_id, :binary_id)
    field(:memory_id, :binary_id)
    field(:active, :boolean, default: false)
    field(:suppressed, :boolean, default: false)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Backplane.Memory.Sources.Mutation do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "bpm_memory_source_mutations" do
    field(:source_id, :binary_id)
    field(:entry_id, :binary_id)
    field(:revision, :integer)
    field(:operation, :string)
    field(:payload_digest, :string)
    field(:provenance, :map)
    field(:occurred_at, :utc_datetime_usec)
    field(:memory_id, :binary_id)
    field(:outcome, :string)
    field(:edge_revision, :integer)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Backplane.Memory.Sources.Reconciliation do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "bpm_memory_source_reconciliations" do
    field(:source_id, :binary_id)
    field(:revision, :integer)
    field(:page_count, :integer)
    field(:entry_count, :integer)
    field(:snapshot_hash, :string)
    field(:status, :string, default: "staging")
    field(:result, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Backplane.Memory.Sources.Page do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "bpm_memory_source_reconciliation_pages" do
    field(:reconciliation_id, :binary_id)
    field(:page_index, :integer)
    field(:page_hash, :string)
    field(:entries, {:array, :map})
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Backplane.Memory.Sources.RequestEvidence do
  use Ecto.Schema
  @primary_key false
  schema "bpm_memory_request_evidence" do
    field(:request_id, :binary_id, primary_key: true)
    field(:evidence_id, :binary_id, primary_key: true)
  end
end
