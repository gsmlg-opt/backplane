defmodule Backplane.Memory.Observations.Observation do
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
