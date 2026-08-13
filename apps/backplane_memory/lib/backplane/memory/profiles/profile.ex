defmodule Backplane.Memory.Profiles.Profile do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts false

  schema "memory_profiles" do
    field(:project, :string)
    field(:host_id, :string)
    field(:client_id, :string)
    field(:scope, :string)
    field(:namespace, :string)
    field(:top_concepts, :map, default: %{})
    field(:top_files, :map, default: %{})
    field(:patterns, :map, default: %{})
    field(:active_lessons, :map, default: %{})
    field(:recent_crystals, :map, default: %{})
    field(:recent_summaries, :map, default: %{})
    field(:source_records, :map, default: %{})
    field(:summary, :string, default: "")
    field(:session_count, :integer, default: 0)
    field(:total_observations, :integer, default: 0)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :project,
      :host_id,
      :client_id,
      :scope,
      :namespace,
      :top_concepts,
      :top_files,
      :patterns,
      :active_lessons,
      :recent_crystals,
      :recent_summaries,
      :source_records,
      :summary,
      :session_count,
      :total_observations,
      :updated_at
    ])
    |> validate_required([:project])
  end
end
