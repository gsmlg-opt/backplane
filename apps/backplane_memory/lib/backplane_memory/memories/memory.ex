defmodule BackplaneMemory.Memories.Memory do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @valid_types ~w(working episodic semantic procedural)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "bpm_memories" do
    field(:content, :string)
    field(:memory_type, :string, default: "semantic")
    field(:scope, :string, default: "global")
    field(:agent_id, :string)
    field(:host_id, :string)
    field(:client_id, :string)
    field(:session_id, :string)
    field(:tags, {:array, :string}, default: [])
    field(:metadata, :map, default: %{})
    field(:namespace, :string, default: "private")
    field(:embedding, Pgvector.Ecto.HalfVector)
    field(:embedding_model, :string, default: "Qwen/Qwen3-Embedding-4B")
    field(:content_hash, :binary)
    field(:confidence, :float, default: 1.0)
    field(:access_count, :integer, default: 0)
    field(:accessed_at, :utc_datetime_usec)
    field(:superseded_by, :binary_id)
    field(:expires_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [
      :content,
      :memory_type,
      :namespace,
      :scope,
      :agent_id,
      :host_id,
      :client_id,
      :session_id,
      :tags,
      :metadata,
      :embedding_model,
      :confidence,
      :access_count,
      :accessed_at,
      :superseded_by,
      :expires_at,
      :deleted_at
    ])
    |> validate_required([:content, :agent_id, :host_id])
    |> validate_inclusion(:memory_type, @valid_types)
    |> derive_content_hash()
    |> unique_constraint([:content_hash, :scope],
      name: :bpm_memories_dedup_uniq,
      message: "duplicate memory"
    )
  end

  def embed_changeset(memory, vector) do
    change(memory, embedding: Pgvector.HalfVector.new(vector))
  end

  defp derive_content_hash(changeset) do
    case get_change(changeset, :content) do
      nil -> changeset
      content -> put_change(changeset, :content_hash, :crypto.hash(:sha256, content))
    end
  end
end
