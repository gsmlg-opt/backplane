defmodule Backplane.LLM.ProviderModelSurface do
  @moduledoc """
  Per-API-surface enablement for a provider model.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.LLM.ProviderApi
  alias Backplane.LLM.ProviderModel
  alias Backplane.Repo

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "llm_provider_model_surfaces" do
    field(:enabled, :boolean, default: true)
    field(:last_seen_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})

    belongs_to(:provider_model, ProviderModel, type: :binary_id)
    belongs_to(:provider_api, ProviderApi, type: :binary_id)

    timestamps()
  end

  @required_fields ~w(provider_model_id provider_api_id)a
  @optional_fields ~w(enabled last_seen_at metadata)a

  @doc "Changeset for creating or updating provider model surface enablement."
  def changeset(surface, attrs) do
    surface
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_metadata()
    |> validate_same_provider()
    |> foreign_key_constraint(:provider_model_id)
    |> foreign_key_constraint(:provider_api_id)
    |> unique_constraint([:provider_model_id, :provider_api_id])
  end

  @doc "Create model surface enablement."
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    result =
      %__MODULE__{}
      |> changeset(attrs)
      |> Repo.insert()

    broadcast_on_ok(result)
  end

  @doc "Update model surface enablement."
  @spec update(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update(%__MODULE__{} = surface, attrs) do
    result =
      surface
      |> changeset(attrs)
      |> Repo.update()

    broadcast_on_ok(result)
  end

  @doc "List enabled model surfaces for an API surface."
  @spec list_enabled(atom()) :: [t()]
  def list_enabled(api_surface) when api_surface in [:openai, :anthropic] do
    __MODULE__
    |> join(:inner, [surface], model in assoc(surface, :provider_model))
    |> join(:inner, [_surface, model], provider in assoc(model, :provider))
    |> join(:inner, [surface, _model, _provider], api in assoc(surface, :provider_api))
    |> where(
      [surface, model, provider, api],
      surface.enabled == true and model.enabled == true and provider.enabled == true and
        is_nil(provider.deleted_at) and api.enabled == true and api.api_surface == ^api_surface
    )
    |> preload([surface, model, provider, api],
      provider_model: {model, provider: provider},
      provider_api: api
    )
    |> Repo.all()
  end

  @doc "Fetch a model surface by provider model and API surface ids."
  @spec get_by_model_and_api(binary(), binary()) :: t() | nil
  def get_by_model_and_api(provider_model_id, provider_api_id) do
    Repo.get_by(__MODULE__,
      provider_model_id: provider_model_id,
      provider_api_id: provider_api_id
    )
  end

  defp validate_metadata(changeset) do
    validate_change(changeset, :metadata, fn
      :metadata, metadata when is_map(metadata) -> []
      :metadata, _metadata -> [metadata: "must be a map"]
    end)
  end

  defp validate_same_provider(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_same_provider(changeset) do
    model_id = get_field(changeset, :provider_model_id)
    api_id = get_field(changeset, :provider_api_id)

    with true <- is_binary(model_id),
         true <- is_binary(api_id),
         %ProviderModel{} = model <- Repo.get(ProviderModel, model_id),
         %ProviderApi{} = api <- Repo.get(ProviderApi, api_id),
         true <- model.provider_id == api.provider_id do
      changeset
    else
      false ->
        add_error(changeset, :provider_api_id, "must belong to the same provider as the model")

      nil ->
        changeset

      _ ->
        changeset
    end
  end

  defp broadcast_on_ok({:ok, _} = result) do
    Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
    result
  end

  defp broadcast_on_ok(result), do: result
end
