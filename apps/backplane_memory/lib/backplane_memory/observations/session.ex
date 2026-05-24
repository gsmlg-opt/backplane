defmodule BackplaneMemory.Observations.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:session_id, :string, autogenerate: false}
  @timestamps_opts false

  schema "memory_sessions" do
    field(:project, :string)
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    field(:consolidated_at, :utc_datetime_usec)
    field(:observation_count, :integer, default: 0)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :session_id,
      :project,
      :started_at,
      :ended_at,
      :consolidated_at,
      :observation_count
    ])
    |> validate_required([:session_id])
  end
end
