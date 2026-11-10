defmodule Backplane.HostAgent.Collectors.Scheduler do
  @moduledoc """
  Periodically runs host collectors and appends changed snapshots to the capture
  spool as `host.snapshot.collected` events. Unchanged snapshots (same
  fingerprint) are never re-emitted; fingerprints persist across restarts in a
  state file keyed by host id (state of another host id is discarded; deleting
  the file forces one full re-report).

  Every payload carries `host_label` (the configured machine name, or the
  hostname). A snapshot that cannot be encoded or is malformed is skipped with a
  warning without affecting the others. A snapshot whose event would exceed
  `:max_bytes` keeps only its leading items and is marked incomplete.
  """

  use GenServer

  require Logger

  alias Backplane.HostAgent.Collectors.{Collector, Command}
  alias Backplane.HostAgent.Memory.{EventEnvelope, Spool, UUID7}

  @default_collectors [
    Backplane.HostAgent.Collectors.Git,
    Backplane.HostAgent.Collectors.Docker,
    Backplane.HostAgent.Collectors.Services,
    Backplane.HostAgent.Collectors.HostInfo
  ]

  @item_keys ["path", "name", "label"]

  # Default event size limit: the capture batch_bytes default minus upload wrapper headroom.
  @default_max_bytes 512 * 1024 - 1_024

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Runs every enabled collector once; returns emitted/unchanged snapshot counts."
  @spec run_once(GenServer.server()) :: %{
          emitted: non_neg_integer(),
          unchanged: non_neg_integer()
        }
  def run_once(server), do: GenServer.call(server, :run_once, :infinity)

  @impl true
  def init(opts) do
    state_path = Keyword.fetch!(opts, :state_path)
    host_id = Keyword.fetch!(opts, :host_id)

    state = %{
      host_id: host_id,
      host_label: host_label(Keyword.get(opts, :host_label)),
      max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes),
      spool: Keyword.fetch!(opts, :spool),
      spool_module: Keyword.get(opts, :spool_module, Spool.Turso),
      state_path: state_path,
      collectors: Keyword.get(opts, :collectors, @default_collectors),
      config: Keyword.get(opts, :config, %{}),
      env: Keyword.get(opts, :env, default_env()),
      interval_ms: Keyword.get(opts, :interval_ms, 900_000),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      fingerprints: load_state(state_path, host_id)
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
    occurred_at = state.clock.() |> DateTime.to_iso8601()
    payload = snapshot |> payload(state) |> fit(key, occurred_at, state)
    fingerprint = fingerprint(payload)

    if Map.get(state.fingerprints, key) == fingerprint do
      {%{counts | unchanged: counts.unchanged + 1}, state}
    else
      envelope = envelope(payload, fingerprint, occurred_at, state)

      case state.spool_module.append(state.spool, envelope) do
        {status, _} when status in [:ok, :duplicate] ->
          fingerprints = Map.put(state.fingerprints, key, fingerprint)
          persist_state(state.state_path, state.host_id, fingerprints)
          {%{counts | emitted: counts.emitted + 1}, %{state | fingerprints: fingerprints}}

        {:error, reason} ->
          Logger.warning("host snapshot #{key} not spooled: #{inspect(reason)}")
          {counts, state}
      end
    end
  rescue
    # One bad snapshot (invalid UTF-8, malformed shape) must not stop the run:
    # skip it and keep its old fingerprint so a later run retries.
    error ->
      Logger.warning("host snapshot skipped: #{Exception.message(error)}")
      {counts, state}
  end

  defp normalize(raw) do
    snapshot = raw |> Jason.encode!() |> Jason.decode!()

    valid? =
      is_binary(snapshot["collector"]) and is_binary(snapshot["unit"]) and
        is_boolean(snapshot["complete"]) and is_list(snapshot["items"]) and
        Enum.all?(snapshot["items"], &is_map/1)

    unless valid?,
      do: raise(ArgumentError, "malformed snapshot #{inspect(Map.delete(snapshot, "items"))}")

    Map.update!(snapshot, "items", &Enum.sort_by(&1, fn item -> item_key(item) end))
  end

  defp item_key(item) do
    Enum.find_value(@item_keys, "host", &Map.get(item, &1))
  end

  defp payload(snapshot, state) do
    snapshot
    |> Map.take(["collector", "unit", "complete", "items", "unscanned"])
    |> Map.put("host_label", state.host_label)
  end

  # Keeps the largest leading run of items whose event fits `max_bytes`.
  defp fit(payload, key, occurred_at, state) do
    if fits?(payload, occurred_at, state) do
      payload
    else
      items = payload["items"]
      truncated = %{payload | "complete" => false}
      kept = largest_fitting(truncated, items, 0, length(items), occurred_at, state)

      Logger.warning(
        "host snapshot #{key} exceeds #{state.max_bytes} bytes; " <>
          "kept #{kept} of #{length(items)} items and marked it incomplete"
      )

      %{truncated | "items" => Enum.take(items, kept)}
    end
  end

  # Binary search for the largest count in lo..hi that fits; lo = 0 must fit.
  defp largest_fitting(payload, items, lo, hi, occurred_at, state) when lo < hi do
    mid = div(lo + hi + 1, 2)

    if fits?(%{payload | "items" => Enum.take(items, mid)}, occurred_at, state),
      do: largest_fitting(payload, items, mid, hi, occurred_at, state),
      else: largest_fitting(payload, items, lo, mid - 1, occurred_at, state)
  end

  defp largest_fitting(payload, _items, lo, _hi, occurred_at, state) do
    if lo == 0 and not fits?(%{payload | "items" => []}, occurred_at, state),
      do: raise(ArgumentError, "snapshot exceeds #{state.max_bytes} bytes even without items")

    lo
  end

  defp fits?(payload, occurred_at, state) do
    envelope = envelope(payload, fingerprint(payload), occurred_at, state)
    byte_size(EventEnvelope.encode!(envelope)) <= state.max_bytes
  end

  defp fingerprint(payload) do
    "sha256:" <> hex =
      payload
      |> Map.take(["complete", "items", "unscanned", "host_label"])
      |> EventEnvelope.payload_hash()

    hex
  end

  defp envelope(payload, fingerprint, occurred_at, state) do
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
        "host_collector:#{payload["collector"]}:#{payload["unit"]}:#{fingerprint}:#{occurred_at}",
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

  defp host_label(label) when is_binary(label) do
    case String.trim(label) do
      "" -> host_label(nil)
      trimmed -> trimmed
    end
  end

  defp host_label(_label) do
    {:ok, name} = :inet.gethostname()
    name |> to_string() |> Collector.sanitize()
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

  # Fingerprints recorded for another host id (or in the old unkeyed format) are discarded.
  defp load_state(path, host_id) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"host_id" => ^host_id, "fingerprints" => %{} = fingerprints}} <-
           Jason.decode(body) do
      fingerprints
    else
      _ -> %{}
    end
  end

  defp persist_state(path, host_id, fingerprints) do
    tmp = path <> ".tmp"
    body = Jason.encode!(%{"host_id" => host_id, "fingerprints" => fingerprints})

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("host collector state not persisted: #{inspect(reason)}")
    end
  end
end
