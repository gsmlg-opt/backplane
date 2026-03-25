defmodule Backplane.Docs.Project do
  @moduledoc """
  Ecto schema for the projects table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "projects" do
    field :repo, :string
    field :ref, :string, default: "main"
    field :description, :string
    field :last_indexed_at, :utc_datetime_usec
    field :index_hash, :string

    has_many :doc_chunks, Backplane.Docs.DocChunk, foreign_key: :project_id

    timestamps()
  end

  @required_fields ~w(id repo)a
  @optional_fields ~w(ref description last_indexed_at index_hash)a

  def changeset(project, attrs) do
    project
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
