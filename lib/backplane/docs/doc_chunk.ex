defmodule Backplane.Docs.DocChunk do
  @moduledoc """
  Ecto schema for the doc_chunks table.
  Stores parsed documentation chunks with full-text search support.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "doc_chunks" do
    belongs_to :project, Backplane.Docs.Project, type: :string
    field :source_path, :string
    field :module, :string
    field :function, :string
    field :chunk_type, :string
    field :content, :string
    field :content_hash, :string
    field :tokens, :integer

    timestamps(updated_at: false)
  end

  @required_fields ~w(project_id source_path chunk_type content content_hash)a
  @optional_fields ~w(module function tokens)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:project_id)
  end
end
