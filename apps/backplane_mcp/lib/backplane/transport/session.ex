defmodule Backplane.Transport.Session do
  @moduledoc """
  ETS-backed MCP session registry.

  Tracks per-session state including the negotiated protocol version and
  client capabilities. This enables version-aware response formatting —
  older clients receive responses without newer fields like `outputSchema`.

  Sessions are automatically cleaned up after `@max_age_seconds` of inactivity.
  """

  use GenServer

  require Logger

  @table :backplane_mcp_sessions
  @cleanup_interval_ms 300_000
  @max_age_seconds 3600

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Create a new session with the given negotiated state."
  @spec create(String.t(), String.t(), map(), map()) :: :ok
  def create(session_id, protocol_version, client_info, client_capabilities) do
    now = System.system_time(:second)

    entry = %{
      protocol_version: protocol_version,
      client_info: client_info || %{},
      client_capabilities: client_capabilities || %{},
      created_at: now,
      last_seen_at: now
    }

    :ets.insert(@table, {session_id, entry})
    :ok
  end

  @doc "Get session state by ID. Returns nil if not found."
  @spec get(String.t()) :: map() | nil
  def get(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Get the negotiated protocol version for a session. Returns latest if unknown."
  @spec protocol_version(String.t() | nil) :: String.t()
  def protocol_version(nil), do: Backplane.MCP.Info.protocol_version()

  def protocol_version(session_id) do
    case get(session_id) do
      %{protocol_version: v} -> v
      nil -> Backplane.MCP.Info.protocol_version()
    end
  end

  @doc "Check if the client declared a specific capability."
  @spec client_has_capability?(String.t() | nil, String.t()) :: boolean()
  def client_has_capability?(nil, _capability), do: false

  def client_has_capability?(session_id, capability) do
    case get(session_id) do
      %{client_capabilities: caps} -> Map.has_key?(caps, capability)
      nil -> false
    end
  end

  @doc "Update the last_seen_at timestamp for a session."
  @spec touch(String.t()) :: :ok
  def touch(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, entry}] ->
        :ets.insert(@table, {session_id, %{entry | last_seen_at: System.system_time(:second)}})
        :ok

      [] ->
        :ok
    end
  end

  @doc "Delete a session."
  @spec delete(String.t()) :: :ok
  def delete(session_id) do
    :ets.delete(@table, session_id)
    :ok
  end

  @doc "Count active sessions."
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size)
  end

  # Server callbacks

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

  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Remove sessions older than max_age_seconds."
  @spec cleanup_stale(pos_integer()) :: non_neg_integer()
  def cleanup_stale(max_age_seconds \\ @max_age_seconds) do
    cutoff = System.system_time(:second) - max_age_seconds

    match_spec = [
      {{:_, %{last_seen_at: :"$1"}}, [{:<, :"$1", cutoff}], [true]}
    ]

    :ets.select_delete(@table, match_spec)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
