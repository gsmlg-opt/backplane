defmodule Backplane.HostAgent.Collectors.Scheduler do
  @moduledoc """
  Periodically runs host collectors and appends changed snapshots to the capture
  spool as `host.snapshot.collected` events. Unchanged snapshots (same
  fingerprint) are never re-emitted; fingerprints persist across restarts.
  """

  use GenServer

  require Logger

  alias Backplane.HostAgent.Collectors.Command
  alias Backplane.HostAgent.Memory.{EventEnvelope, Spool, UUID7}

  @default_collectors [
    Backplane.HostAgent.Collectors.Git,
    Backplane.HostAgent.Collectors.Docker,
    Backplane.HostAgent.Collectors.Services,
    Backplane.HostAgent.Collectors.HostInfo
  ]

  @item_keys ["path", "name", "label"]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Runs every enabled collector once; returns emitted/unchanged snapshot counts."
  @spec run_once(GenServer.server()) :: %{emitted: non_neg_integer(), unchanged: non_neg_integer()}
  def run_once(server), do: GenServer.call(server, :run_once, :infinity)

  @impl true
  def init(opts) do
    state_path = Keyword.fetch!(opts, :state_path)

    state = %{
      host_id: Keyword.fetch!(opts, :host_id),
      spool: Keyword.fetch!(opts, :spool),
      spool_module: Keyword.get(opts, :spool_module, Spool.Turso),
      state_path: state_path,
      collectors: Keyword.get(opts, :collectors, @default_collectors),
      config: Keyword.get(opts, :config, %{}),
      env: Keyword.get(opts, :env, default_env()),
      interval_ms: Keyword.get(opts, :interval_ms, 900_000),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      fingerprints: load_state(state_path)
    }

    if Keyword.get(opts, :auto_run, true) do
      Process.send_after(self(), :tick, Keyword.get(opts, :initial_delay_ms, 60_000))
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:run_once, _from, state) do
    {counts, state} = run(state)
    {:reply, counts, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_counts, state} = run(state)
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  defp run(state) do
    state.collectors
    |> Enum.flat_map(&collect(&1, state))
    |> Enum.reduce({%{emitted: 0, unchanged: 0}, state}, &process_snapshot/2)
  end

  defp collect(module, state) do
    section = module.config_key()
    config = Map.get(state.config, section) || %{}

    if Map.get(config, :enabled, true) == false,
      do: [],
      else: module.collect(config, state.env)
  rescue
    error ->
      Logger.warning("host collector #{inspect(module)} failed: #{Exception.message(error)}")
      []
  catch
    kind, reason ->
      Logger.warning("host collector #{inspect(module)} failed: #{inspect({kind, reason})}")
      []
  end

  defp process_snapshot(raw, {counts, state}) do
    snapshot = normalize(raw)
    key = snapshot["collector"] <> ":" <> snapshot["unit"]
    fingerprint = fingerprint(snapshot)

    if Map.get(state.fingerprints, key) == fingerprint do
      {%{counts | unchanged: counts.unchanged + 1}, state}
    else
      envelope = envelope(snapshot, fingerprint, state)

      case state.spool_module.append(state.spool, envelope) do
        {status, _} when status in [:ok, :duplicate] ->
          fingerprints = Map.put(state.fingerprints, key, fingerprint)
          persist_state(state.state_path, fingerprints)
          {%{counts | emitted: counts.emitted + 1}, %{state | fingerprints: fingerprints}}

        {:error, reason} ->
          Logger.warning("host snapshot #{key} not spooled: #{inspect(reason)}")
          {counts, state}
      end
    end
  end

  defp normalize(raw) do
    snapshot = raw |> Jason.encode!() |> Jason.decode!()
    Map.update!(snapshot, "items", &Enum.sort_by(&1, fn item -> item_key(item) end))
  end

  defp item_key(item) do
    Enum.find_value(@item_keys, "host", &Map.get(item, &1))
  end

  defp fingerprint(snapshot) do
    "sha256:" <> hex =
      EventEnvelope.payload_hash(%{
        "complete" => snapshot["complete"],
        "items" => snapshot["items"]
      })

    hex
  end

  defp envelope(snapshot, fingerprint, state) do
    occurred_at = state.clock.() |> DateTime.to_iso8601()
    payload = Map.take(snapshot, ["collector", "unit", "complete", "items"])

    %{
      schema_version: 1,
      event_id: UUID7.generate(),
      host_id: state.host_id,
      agent_id: "host-collector",
      client_id: "host_collector",
      integration: "host_collector",
      event_type: "host.snapshot.collected",
      occurred_at: occurred_at,
      captured_at: occurred_at,
      idempotency_key:
        "host_collector:#{snapshot["collector"]}:#{snapshot["unit"]}:#{fingerprint}:#{occurred_at}",
      payload_hash: EventEnvelope.payload_hash(payload),
      privacy: %{
        "filtered" => false,
        "filter_version" => "pending",
        "redaction_count" => 0,
        "private_blocks_removed" => 0
      },
      payload: payload
    }
  end

  defp default_env do
    os =
      case :os.type() do
        {:unix, :linux} -> :linux
        {:unix, :darwin} -> :darwin
        _ -> :other
      end

    %{runner: &Command.run/3, os: os, home: System.user_home!()}
  end

  defp load_state(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = map} <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  defp persist_state(path, fingerprints) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, Jason.encode!(fingerprints)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("host collector state not persisted: #{inspect(reason)}")
    end
  end
end
