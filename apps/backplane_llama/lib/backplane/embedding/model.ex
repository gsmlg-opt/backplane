defmodule Backplane.Embedding.Model do
  @moduledoc """
  Embedding model exposed by an embedding-only provider.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.Embedding.Provider

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "embedding_models" do
    field(:model, :string)
    field(:display_name, :string)
    field(:enabled, :boolean, default: true)
    field(:metadata, :map, default: %{})

    belongs_to(:provider, Provider, type: :binary_id)

    timestamps()
  end

  @required_fields ~w(provider_id model)a
  @optional_fields ~w(display_name enabled metadata)a

  @doc "Changeset for creating or updating an embedding model."
  def changeset(model, attrs) do
    model
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_metadata()
    |> foreign_key_constraint(:provider_id)
    |> unique_constraint([:provider_id, :model])
  end

  defp validate_metadata(changeset) do
    validate_change(changeset, :metadata, fn
      :metadata, metadata when is_map(metadata) -> []
      :metadata, _metadata -> [metadata: "must be a map"]
    end)
  end
end
