defmodule Backplane.HostAgent.Memory.Pruner do
  @moduledoc """
  Age-only retention for synced host-agent local memories.
  """

  use GenServer

  alias Backplane.HostAgent.Memory.Store
  alias ExTurso.Result

  @default_ttl_days 90
  @default_interval_ms :timer.hours(1)

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @impl true
  def init(opts) do
    state = normalize_opts(opts)
    schedule_prune(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:prune, state) do
    _ = prune_once(state)
    schedule_prune(state)
    {:noreply, state}
  end

  @doc "Runs one retention pass."
  def prune_once(opts \\ []) do
    opts = normalize_opts(opts)
    cutoff = Map.get(opts, :cutoff) || cutoff_from_ttl(opts.local_ttl_days)
    started_at = System.monotonic_time()

    sql = """
    DELETE FROM memories
    WHERE sync_state = 'synced'
      AND (
        (deleted_at IS NULL AND inserted_at < ?)
        OR (
          deleted_at IS NOT NULL
          AND NOT EXISTS (
            SELECT 1
            FROM memory_outbox
            WHERE memory_outbox.memory_id = memories.id
              AND memory_outbox.state IN ('pending', 'inflight', 'failed')
          )
        )
      )
    """

    case Store.execute(opts.store, sql, [cutoff]) do
      {:ok, %Result{num_rows: deleted}} ->
        duration = System.monotonic_time() - started_at

        :telemetry.execute(
          [:backplane, :host_agent, :memory_pruner, :run],
          %{deleted: deleted, duration: duration},
          %{cutoff: cutoff}
        )

        {:ok, %{"deleted" => deleted, "cutoff" => cutoff}}

      {:error, reason} ->
        {:error, {:storage_error, reason}}
    end
  end

  defp normalize_opts(opts) when is_list(opts) do
    config =
      Keyword.get(opts, :config, Application.get_env(:backplane_host_agent, :memory_config, %{}))

    %{
      store:
        Keyword.get(
          opts,
          :store,
          Application.get_env(:backplane_host_agent, :memory_store, Store)
        ),
      cutoff: Keyword.get(opts, :cutoff),
      local_ttl_days:
        Keyword.get(
          opts,
          :local_ttl_days,
          config_value(config, :local_ttl_days) || @default_ttl_days
        ),
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          config_value(config, :prune_interval_ms) || @default_interval_ms
        )
    }
  end

  defp normalize_opts(%{} = opts) do
    opts
    |> Map.to_list()
    |> normalize_opts()
  end

  defp schedule_prune(%{interval_ms: interval_ms})
       when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :prune, interval_ms)
  end

  defp schedule_prune(_state), do: :ok

  defp cutoff_from_ttl(ttl_days) when is_integer(ttl_days) and ttl_days >= 0 do
    DateTime.utc_now()
    |> DateTime.add(-ttl_days * 86_400, :second)
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp cutoff_from_ttl(_ttl_days), do: cutoff_from_ttl(@default_ttl_days)

  defp config_value(config, key) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key)))
  end

  defp config_value(_config, _key), do: nil
end
