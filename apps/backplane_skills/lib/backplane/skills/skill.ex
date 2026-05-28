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
    field(:name, :string)
    field(:description, :string, default: "")
    field(:tags, {:array, :string}, default: [])
    field(:category, :string)
    field(:content, :string)
    field(:content_hash, :string)
    field(:enabled, :boolean, default: true)
    field(:slug, :string)
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

    timestamps()
  end

  @required_fields ~w(id slug name content)a
  @optional_fields ~w(description tags category content_hash enabled version license homepage author meta archive_ref size_bytes file_count source_kind source_uri source_rev)a
  @archive_ref_pattern ~r/^sha256\/[a-f0-9]{64}\.tar\.gz$/

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(skill, attrs) do
    skill
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_archive_ref()
    |> unique_constraint(:slug)
  end

  @spec update_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def update_changeset(skill, attrs) do
    skill
    |> cast(attrs, ~w(content content_hash description tags category enabled)a)
  end

  defp validate_archive_ref(changeset) do
    validate_change(changeset, :archive_ref, fn
      :archive_ref, nil ->
        []

      :archive_ref, archive_ref ->
        if is_binary(archive_ref) and Regex.match?(@archive_ref_pattern, archive_ref) do
          []
        else
          [archive_ref: {"must match sha256/<64 lowercase hex>.tar.gz", [validation: :format]}]
        end
    end)
  end
end
