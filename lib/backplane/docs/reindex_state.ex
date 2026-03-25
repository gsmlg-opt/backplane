defmodule Backplane.Docs.ReindexState do
  @moduledoc """
  Ecto schema for the reindex_state table.
  Tracks the status of documentation reindexing per project.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:project_id, :string, autogenerate: false}

  schema "reindex_state" do
    field :commit_sha, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :chunk_count, :integer
    field :status, :string, default: "pending"
  end

  @fields ~w(project_id commit_sha started_at completed_at chunk_count status)a

  def changeset(state, attrs) do
    state
    |> cast(attrs, @fields)
    |> validate_required([:project_id, :status])
    |> validate_inclusion(:status, ~w(pending running completed failed))
  end
end
