defmodule Backplane.Memory.Memories.RememberRequest do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "bpm_memory_remember_requests" do
    field(:idempotency_scope, :string)
    field(:idempotency_key, :string)
    field(:request_hash, :binary)
    field(:memory_id, :binary_id)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [:idempotency_scope, :idempotency_key, :request_hash, :memory_id])
    |> validate_required([:idempotency_scope, :idempotency_key, :request_hash, :memory_id])
    |> validate_length(:idempotency_scope, min: 1)
    |> validate_length(:idempotency_key, min: 1)
    |> unique_constraint([:idempotency_scope, :idempotency_key],
      name: :bpm_memory_remember_requests_scope_key_uniq
    )
    |> foreign_key_constraint(:memory_id)
    |> check_constraint(:request_hash, name: :bpm_memory_remember_requests_hash_length)
  end
end
