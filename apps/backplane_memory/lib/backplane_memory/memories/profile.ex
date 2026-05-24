defmodule BackplaneMemory.Memories.Profile do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:project, :string, autogenerate: false}
  @timestamps_opts false

  schema "memory_profiles" do
    field(:top_concepts, :map, default: %{})
    field(:top_files, :map, default: %{})
    field(:patterns, :map, default: %{})
    field(:session_count, :integer, default: 0)
    field(:total_observations, :integer, default: 0)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :project,
      :top_concepts,
      :top_files,
      :patterns,
      :session_count,
      :total_observations,
      :updated_at
    ])
    |> validate_required([:project])
  end
end
