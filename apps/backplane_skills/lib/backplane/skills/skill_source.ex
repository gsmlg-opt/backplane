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
    field(:selected_skills, {:array, :string}, default: [])
    field(:sync_tags, {:array, :string}, default: [])

    timestamps()
  end

  @required_fields ~w(name url)a
  @optional_fields ~w(source_type branch path_prefix enabled last_synced_at last_sync_status last_sync_error sync_metadata selected_skills sync_tags)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(source, attrs) do
    source
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:source_type, ~w(github git))
    |> validate_url_by_type()
    |> unique_constraint([:url, :branch])
  end

  defp validate_url_by_type(changeset) do
    source_type = get_field(changeset, :source_type)
    url = get_field(changeset, :url)

    case source_type do
      "git" ->
        # Git requires full URL
        validate_format(changeset, :url, ~r/^https?:\/\//, message: "must be a full HTTP(S) URL for git sources")

      "github" ->
        # GitHub allows full URL or org/repo shorthand
        if url && !String.match?(url, ~r/^https?:\/\//) do
          if String.match?(url, ~r/^[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+$/) do
            # Expand org/repo to full GitHub URL
            put_change(changeset, :url, "https://github.com/#{url}")
          else
            add_error(changeset, :url, "must be a GitHub URL or org/repo shorthand (e.g. owner/repo)")
          end
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
