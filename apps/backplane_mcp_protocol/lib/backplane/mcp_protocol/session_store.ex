defmodule Backplane.McpProtocol.SessionStore do
  @moduledoc """
  ETS-backed MCP session store.
  """

  use GenServer

  @table :backplane_mcp_protocol_sessions
  @cleanup_interval_ms 300_000
  @max_age_seconds 3600

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec create(map()) :: {:ok, String.t()}
  def create(attrs) when is_map(attrs) do
    id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    now = System.system_time(:second)
    session = Map.merge(attrs, %{created_at: now, last_seen_at: now})
    :ets.insert(@table, {id, session})
    {:ok, id}
  end

  @spec get(String.t()) :: map() | nil
  def get(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, session}] -> session
      [] -> nil
    end
  end

  @spec touch(String.t()) :: :ok
  def touch(id) when is_binary(id) do
    case get(id) do
      nil ->
        :ok

      session ->
        :ets.insert(@table, {id, %{session | last_seen_at: System.system_time(:second)}})
    end

    :ok
  end

  @spec delete(String.t()) :: :ok
  def delete(id) when is_binary(id) do
    :ets.delete(@table, id)
    :ok
  end

  @spec cleanup_stale(pos_integer()) :: non_neg_integer()
  def cleanup_stale(max_age_seconds \\ @max_age_seconds) do
    cutoff = System.system_time(:second) - max_age_seconds

    match_spec = [
      {{:_, %{last_seen_at: :"$1"}}, [{:<, :"$1", cutoff}], [true]}
    ]

    :ets.select_delete(@table, match_spec)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_stale(@max_age_seconds)
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
