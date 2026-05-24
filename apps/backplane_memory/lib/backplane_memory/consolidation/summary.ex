defmodule BackplaneMemory.Consolidation.Summary do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at]

  schema "memory_summaries" do
    field(:session_id, :string)
    field(:project, :string, default: "")
    field(:content, :string)
    field(:observation_count, :integer, default: 0)
    timestamps()
  end

  def changeset(summary, attrs) do
    summary
    |> cast(attrs, [:session_id, :project, :content, :observation_count])
    |> validate_required([:session_id, :content])
  end
end
