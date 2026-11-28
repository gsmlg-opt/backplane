defmodule Backplane.HostAgent.Diagnostics.Collectors.Runner do
  @moduledoc "Samples registered targets in a bounded worker and retains pending evidence across restart."

  use GenServer

  alias Backplane.HostAgent.Diagnostics.Collectors.{Cursor, Observation, Probes, Service}
  alias Backplane.HostAgent.Diagnostics.Collectors.Process, as: ProcessProbe

  @target_limit 32
  @interval_ms 15_000
  @trigger_interval_ms 60_000
  @worker_timeout_ms 5_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "Returns bounded process health counters without waiting for an active probe."
  def health(server \\ __MODULE__), do: GenServer.call(server, :health, 250)

  @doc "Coalesces an extra sample for a previously registered target."
  def trigger(server \\ __MODULE__, target_id)

  def trigger(server, target_id)
      when is_atom(server) and is_binary(target_id) and byte_size(target_id) in 1..128 do
    with {pid, gate} <- :persistent_term.get({__MODULE__, server}, nil),
         true <- Process.alive?(pid),
         :ok <- :atomics.compare_exchange(gate, 1, 0, 1) do
      send(pid, {:trigger, target_id})
      :ok
    else
      nil -> {:error, :unavailable}
      false -> {:error, :unavailable}
      _ -> :coalesced
    end
  end

  def trigger(_, _), do: {:error, :invalid_target}

  @doc "Parses the local operator's explicitly registered collector targets."
  def targets(input) when is_list(input) do
    input
    |> Enum.take(@target_limit)
    |> Enum.flat_map(fn item ->
      case parse_target(item) do
        nil -> []
        target -> [target]
      end
    end)
    |> Enum.group_by(& &1.id)
    |> Enum.flat_map(fn
      {_id, [target]} -> [target]
      _ -> []
    end)
    |> Enum.sort_by(& &1.id)
  end

  def targets(_input), do: []

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    targets = targets(Keyword.fetch!(opts, :targets))
    name = Keyword.fetch!(opts, :name)
    gate = :atomics.new(1, signed: false)

    env = %{
      platform: Keyword.get(opts, :platform, Probes.platform()),
      command: Keyword.get(opts, :command, &Probes.command/2),
      read: Keyword.get(opts, :read, &Probes.read/2),
      docker_socket: absolute_path(Keyword.get(opts, :docker_socket))
    }

    interval = Keyword.get(opts, :interval_ms, @interval_ms)
    spacing = max(250, div(max(1_000, interval), max(1, length(targets))))
    :persistent_term.put({__MODULE__, name}, {self(), gate})

    state = %{
      name: name,
      gate: gate,
      targets: targets,
      spacing: spacing,
      index: 0,
      active: nil,
      pending_trigger: nil,
      last_trigger: %{},
      epoch: random_id(),
      env: env,
      cursor_path: Keyword.fetch!(opts, :cursor_path),
      emit: Keyword.fetch!(opts, :emit),
      health: %{
        "samples" => 0,
        "failures" => 0,
        "unavailable_probes" => 0,
        "last_error" => nil,
        "last_sample_at" => nil
      }
    }

    Process.send_after(self(), :sample, spacing)
    {:ok, state}
  end

  @impl true
  def handle_call(:health, _from, state) do
    response =
      Map.merge(state.health, %{
        "targets" => length(state.targets),
        "sampling" => not is_nil(state.active),
        "platform" => Atom.to_string(state.env.platform),
        "service_adapters" => Service.capabilities(state.env.platform),
        "container_socket_configured" => is_binary(state.env.docker_socket)
      })

    {:reply, response, state}
  end

  @impl true
  def handle_info(:sample, state) do
    Process.send_after(self(), :sample, state.spacing)

    case state do
      %{active: nil, targets: [_ | _] = targets, index: index} ->
        task = start_worker(state, Enum.at(targets, index))
        {:noreply, %{task | index: rem(index + 1, length(targets))}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:trigger, id}, state) do
    :atomics.put(state.gate, 1, 0)
    target = Enum.find(state.targets, &(&1.id == id))
    now = System.monotonic_time(:millisecond)
    last = Map.get(state.last_trigger, id, now - @trigger_interval_ms)

    if target && now - last >= @trigger_interval_ms do
      state = %{state | last_trigger: Map.put(state.last_trigger, id, now)}

      {:noreply,
       if(state.active, do: %{state | pending_trigger: target}, else: start_worker(state, target))}
    else
      {:noreply, state}
    end
  end

  def handle_info({:sample_finished, pid, result}, %{active: %{pid: pid} = active} = state) do
    Process.demonitor(active.monitor, [:flush])
    _ = Process.cancel_timer(active.timeout)
    {:noreply, complete(state, result)}
  end

  def handle_info({:sample_timeout, pid}, %{active: %{pid: pid} = active} = state) do
    Process.exit(pid, :kill)
    {:noreply, %{state | active: Map.put(active, :timed_out, true)}}
  end

  def handle_info(
        {:DOWN, monitor, :process, _, _},
        %{active: %{monitor: monitor} = active} = state
      ) do
    _ = Process.cancel_timer(active.timeout)
    reason = if active[:timed_out], do: :sample_timeout, else: :sample_failed
    {:noreply, complete(state, {:error, reason})}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.active, do: Process.exit(state.active.pid, :kill)
    :persistent_term.erase({__MODULE__, state.name})
    :ok
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, Map.get(status.state, :health, %{}))

  defp start_worker(state, target) do
    parent = self()
    env = state.env
    path = state.cursor_path
    emit = state.emit
    epoch = state.epoch
    valid = Enum.map(state.targets, & &1.key)

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          result = sample(target, env, path, epoch, valid, emit)
          send(parent, {:sample_finished, self(), result})
        end,
        [:link, :monitor]
      )

    timeout = Process.send_after(self(), {:sample_timeout, pid}, @worker_timeout_ms)
    %{state | active: %{pid: pid, monitor: monitor, timeout: timeout}}
  end

  defp complete(state, result) do
    health =
      case result do
        {:ok, missing} ->
          state.health
          |> Map.update!("samples", &(&1 + 1))
          |> Map.update!("unavailable_probes", &(&1 + missing))
          |> Map.put("last_sample_at", DateTime.utc_now() |> DateTime.to_iso8601())
          |> Map.put("last_error", nil)

        {:error, reason} ->
          state.health
          |> Map.update!("failures", &(&1 + 1))
          |> Map.put("last_error", Atom.to_string(reason))
      end

    selected = state.pending_trigger
    state = %{state | active: nil, health: health, pending_trigger: nil}
    if selected, do: start_worker(state, selected), else: state
  end

  defp sample(target, env, path, epoch, valid, emit) do
    with {:ok, store} <- Cursor.load(path),
         {:ok, prepared, records} <- prepare(target, store, env, path, epoch, valid),
         :ok <- emit_records(records, target.source_id, emit),
         :ok <- save(path, put_in(prepared, ["targets", target.key, "pending"], nil)) do
      {:ok,
       Enum.reduce(records, 0, fn record, count -> count + unavailable(record["fields"]) end)}
    end
  rescue
    _error -> {:error, :sample_failed}
  catch
    _, _ -> {:error, :sample_failed}
  end

  defp prepare(target, store, env, path, epoch, valid) do
    previous = get_in(store, ["targets", target.key]) || %{}

    case previous["pending"] do
      [_ | _] = pending -> {:ok, store, pending}
      _ -> new_sample(target, previous, store, env, path, epoch, valid)
    end
  end

  defp new_sample(target, previous, store, env, path, epoch, valid) do
    env = Map.put(env, :boot_id, ProcessProbe.boot_identity(env))
    {observations, snapshot} = Observation.sample(target, previous["snapshot"] || %{}, env)
    sequences = if store["epoch"] == epoch, do: store["sequences"], else: %{}

    {records, sequence} =
      wire_records(observations, target, epoch, Map.get(sequences, target.source_id, 0))

    targets =
      store["targets"]
      |> Map.take(valid)
      |> Map.put(target.key, %{"snapshot" => snapshot, "pending" => records})

    prepared = %{
      "targets" => targets,
      "epoch" => epoch,
      "sequences" => Map.put(sequences, target.source_id, sequence)
    }

    with :ok <- save(path, prepared), do: {:ok, prepared, records}
  end

  defp wire_records(observations, target, epoch, sequence) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    Enum.map_reduce(observations, sequence, fn %{fields: fields} = observation, sequence ->
      sequence = sequence + 1

      id =
        if observation[:id],
          do: Probes.fingerprint({target.key, observation.id}),
          else: random_id()

      target_reference = %{"kind" => "registered_target", "reference" => target.id}

      fields =
        fields
        |> Map.merge(%{
          "event_id" => id,
          "producer_epoch" => epoch,
          "source_sequence" => sequence,
          "occurred_at" => timestamp
        })
        |> update_in(["evidence", "breadcrumbs"], &Enum.take([target_reference | &1 || []], 16))

      {%{"id" => id, "fields" => fields}, sequence}
    end)
  end

  defp emit_records(records, source_id, emit) do
    Enum.reduce_while(records, :ok, fn %{"id" => id, "fields" => fields}, :ok ->
      case emit.(source_id, %{id: id, fields: fields}) do
        :ok -> {:cont, :ok}
        _ -> {:halt, {:error, :delivery_unavailable}}
      end
    end)
  end

  defp save(path, store) do
    case Cursor.save(path, store) do
      :ok -> :ok
      {:error, :cursor_capacity} -> {:error, :cursor_capacity}
      {:error, _} -> {:error, :cursor_unavailable}
    end
  end

  defp unavailable(fields) do
    fields
    |> get_in(["evidence", "breadcrumbs"])
    |> List.wrap()
    |> Enum.count(&(&1["reference"] == "unavailable" or &1["kind"] == "measurement_unavailable"))
  end

  defp parse_target(%{"id" => id, "source_id" => source} = raw) do
    pid = positive_pid(raw["pid"])
    service = Service.parse(raw["service"])
    log = absolute_path(raw["log_path"])
    crash = absolute_path(raw["crash_path"])
    disk = absolute_path(raw["disk_path"])

    if id?(id) and id?(source) and (is_nil(pid) or is_nil(service)) and
         Enum.any?([pid, service, log, crash, disk]) do
      target = %{
        id: id,
        source_id: source,
        pid: pid,
        service: service,
        log_path: log,
        rotated_log_path: absolute_path(raw["rotated_log_path"]),
        crash_path: crash,
        disk_path: disk
      }

      Map.put(target, :key, Probes.fingerprint(target))
    end
  end

  defp parse_target(_), do: nil

  defp id?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_.:-]*\z/, value)

  defp id?(_), do: false

  defp positive_pid(value) when is_integer(value) and value in 1..2_147_483_647, do: value
  defp positive_pid(_), do: nil

  defp absolute_path(path) when is_binary(path) and byte_size(path) in 1..1_024 do
    if Path.type(path) == :absolute and String.valid?(path) and
         not String.contains?(path, [<<0>>, "\n", "\r"]),
       do: path
  end

  defp absolute_path(_), do: nil

  defp random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
