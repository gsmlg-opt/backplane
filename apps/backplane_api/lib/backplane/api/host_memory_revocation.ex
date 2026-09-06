defmodule Backplane.Api.HostMemoryRevocation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  schema "bpm_host_memory_revocations" do
    field(:memory_space_id, :binary_id)
    field(:host_id, :string)
    field(:source_client_id, :string)
    field(:local_id, :string)
    field(:memory_id, :binary_id)
    field(:source_request_id, :binary_id)
    field(:scope, :string)
    field(:namespace, :string)
    field(:content_hash, :binary)
    timestamps()
  end

  def changeset(revocation, attrs) do
    revocation
    |> cast(attrs, [
      :memory_space_id,
      :host_id,
      :source_client_id,
      :local_id,
      :memory_id,
      :source_request_id,
      :scope,
      :namespace,
      :content_hash
    ])
    |> validate_required([
      :memory_space_id,
      :host_id,
      :local_id,
      :memory_id,
      :scope,
      :namespace,
      :content_hash
    ])
    |> unique_constraint([:host_id, :local_id])
    |> unique_constraint(:source_request_id)
  end
end
