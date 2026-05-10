defmodule Backplane.LLM.AutoModel do
  @moduledoc """
  Backplane-owned public model names such as fast, smart, and expert.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.LLM.AutoModelRoute
  alias Backplane.LLM.AutoModelTarget
  alias Backplane.LLM.ProviderModelSurface
  alias Backplane.Repo

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @ordered_names ~w(fast smart expert)
  @allowed_names @ordered_names
  @name_positions @ordered_names |> Enum.with_index() |> Map.new()

  schema "llm_auto_models" do
    field(:name, :string)
    field(:description, :string)
    field(:enabled, :boolean, default: true)

    has_many(:routes, AutoModelRoute, foreign_key: :auto_model_id)

    timestamps()
  end

  @required_fields ~w(name)a
  @optional_fields ~w(description enabled)a

  @doc "Built-in auto model names in display order."
  @spec built_in_names() :: [String.t()]
  def built_in_names, do: @ordered_names

  @doc "Changeset for auto models."
  def changeset(auto_model, attrs) do
    auto_model
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:name, @allowed_names)
    |> unique_constraint(:name)
  end

  @doc "List auto models with routes and targets."
  @spec list() :: [t()]
  def list do
    __MODULE__
    |> preload(routes: [:targets])
    |> Repo.all()
    |> sort_by_model_order()
  end

  @doc "List auto models with route target provider/model details."
  @spec list_configurations() :: [t()]
  def list_configurations do
    target_query =
      from(target in AutoModelTarget,
        order_by: [asc: target.priority],
        preload: [provider_model_surface: [:provider_api, provider_model: [:provider]]]
      )

    route_query =
      from(route in AutoModelRoute,
        order_by: [asc: route.api_surface],
        preload: [targets: ^target_query]
      )

    __MODULE__
    |> preload(routes: ^route_query)
    |> Repo.all()
    |> sort_by_model_order()
  end

  @doc "Configured target model ids for an auto model name."
  @spec configured_model_ids(String.t()) :: [String.t()]
  def configured_model_ids(name) when is_binary(name) do
    case Backplane.Settings.get(setting_key(name)) do
      model_ids when is_list(model_ids) ->
        model_ids
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  @doc "List distinct enabled provider model ids that can be selected as auto-model targets."
  @spec list_available_target_model_ids() :: [String.t()]
  def list_available_target_model_ids do
    [:openai, :anthropic]
    |> Enum.flat_map(&ProviderModelSurface.list_enabled/1)
    |> Enum.map(& &1.provider_model.model)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "List currently available provider model surfaces for model ids on an API surface."
  @spec available_surfaces_for(atom(), [String.t()]) :: [ProviderModelSurface.t()]
  def available_surfaces_for(api_surface, model_ids) when api_surface in [:openai, :anthropic] do
    enabled_surfaces_for(api_surface, model_ids)
  end

  @doc "Configure one auto model's target model ids across all API-surface routes."
  @spec configure_targets(String.t(), [String.t()]) ::
          {:ok, %{target_count: non_neg_integer()}} | {:error, term()}
  def configure_targets(name, model_ids) when is_binary(name) and is_list(model_ids) do
    model_ids =
      model_ids
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    with :ok <- Backplane.Settings.set(setting_key(name), model_ids) do
      sync_configured_targets(name, model_ids)
    end
  end

  defp sync_configured_targets(name, model_ids) do
    result =
      Repo.transaction(fn ->
        auto_model =
          __MODULE__
          |> Repo.get_by!(name: name)
          |> Repo.preload(:routes)

        surfaces_by_route =
          Map.new(auto_model.routes, fn route ->
            {route.id, enabled_surfaces_for(route.api_surface, model_ids)}
          end)

        target_count =
          auto_model.routes
          |> Enum.map(fn route ->
            route
            |> sync_route_targets(Map.fetch!(surfaces_by_route, route.id))
          end)
          |> Enum.sum()

        %{target_count: target_count}
      end)

    case result do
      {:ok, _} = ok ->
        Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
        ok

      {:error, _} = error ->
        error
    end
  end

  defp setting_key(name), do: "llm.auto_models.#{name}.targets"

  defp sort_by_model_order(auto_models) do
    Enum.sort_by(auto_models, &Map.get(@name_positions, &1.name, map_size(@name_positions)))
  end

  defp enabled_surfaces_for(_api_surface, []), do: []

  defp enabled_surfaces_for(api_surface, model_ids) do
    ProviderModelSurface
    |> join(:inner, [surface], model in assoc(surface, :provider_model))
    |> join(:inner, [_surface, model], provider in assoc(model, :provider))
    |> join(:inner, [surface, _model, _provider], api in assoc(surface, :provider_api))
    |> where(
      [surface, model, provider, api],
      surface.enabled == true and model.enabled == true and provider.enabled == true and
        is_nil(provider.deleted_at) and api.enabled == true and api.api_surface == ^api_surface and
        model.model in ^model_ids
    )
    |> preload([surface, model, provider, api],
      provider_model: {model, provider: provider},
      provider_api: api
    )
    |> Repo.all()
    |> Enum.sort_by(fn surface ->
      {
        Enum.find_index(model_ids, &(&1 == surface.provider_model.model)) || 999_999,
        surface.provider_model.provider.name,
        surface.provider_model.model
      }
    end)
  end

  defp sync_route_targets(route, surfaces) do
    Repo.delete_all(
      from(target in AutoModelTarget, where: target.auto_model_route_id == ^route.id)
    )

    surfaces
    |> Enum.with_index()
    |> Enum.reduce_while(0, fn {surface, priority}, count ->
      case AutoModelTarget.create(%{
             auto_model_route_id: route.id,
             provider_model_surface_id: surface.id,
             priority: priority,
             enabled: true
           }) do
        {:ok, _target} -> {:cont, count + 1}
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end
end
