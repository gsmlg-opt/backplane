defmodule Backplane.Skills.SkillSource do
  @moduledoc """
  Ecto schema for the `skill_sources` table.
  Represents an upstream source (e.g. GitHub repo) from which skills can be synced.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "skill_sources" do
    field(:name, :string)
    field(:source_type, :string, default: "github")
    field(:url, :string)
    field(:branch, :string, default: "main")
    field(:path_prefix, :string, default: "skills/")
    field(:enabled, :boolean, default: true)
    field(:last_synced_at, :utc_datetime_usec)
    field(:last_sync_status, :string)
    field(:last_sync_error, :string)
    field(:sync_metadata, :map, default: %{})

    timestamps()
  end

  @required_fields ~w(name url)a
  @optional_fields ~w(source_type branch path_prefix enabled last_synced_at last_sync_status last_sync_error sync_metadata)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(source, attrs) do
    source
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:source_type, ~w(github))
    |> validate_format(:url, ~r/^https?:\/\//, message: "must be an HTTP(S) URL")
    |> unique_constraint([:url, :branch])
  end
end
