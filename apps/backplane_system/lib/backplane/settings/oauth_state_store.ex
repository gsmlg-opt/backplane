defmodule Backplane.Settings.OAuthStateStore do
  @moduledoc """
  Short-lived ETS store for OAuth authorization code flow state.

  Each pending authorization gets a random `state` token as the key.
  Entries expire after 10 minutes (enforced on read, not by a timer).
  """

  @table :oauth_state_store
  @ttl_ms 600_000

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link do
    :ets.new(@table, [:named_table, :public, :set])
    :ignore
  end

  @doc "Store OAuth state. Returns the state token."
  @spec put(map()) :: String.t()
  def put(attrs) do
    state = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    :ets.insert(@table, {state, attrs, System.monotonic_time(:millisecond)})
    state
  end

  @doc "Fetch and delete state by token. Returns `{:ok, attrs}` or `:error`."
  @spec pop(String.t()) :: {:ok, map()} | :error
  def pop(state) do
    case :ets.take(@table, state) do
      [{^state, attrs, inserted_at}] ->
        now = System.monotonic_time(:millisecond)

        if now - inserted_at <= @ttl_ms do
          {:ok, attrs}
        else
          :error
        end

      [] ->
        :error
    end
  end
end
