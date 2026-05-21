defmodule Backplane.Skills.Skill do
  @moduledoc """
  Ecto schema for the skills table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "skills" do
    field(:slug, :string)
    field(:name, :string)
    field(:description, :string, default: "")
    field(:tags, {:array, :string}, default: [])
    field(:content, :string)
    field(:content_hash, :string)
    field(:version, :string)
    field(:license, :string)
    field(:homepage, :string)
    field(:author, :string)
    field(:meta, :map, default: %{})
    field(:archive_ref, :string)
    field(:size_bytes, :integer)
    field(:file_count, :integer)
    field(:source_kind, :string)
    field(:source_uri, :string)
    field(:source_rev, :string)
    field(:enabled, :boolean, default: true)

    timestamps()
  end

  @required_fields ~w(id slug name content)a
  @optional_fields ~w(
    description tags content_hash version license homepage author meta archive_ref size_bytes
    file_count source_kind source_uri source_rev enabled
  )a
  @updatable_fields [:content | @optional_fields]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(skill, attrs) do
    skill
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> put_derived_slug()
    |> validate_required(@required_fields)
    |> update_change(:slug, &normalize_slug/1)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$/,
      message: "must contain only lowercase letters, numbers, and hyphens"
    )
  end

  @spec update_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def update_changeset(skill, attrs) do
    skill
    |> cast(attrs, @updatable_fields)
  end

  @doc "Derive a URL-safe slug from skill metadata."
  @spec slugify(String.t() | nil) :: String.t() | nil
  def slugify(nil), do: nil

  def slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp put_derived_slug(changeset) do
    case get_field(changeset, :slug) do
      value when is_binary(value) and value != "" ->
        changeset

      _ ->
        case get_field(changeset, :name) do
          name when is_binary(name) and name != "" -> put_change(changeset, :slug, slugify(name))
          _ -> changeset
        end
    end
  end

  defp normalize_slug(slug) when is_binary(slug), do: slugify(slug)
  defp normalize_slug(other), do: other
end
