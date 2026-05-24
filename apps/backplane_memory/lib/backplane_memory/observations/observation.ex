defmodule BackplaneMemory.Observations.Observation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at]

  schema "bpm_observations" do
    field(:session_id, :string)
    field(:tool_name, :string)
    field(:content, :string)
    field(:is_error, :boolean, default: false)
    field(:files, :map, default: %{})
    timestamps()
  end

  def changeset(obs, attrs) do
    obs
    |> cast(attrs, [:session_id, :tool_name, :content, :is_error, :files])
    |> validate_required([:session_id, :content])
  end
end
