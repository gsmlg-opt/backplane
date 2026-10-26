defmodule Backplane.Memory.LegacyFixtures.Observation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at]

  schema "bpm_observations" do
    field(:memory_space_id, :binary_id)
    field(:host_id, :string)
    field(:source_client_id, :string)
    field(:scope, :string)
    field(:namespace, :string)
    field(:session_id, :string)
    field(:tool_name, :string)
    field(:content, :string)
    field(:is_error, :boolean, default: false)
    field(:files, :map, default: %{})
    timestamps()
  end

  def changeset(obs, attrs) do
    obs
    |> cast(attrs, [
      :memory_space_id,
      :host_id,
      :source_client_id,
      :scope,
      :namespace,
      :session_id,
      :tool_name,
      :content,
      :is_error,
      :files
    ])
    |> validate_required([:memory_space_id, :scope, :namespace, :session_id, :content])
  end
end

defmodule Backplane.Memory.LegacyFixtures.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:session_id, :string, autogenerate: false}
  @timestamps_opts false

  schema "memory_sessions" do
    field(:memory_space_id, :binary_id)
    field(:host_id, :string)
    field(:source_client_id, :string)
    field(:scope, :string)
    field(:namespace, :string)
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
      :memory_space_id,
      :host_id,
      :source_client_id,
      :scope,
      :namespace,
      :project,
      :started_at,
      :ended_at,
      :consolidated_at,
      :observation_count
    ])
    |> validate_required([:session_id, :memory_space_id, :scope, :namespace])
  end
end
