defmodule Backplane.LLM.ProviderModel do
  @moduledoc """
  Model known for an upstream LLM provider.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.LLM.Provider
  alias Backplane.LLM.ProviderModelSurface
  alias Backplane.Repo

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "llm_provider_models" do
    field(:model, :string)
    field(:display_name, :string)
    field(:source, Ecto.Enum, values: [:discovered, :manual], default: :manual)
    field(:enabled, :boolean, default: true)
    field(:metadata, :map, default: %{})

    belongs_to(:provider, Provider, type: :binary_id)
    has_many(:surfaces, ProviderModelSurface, foreign_key: :provider_model_id)

    timestamps()
  end

  @required_fields ~w(provider_id model source)a
  @optional_fields ~w(display_name enabled metadata)a

  @doc "Changeset for creating or updating a provider model."
  def changeset(model, attrs) do
    model
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_metadata()
    |> foreign_key_constraint(:provider_id)
    |> unique_constraint([:provider_id, :model])
  end

  @doc "Create a provider model."
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    result =
      %__MODULE__{}
      |> changeset(attrs)
      |> Repo.insert()

    broadcast_on_ok(result)
  end

  @doc "Update a provider model."
  @spec update(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update(%__MODULE__{} = model, attrs) do
    result =
      model
      |> changeset(attrs)
      |> Repo.update()

    broadcast_on_ok(result)
  end

  @doc "List models for a provider."
  @spec list_for_provider(binary()) :: [t()]
  def list_for_provider(provider_id) do
    __MODULE__
    |> where([model], model.provider_id == ^provider_id)
    |> order_by([model], model.model)
    |> preload(:surfaces)
    |> Repo.all()
  end

  @doc "Fetch a provider model by id with surfaces preloaded."
  @spec get(binary()) :: t() | nil
  def get(id) do
    __MODULE__
    |> preload(:surfaces)
    |> Repo.get(id)
  end

  @doc "Fetch a provider model by provider/model id."
  @spec get_by_provider_and_model(binary(), String.t()) :: t() | nil
  def get_by_provider_and_model(provider_id, model) do
    __MODULE__
    |> where([provider_model], provider_model.provider_id == ^provider_id)
    |> where([provider_model], provider_model.model == ^model)
    |> preload(:surfaces)
    |> Repo.one()
  end

  @doc "Delete a provider model."
  @spec delete(t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def delete(%__MODULE__{} = model) do
    result = Repo.delete(model)
    broadcast_on_ok(result)
  end

  defp validate_metadata(changeset) do
    validate_change(changeset, :metadata, fn
      :metadata, metadata when is_map(metadata) -> []
      :metadata, _metadata -> [metadata: "must be a map"]
    end)
  end

  defp broadcast_on_ok({:ok, _} = result) do
    Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
    result
  end

  defp broadcast_on_ok(result), do: result
end
