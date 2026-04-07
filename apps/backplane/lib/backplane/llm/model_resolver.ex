defmodule Backplane.LLM.ModelResolver do
  @moduledoc """
  GenServer that resolves model strings to provider + raw model pairs.

  Supports two resolution strategies:
  1. **Prefixed format** — `"provider_name/model"` routes directly to a named provider
  2. **Alias lookup** — unprefixed strings are looked up in the `llm_model_aliases` table

  Results are cached in an ETS table (`:llm_model_resolver_cache`) with a 30-second TTL.
  The cache is cleared whenever a `{:llm_providers_changed, _}` message arrives on the
  `"llm:providers"` PubSub topic.
  """

  use GenServer

  import Ecto.Query

  alias Backplane.LLM.ModelAlias
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
  - `{:error, :api_type_mismatch, provider}` when the found provider's api_type differs
  """
  @spec resolve(atom(), String.t()) ::
          {:ok, Provider.t(), String.t()}
          | {:error, :no_provider}
          | {:error, :api_type_mismatch, Provider.t()}
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

      provider.api_type != api_type ->
        {:error, :api_type_mismatch, provider}

      raw_model not in (provider.models || []) ->
        {:error, :no_provider}

      true ->
        {:ok, provider, raw_model}
    end
  end

  defp resolve_alias(api_type, alias_name) do
    result =
      from(a in ModelAlias,
        join: p in Provider,
        on: a.provider_id == p.id and is_nil(p.deleted_at) and p.enabled == true,
        where: a.alias == ^alias_name,
        select: {p, a.model}
      )
      |> Repo.one()

    case result do
      nil ->
        {:error, :no_provider}

      {provider, model} when provider.api_type == api_type ->
        {:ok, provider, model}

      {provider, _model} ->
        {:error, :api_type_mismatch, provider}
    end
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
