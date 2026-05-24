defmodule Backplane.Settings.TokenCache do
  @moduledoc "ETS-backed cache for OAuth2 access tokens with TTL."

  @table :credential_token_cache
  @safety_margin_seconds 60

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, type: :worker}
  end

  def start_link(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    :ignore
  end

  @spec get(String.t()) :: {:ok, String.t()} | :miss
  def get(credential_name) do
    case :ets.lookup(@table, credential_name) do
      [{_, token, expires_at}] ->
        if System.system_time(:second) < expires_at - @safety_margin_seconds,
          do: {:ok, token},
          else: :miss

      [] ->
        :miss
    end
  end

  @spec put(String.t(), String.t(), non_neg_integer()) :: :ok
  def put(credential_name, token, expires_in_seconds) do
    expires_at = System.system_time(:second) + expires_in_seconds
    :ets.insert(@table, {credential_name, token, expires_at})
    :ok
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(credential_name) do
    :ets.delete(@table, credential_name)
    :ok
  end

  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end
end
