defmodule Backplane.LLM.ProviderApi do
  @moduledoc """
  API surface configuration for an LLM provider.

  One provider can expose independent OpenAI-compatible and Anthropic Messages
  surfaces.
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

  schema "llm_provider_apis" do
    field(:api_surface, Ecto.Enum, values: [:openai, :anthropic])
    field(:base_url, :string)
    field(:enabled, :boolean, default: true)
    field(:default_headers, :map, default: %{})
    field(:model_discovery_enabled, :boolean, default: true)
    field(:model_discovery_path, :string)
    field(:last_discovered_at, :utc_datetime_usec)

    belongs_to(:provider, Provider, type: :binary_id)
    has_many(:model_surfaces, ProviderModelSurface, foreign_key: :provider_api_id)

    timestamps()
  end

  @required_fields ~w(provider_id api_surface base_url)a
  @optional_fields ~w(enabled default_headers model_discovery_enabled model_discovery_path last_discovered_at)a

  @doc "Changeset for creating or updating a provider API surface."
  def changeset(api, attrs) do
    api
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> update_change(:base_url, &trim_trailing_slash/1)
    |> validate_required(@required_fields)
    |> Provider.validate_api_url(:base_url)
    |> validate_default_headers()
    |> foreign_key_constraint(:provider_id)
    |> unique_constraint([:provider_id, :api_surface])
  end

  @doc "Create a provider API surface."
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    result =
      %__MODULE__{}
      |> changeset(attrs)
      |> Repo.insert()

    broadcast_on_ok(result)
  end

  @doc "Update a provider API surface."
  @spec update(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update(%__MODULE__{} = api, attrs) do
    result =
      api
      |> changeset(attrs)
      |> Repo.update()

    broadcast_on_ok(result)
  end

  @doc "List enabled provider API surfaces with providers preloaded."
  @spec list_enabled() :: [t()]
  def list_enabled do
    __MODULE__
    |> join(:inner, [api], provider in assoc(api, :provider))
    |> where(
      [api, provider],
      api.enabled == true and provider.enabled == true and is_nil(provider.deleted_at)
    )
    |> preload([_api, provider], provider: provider)
    |> Repo.all()
  end

  @doc "List provider API surfaces for a provider."
  @spec list_for_provider(binary()) :: [t()]
  def list_for_provider(provider_id) do
    __MODULE__
    |> where([api], api.provider_id == ^provider_id)
    |> order_by([api], api.api_surface)
    |> Repo.all()
  end

  @doc "Fetch a provider API surface by id."
  @spec get(binary()) :: t() | nil
  def get(id), do: Repo.get(__MODULE__, id)

  defp trim_trailing_slash(url) when is_binary(url), do: String.trim_trailing(url, "/")
  defp trim_trailing_slash(url), do: url

  defp validate_default_headers(changeset) do
    validate_change(changeset, :default_headers, fn
      :default_headers, headers when is_map(headers) -> []
      :default_headers, _headers -> [default_headers: "must be a map"]
    end)
  end

  defp broadcast_on_ok({:ok, _} = result) do
    Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
    result
  end

  defp broadcast_on_ok(result), do: result
end
