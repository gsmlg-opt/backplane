defmodule Backplane.Git.RateLimitCache do
  @moduledoc """
  ETS-backed cache for Git provider rate limit info.

  Stores the most recent rate limit headers from GitHub/GitLab API responses,
  keyed by provider instance name (e.g., "github", "gitlab.enterprise").
  """

  @table :backplane_rate_limits

  @doc "Initialize the ETS table. Called from ToolRegistry or Application startup."
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Store rate limit info for a provider instance.

  Expects a map with optional keys: :remaining, :limit, :reset.
  """
  @spec put(String.t(), map()) :: :ok
  def put(provider_key, info) when is_binary(provider_key) and is_map(info) do
    init_if_needed()
    :ets.insert(@table, {provider_key, info, System.system_time(:second)})
    :ok
  end

  @doc "Get rate limit info for a provider instance."
  @spec get(String.t()) :: map() | nil
  def get(provider_key) when is_binary(provider_key) do
    init_if_needed()

    case :ets.lookup(@table, provider_key) do
      [{^provider_key, info, _ts}] -> info
      [] -> nil
    end
  end

  @doc "Delete rate limit info for a provider instance."
  @spec delete(String.t()) :: :ok
  def delete(provider_key) when is_binary(provider_key) do
    init_if_needed()
    :ets.delete(@table, provider_key)
    :ok
  end

  @doc "Get all stored rate limit info."
  @spec all() :: [{String.t(), map()}]
  def all do
    init_if_needed()

    :ets.tab2list(@table)
    |> Enum.map(fn {key, info, _ts} -> {key, info} end)
  end

  @doc "Check if a provider is currently rate-limited (remaining == 0 and reset in the future)."
  @spec rate_limited?(String.t()) :: boolean()
  def rate_limited?(provider_key) when is_binary(provider_key) do
    case get(provider_key) do
      %{remaining: 0, reset: reset} when is_integer(reset) ->
        System.system_time(:second) < reset

      _ ->
        false
    end
  end

  defp init_if_needed do
    if :ets.whereis(@table) == :undefined do
      init()
    end
  end
end
