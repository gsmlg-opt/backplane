defmodule Backplane.LLM.ModelResolver do
  @moduledoc """
  GenServer that resolves model strings to provider + raw model pairs.

  Supports two resolution strategies:
  1. **Prefixed format** — `"provider_name/model"` routes directly to a named provider
  2. **Auto model lookup** — unprefixed names such as `fast`, `smart`, and `expert`
     resolve through configured auto model target preferences

  Results are cached in an ETS table (`:llm_model_resolver_cache`) with a 30-second TTL.
  The cache is cleared whenever a `{:llm_providers_changed, _}` message arrives on the
  `"llm:providers"` PubSub topic.
  """

  use GenServer

  import Ecto.Query

  alias Backplane.LLM.AutoModel
  alias Backplane.LLM.AutoModelRoute
  alias Backplane.LLM.ModelAlias
  alias Backplane.LLM.ProviderApi
  alias Backplane.LLM.ProviderModel
  alias Backplane.LLM.ProviderModelSurface
  alias Backplane.LLM.Provider
  alias Backplane.PubSubBroadcaster
  alias Backplane.Repo

  @table :llm_model_resolver_cache
  @ttl_seconds 30

  # ── Client API ───────────────────────────────────────────────────────────────

  @doc "Start the GenServer (registered under its module name)."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Resolve `model_string` for the given `api_type` (`:anthropic` or `:openai`).

  Returns:
  - `{:ok, provider, raw_model}` on success
  - `{:error, :no_provider}` when no matching provider/alias is found
  """
  @spec resolve(atom(), String.t()) ::
          {:ok, Provider.t(), String.t()}
          | {:error, :no_provider}
  def resolve(api_type, model_string) when is_atom(api_type) and is_binary(model_string) do
    cache_key = {api_type, model_string}

    case lookup_cache(cache_key) do
      {:hit, result} ->
        result

      :miss ->
        result = do_resolve(api_type, model_string)
        put_cache(cache_key, result)
        result
    end
  end

  @doc "Clear all cached resolution results."
  @spec clear_cache() :: :ok
  def clear_cache do
    :ets.delete_all_objects(@table)
    :ok
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    PubSubBroadcaster.subscribe(PubSubBroadcaster.llm_providers_topic())
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:llm_providers_changed, _payload}, state) do
    clear_cache()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Resolution logic ─────────────────────────────────────────────────────────

  defp do_resolve(api_type, model_string) do
    case String.split(model_string, "/", parts: 2) do
      [provider_name, raw_model] ->
        resolve_prefixed(api_type, provider_name, raw_model)

      [_] ->
        resolve_alias(api_type, model_string)
    end
  end

  defp resolve_prefixed(api_type, provider_name, raw_model) do
    provider =
      Provider
      |> where([p], p.name == ^provider_name and is_nil(p.deleted_at))
      |> Repo.one()

    cond do
      is_nil(provider) ->
        {:error, :no_provider}

      not provider.enabled ->
        {:error, :no_provider}

      not provider_model_available?(provider, api_type, raw_model) ->
        {:error, :no_provider}

      true ->
        {:ok, provider, raw_model}
    end
  end

  defp resolve_alias(api_type, alias_name) do
    result =
      case AutoModelRoute.get_by_model_and_surface(alias_name, api_type) do
        nil ->
          {:error, :no_provider}

        route ->
          resolve_auto_model_route(route, api_type)
      end

    case result do
      {:error, :no_provider} -> resolve_custom_alias(api_type, alias_name)
      result -> result
    end
  end

  defp resolve_custom_alias(api_type, alias_name) do
    case ModelAlias.target_for(alias_name) do
      nil -> {:error, :no_provider}
      target -> resolve_custom_alias_target(api_type, target)
    end
  end

  defp resolve_custom_alias_target(api_type, target) do
    case AutoModelRoute.get_by_model_and_surface(target, api_type) do
      nil ->
        resolve_model_id_target(api_type, target)

      route ->
        resolve_auto_model_route(route, api_type)
    end
  end

  defp resolve_model_id_target(api_type, target) do
    case AutoModel.available_surfaces_for(api_type, [target]) do
      [surface | _] -> {:ok, surface.provider_model.provider, surface.provider_model.model}
      [] -> {:error, :no_provider}
    end
  end

  defp provider_model_available?(provider, api_type, raw_model) do
    ProviderModelSurface
    |> join(:inner, [surface], model in ProviderModel, on: surface.provider_model_id == model.id)
    |> join(:inner, [surface, _model], api in ProviderApi, on: surface.provider_api_id == api.id)
    |> where(
      [surface, model, api],
      model.provider_id == ^provider.id and model.model == ^raw_model and
        model.enabled == true and surface.enabled == true and api.enabled == true and
        api.api_surface == ^api_type
    )
    |> Repo.exists?()
  end

  defp resolve_auto_model_route(route, api_type) do
    route_enabled? = route.enabled and route.auto_model.enabled

    target =
      case AutoModel.available_surfaces_for(
             api_type,
             AutoModel.configured_model_ids(route.auto_model.name)
           ) do
        [surface | _] ->
          {:surface, surface}

        [] ->
          route.targets
          |> Enum.sort_by(& &1.priority)
          |> Enum.find(&usable_target?(&1, api_type))
      end

    case {route_enabled?, target} do
      {true, {:surface, surface}} ->
        {:ok, surface.provider_model.provider, surface.provider_model.model}

      {true, target} when not is_nil(target) ->
        surface = target.provider_model_surface
        {:ok, surface.provider_model.provider, surface.provider_model.model}

      _ ->
        {:error, :no_provider}
    end
  end

  defp usable_target?(target, api_type) do
    surface = target.provider_model_surface
    model = surface.provider_model
    provider = model.provider
    api = surface.provider_api

    target.enabled and surface.enabled and model.enabled and provider.enabled and
      is_nil(provider.deleted_at) and api.enabled and api.api_surface == api_type
  end

  # ── Cache helpers ─────────────────────────────────────────────────────────────

  defp lookup_cache(cache_key) do
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, cache_key) do
      [{^cache_key, result, expires_at}] when expires_at > now ->
        {:hit, result}

      [{^cache_key, _result, _expires_at}] ->
        :ets.delete(@table, cache_key)
        :miss

      [] ->
        :miss
    end
  end

  defp put_cache(cache_key, result) do
    expires_at = System.monotonic_time(:second) + @ttl_seconds
    :ets.insert(@table, {cache_key, result, expires_at})
  end
end
