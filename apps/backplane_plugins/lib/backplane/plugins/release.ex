defmodule Backplane.Plugins.Release do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  schema "plugin_releases" do
    field :plugin_id, Ecto.UUID
    field :manifest, :map
    field :raw_manifest, :string
    field :upstream_version, :string
    field :artifact, :binary
    field :artifact_digest, :string
    field :source_commit, :string
    field :source_path, :string
    field :provenance, :map, default: %{}
    field :diagnostics, {:array, :map}, default: []
    field :published_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(
      attrs,
      ~w(plugin_id manifest raw_manifest upstream_version artifact artifact_digest source_commit source_path provenance diagnostics published_at)a
    )
    |> validate_required(~w(plugin_id manifest raw_manifest artifact artifact_digest)a)
    |> foreign_key_constraint(:plugin_id)
  end
end
