defmodule Backplane.SecretHub.Publication do
  @moduledoc """
  Where a credential was published in SecretHub, and the last sync outcome.

  Holds no secret values or value digests. `version` is the SecretHub version
  confirmed by the last successful publication; `last_error` is an error code.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:credential_name, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "secrethub_publications" do
    field(:path, :string)
    field(:version, :integer)
    field(:synced_at, :utc_datetime_usec)
    field(:last_attempt_at, :utc_datetime_usec)
    field(:last_error, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(publication, attrs) do
    publication
    |> cast(attrs, [:credential_name, :path, :version, :synced_at, :last_attempt_at, :last_error])
    |> validate_required([:credential_name, :path, :last_attempt_at])
    |> unique_constraint(:path)
  end
end
