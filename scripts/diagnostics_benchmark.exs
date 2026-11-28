defmodule Backplane.Diagnostics.Benchmark do
  @moduledoc false

  alias Backplane.Diagnostics.{Events, Issues, Projector, Sources}
  alias Backplane.DiagnosticsClient.{Envelope, Receipt, Reporter}
  alias Backplane.HostAgent.Diagnostics.{Spool, Uploader}
  alias Backplane.Repo

  @reporter __MODULE__.Reporter
  @normal_rounds 16
  @normal_batch 64
  @storm_workers 8
  @storm_requests 5_000
  @spool_sources 4
  @spool_events 1_200
  @spool_max 4 * 1024 * 1024
  @spool_disk_max 16 * 1024 * 1024
  @postgres_batches 100
  @postgres_batch_size 32
  @issue_count 256
  @page_rounds 25
  @page_size 30
  @rss_allowance_kib 64 * 1024
  @telemetry_key {__MODULE__, :commits}
  @telemetry_event [:diagnostics_benchmark, :repo, :query]

  defmodule Acknowledgement do
    @moduledoc false
    def push(_, "diagnostics_sync", %{"batch_id" => batch_id, "events" => entries}, _) do
      receipts = Enum.map(entries, &Receipt.result(&1, "stored"))
      {:ok, Receipt.response(:remote, batch_id, receipts)}
    end
  end

  def main do
    {:ok, _} = Application.ensure_all_started(:crypto)
    {:ok, _} = Application.ensure_all_started(:ex_turso)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    work = Path.join("/tmp", "backplane-diagnostics-benchmark-#{unique_id()}")
    true = Path.dirname(work) == "/tmp"
    File.mkdir!(work)
    File.chmod!(work, 0o700)

    try do
      normal = normal_reporter()
      storm = storm_reporter()
      spool = spool_fixture(work)
      postgres = with_postgres(work, &postgres_fixture/0)

      gates = gates(normal, storm, spool, postgres)

      results = %{
        recorded_at: DateTime.to_iso8601(DateTime.utc_now()),
        system: system(),
        normal_reporter: normal,
        failure_storm: storm,
        spool: spool,
        postgres: postgres,
        gates: gates
      }

      IO.puts(Formata.JSON.encode!(results, pretty: true))
      if Enum.all?(gates, fn {_, pass} -> pass end), do: :ok, else: :failed
    after
      File.rm_rf!(work)
    end
  end

  defp system do
    {os, 0} = System.cmd("uname", ["-sm"])

    %{
      os: String.trim(os),
      hardware: hardware(),
      otp: System.otp_release(),
      elixir: System.version(),
      schedulers: System.schedulers_online(),
      ex_turso: Application.spec(:ex_turso, :vsn) |> to_string()
    }
  end

  defp hardware do
    if match?({:unix, :darwin}, :os.type()) do
      {cpu, 0} = System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"])
      {memory, 0} = System.cmd("sysctl", ["-n", "hw.memsize"])
      %{cpu: String.trim(cpu), memory_bytes: memory |> String.trim() |> String.to_integer()}
    else
      %{logical_cpu_count: :erlang.system_info(:logical_processors_online)}
    end
  end

  defp normal_reporter do
    disabled = normal_rounds()

    enabled =
      with_reporter(&local_ack/1, fn ->
        normal_rounds(fn -> wait_until(fn -> Reporter.health(@reporter).pending == 0 end) end)
      end)

    %{disabled: disabled, enabled: enabled, requests_per_mode: @normal_rounds * @normal_batch}
  end

  defp normal_rounds(wait \\ fn -> :ok end) do
    for _ <- 1..2 do
      requests(@normal_batch)
      wait.()
    end

    observations =
      Enum.flat_map(1..@normal_rounds, fn _ ->
        values = requests(@normal_batch)
        wait.()
        values
      end)

    request_summary(observations)
  end

  defp storm_reporter do
    # Exercise identical business input and concurrency with diagnostics disabled first.
    disabled = measure_rss(&storm_requests/0)

    {enabled, health} =
      with_reporter(fn _ -> {:error, :host_unavailable} end, fn ->
        sampled = measure_rss(&storm_requests/0)
        {sampled, Reporter.health(@reporter)}
      end)

    %{
      request_count: @storm_workers * @storm_requests,
      producer_count: @storm_workers,
      disabled: disabled,
      enabled: enabled,
      unavailable_reporter: health
    }
  end

  defp storm_requests do
    1..@storm_workers
    |> Task.async_stream(
      fn _ ->
        Enum.flat_map(1..div(@storm_requests, 250), fn burst ->
          if burst > 1, do: Process.sleep(10)
          requests(250)
        end)
      end,
      max_concurrency: @storm_workers,
      timeout: 15_000
    )
    |> Enum.flat_map(fn {:ok, observations} -> observations end)
    |> request_summary()
  end

  defp requests(count) do
    for sequence <- 1..count do
      timed(fn ->
        result = :erlang.phash2({sequence, "synthetic operation"})

        Reporter.report(
          %{
            "event_type" => "exception",
            "subject" => %{"run_id" => "synthetic-#{result}"},
            "evidence" => %{"exception" => %{"type" => "SyntheticFault", "message" => message()}}
          },
          @reporter
        )
      end)
    end
  end

  defp request_summary(observations) do
    %{
      latency_us: observations |> Enum.map(&elem(&1, 0)) |> percentiles(),
      outcomes: observations |> Enum.map(&request_outcome(elem(&1, 1))) |> Enum.frequencies()
    }
  end

  defp request_outcome(:enqueued), do: :enqueued
  defp request_outcome({:error, reason}), do: reason

  defp with_reporter(sender, fun) do
    {:ok, reporter} =
      Reporter.start_link(
        name: @reporter,
        source_id: "benchmark",
        application: "benchmark",
        interval_ms: 10,
        send_batch: sender
      )

    try do
      fun.()
    after
      GenServer.stop(reporter)
    end
  end

  defp local_ack(%{"batch_id" => batch_id, "events" => entries}) do
    {:ok, Receipt.response(:local, batch_id, Enum.map(entries, &Receipt.result(&1, "stored")))}
  end

  defp measure_rss(fun) do
    baseline = rss_kib()
    reader = Task.async(fn -> sample_rss(baseline, 0, 0, 0) end)

    try do
      result = fun.()
      send(reader.pid, :finish)
      {peak, queue, bytes, samples} = Task.await(reader, 5_000)

      Map.merge(result, %{
        baseline_rss_kib: baseline,
        peak_rss_kib: peak,
        rss_delta_kib: peak - baseline,
        queue_high_water_events: queue,
        queue_high_water_bytes: bytes,
        rss_samples: samples
      })
    after
      if Process.alive?(reader.pid), do: Task.shutdown(reader)
    end
  end

  defp sample_rss(peak, queue, bytes, samples) do
    health = Reporter.health(@reporter)
    peak = max(rss_kib(), peak)
    queue = max(queue, Map.get(health, :pending, 0))
    bytes = max(bytes, Map.get(health, :pending_bytes, 0))

    receive do
      :finish -> {peak, queue, bytes, samples + 1}
    after
      20 -> sample_rss(peak, queue, bytes, samples + 1)
    end
  end

  defp rss_kib do
    {rss, 0} = System.cmd("ps", ["-o", "rss=", "-p", System.pid()])
    rss |> String.trim() |> String.to_integer()
  end

  defp spool_fixture(work) do
    path = Path.join(work, "spool.db")

    {:ok, spool} =
      Spool.start_link(
        path: path,
        max_bytes: @spool_max,
        source_max_bytes: 2 * 1024 * 1024,
        disk_max_bytes: @spool_disk_max
      )

    try do
      batches =
        for source_number <- 1..@spool_sources,
            batch <- Enum.chunk_every(1..@spool_events, 64),
            do: {"benchmark-#{source_number}", batch}

      {outcomes, peak} =
        Enum.reduce(batches, {%{}, spool_size(path)}, fn {id, batch}, {counts, peak} ->
          source = %{id: id, application: "benchmark", critical: true}

          entries =
            Enum.map(
              batch,
              &entry(id, &1, if(rem(&1, 4) == 0, do: "exception", else: "log_error"))
            )

          %{"level" => "local_durable", "receipts" => receipts} =
            Spool.ingest(spool, source, "batch-#{hd(batch)}", entries)

          counts =
            Enum.reduce(receipts, counts, fn item, acc ->
              key = item["reason"] || item["status"]
              Map.update(acc, key, 1, &(&1 + 1))
            end)

          {counts, max(peak, spool_size(path))}
        end)

      before = spool_counts(spool)
      {drain_us, {peak, rounds}} = timed(fn -> drain_spool(spool, path, peak, 0) end)
      after_drain = spool_counts(spool)
      {:ok, :ok} = Spool.maintain(spool)

      %{
        offered: @spool_sources * @spool_events,
        outcomes: outcomes,
        before_drain: before,
        after_drain: after_drain,
        peak_db_and_wal_bytes: peak,
        after_checkpoint_bytes: spool_size(path),
        drain_ms: Float.round(drain_us / 1_000, 2),
        drain_batches: rounds
      }
    after
      GenServer.stop(spool)
    end
  end

  defp drain_spool(spool, path, peak, rounds) when rounds < 5_000 do
    if Map.get(spool_counts(spool), "pending", %{}) |> Map.get("count", 0) == 0 do
      {peak, rounds}
    else
      {:ok, :connected} = Uploader.drain_once(spool, Acknowledgement, self(), {100, 512 * 1024})
      drain_spool(spool, path, max(peak, spool_size(path)), rounds + 1)
    end
  end

  defp spool_counts(spool) do
    {:ok, rows} = Spool.health(spool)
    Map.new(rows, &{&1["state"], Map.take(&1, ["count", "bytes"])})
  end

  defp spool_size(path) do
    Enum.reduce([path, path <> "-wal"], 0, fn file, sum ->
      case File.stat(file) do
        {:ok, stat} -> sum + stat.size
        {:error, :enoent} -> sum
      end
    end)
  end

  defp with_postgres(work, fun) do
    pgdata = Path.join(work, "pgdata")
    socket = Path.join(work, "socket")
    File.mkdir!(socket)
    run_pg("initdb", ["-D", pgdata, "-A", "trust", "--locale=C", "--no-instructions"])

    run_pg("pg_ctl", [
      "-D",
      pgdata,
      "-l",
      Path.join(work, "postgres.log"),
      "-o",
      "-h '' -k #{socket}",
      "-w",
      "-t",
      "10",
      "start"
    ])

    try do
      username =
        case System.cmd("id", ["-un"]) do
          {name, 0} -> String.trim(name)
        end

      Application.put_env(:backplane_system, Repo,
        username: username,
        database: "postgres",
        socket_dir: socket,
        pool_size: 8,
        telemetry_prefix: Enum.drop(@telemetry_event, -1),
        log: false
      )

      {:ok, repo} = Repo.start_link()

      try do
        %{rows: [[^socket]]} = Repo.query!("SHOW unix_socket_directories")
        create_schema()
        fun.()
      after
        Supervisor.stop(repo)
      end
    after
      run_pg("pg_ctl", ["-D", pgdata, "-w", "-t", "10", "-m", "fast", "stop"])
    end
  end

  defp run_pg(executable, argv) do
    binary =
      case System.get_env("DIAGNOSTICS_BENCHMARK_PG_BIN") do
        nil -> System.find_executable(executable) || raise "#{executable} is required"
        path -> Path.join(path, executable)
      end

    case System.cmd(binary, argv, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> raise "#{executable} failed (#{status}): #{out}"
    end
  end

  defp create_schema do
    Repo.query!(
      "CREATE TABLE skill_hosts (id uuid DEFAULT gen_random_uuid() PRIMARY KEY, name text NOT NULL, inserted_at timestamp NOT NULL, updated_at timestamp NOT NULL)"
    )

    "apps/backplane_system/priv/repo/migrations/*_diagnostics_*.exs"
    |> Path.wildcard()
    |> Enum.each(fn path ->
      [{module, _}] = Code.require_file(path)
      [version | _] = path |> Path.basename() |> String.split("_", parts: 2)
      :ok = Ecto.Migrator.up(Repo, String.to_integer(version), module, log: false)
    end)
  end

  defp postgres_fixture do
    %{rows: [[host]]} =
      Repo.query!(
        "INSERT INTO skill_hosts (name, inserted_at, updated_at) VALUES ('benchmark', NOW(), NOW()) RETURNING id"
      )

    host = Ecto.UUID.load!(host)
    {:ok, _} = Sources.register(host, %{id: "benchmark", application: "benchmark"})

    {:ok, _} = Application.ensure_all_started(:telemetry)
    :ok = :telemetry.attach(@telemetry_key, @telemetry_event, &__MODULE__.observe_commit/4, nil)
    Process.put(@telemetry_key, [])

    response_latencies =
      for batch <- 1..@postgres_batches do
        entries =
          for offset <- 1..@postgres_batch_size,
              do: entry("benchmark", (batch - 1) * @postgres_batch_size + offset, "exception")

        {latency, body} =
          timed(fn ->
            host |> Events.ingest("batch-#{batch}", entries) |> Formata.JSON.encode!()
          end)

        %{"level" => "remote_durable", "receipts" => receipts} = Formata.JSON.decode!(body)

        true =
          length(receipts) == @postgres_batch_size and
            Enum.all?(receipts, &(&1["status"] == "stored"))

        latency
      end

    commits = Process.delete(@telemetry_key)
    :ok = :telemetry.detach(@telemetry_key)

    {project_us, projected} = timed(fn -> drain_postgres(0) end)

    page_latencies =
      Enum.flat_map(1..@page_rounds, fn _ ->
        {ids, times} = read_pages(nil, [], [])
        true = length(ids) == @issue_count and length(Enum.uniq(ids)) == @issue_count
        times
      end)

    %{
      stored_events: @postgres_batches * @postgres_batch_size,
      projected_events: projected,
      measured_commits: length(commits),
      commit_us: percentiles(commits),
      receipt_batches: @postgres_batches,
      response_us: percentiles(response_latencies),
      projection_ms: Float.round(project_us / 1_000, 2),
      issues: @issue_count,
      queried_pages: length(page_latencies),
      query_us: percentiles(page_latencies),
      version: show("server_version"),
      fsync: show("fsync"),
      synchronous_commit: show("synchronous_commit")
    }
  end

  def observe_commit(_event, measurements, %{query: query}, _opts) do
    if String.downcase(String.trim(query)) == "commit" do
      case Process.get(@telemetry_key) do
        nil ->
          :ok

        previous ->
          micros = System.convert_time_unit(measurements.total_time, :native, :nanosecond) / 1_000
          Process.put(@telemetry_key, [micros | previous])
      end
    end
  end

  defp drain_postgres(projected) when projected <= @postgres_batches * @postgres_batch_size do
    case Projector.project_next() do
      {:ok, :processed} -> drain_postgres(projected + 1)
      {:ok, :empty} -> projected
      error -> raise "projector returned #{inspect(error)}"
    end
  end

  defp read_pages(before, ids, times) do
    {latency, rows} = timed(fn -> Issues.list(limit: @page_size, before: before) end)
    true = length(rows) <= @page_size
    next_ids = Enum.map(rows, & &1.id) ++ ids
    next_times = [latency | times]

    if length(rows) == @page_size do
      last = List.last(rows)
      read_pages({last.last_seen_at, last.id}, next_ids, next_times)
    else
      {next_ids, next_times}
    end
  end

  defp entry(source, seq, type) do
    event = %{
      "schema_version" => 1,
      "application" => "benchmark",
      "source_id" => source,
      "producer_epoch" => "pilot",
      "source_sequence" => seq,
      "event_id" => "event-#{seq}",
      "occurred_at" => "2026-11-27T00:00:00Z",
      "event_type" => type,
      "quality" => %{"redaction_policy_version" => 1},
      "result" => %{"error_class" => "software_defect", "outcome" => "failure"},
      "subject" => %{"run_id" => "synthetic-run-#{div(seq, 3)}", "attempt_id" => "attempt-#{seq}"},
      "evidence" => %{
        "exception" => %{
          "type" => "SyntheticFault#{rem(seq, @issue_count)}",
          "message" => message(),
          "stack" => [%{"module" => "BenchmarkFixture", "function" => "trigger", "arity" => 1}]
        }
      }
    }

    {:ok, _bytes, digest} = Envelope.seal(event)
    Receipt.entry(event, digest)
  end

  defp message, do: String.duplicate("x", 512)

  defp show(setting) do
    %{rows: [[value]]} = Repo.query!("SHOW #{setting}")
    value
  end

  defp wait_until(check, attempts \\ 500)
  defp wait_until(_, 0), do: raise("fixture did not drain before the deadline")

  defp wait_until(check, attempts) do
    unless check.() do
      Process.sleep(10)
      wait_until(check, attempts - 1)
    end
  end

  defp timed(fun) do
    before = System.monotonic_time(:nanosecond)
    result = fun.()
    {(System.monotonic_time(:nanosecond) - before) / 1_000, result}
  end

  defp percentiles(values) when values != [] do
    values = Enum.sort(values)

    Map.new([p50: 50, p95: 95, p99: 99], fn {label, pct} ->
      {label, Float.round(Enum.at(values, div(length(values) * pct + 99, 100) - 1), 2)}
    end)
  end

  defp gates(normal, storm, spool, postgres) do
    health = storm.unavailable_reporter
    accepted = spool.outcomes["stored"]
    confirmed = spool.after_drain["confirmed"]["count"]

    %{
      normal_latency:
        normal.enabled.latency_us.p95 - normal.disabled.latency_us.p95 <= 250 and
          normal.enabled.latency_us.p99 - normal.disabled.latency_us.p99 <= 700,
      normal_delivery: normal.enabled.outcomes == %{enqueued: normal.requests_per_mode},
      storm_latency: storm.enabled.latency_us.p99 - storm.disabled.latency_us.p99 <= 1_500,
      storm_memory:
        storm.enabled.rss_delta_kib <= @rss_allowance_kib and
          storm.enabled.queue_high_water_events <= health.max_events and
          storm.enabled.queue_high_water_bytes <= health.max_bytes and
          health.pending <= health.max_events and health.pending_bytes <= health.max_bytes,
      storm_counters:
        health.dropped > 0 and
          health.pending + health.dropped + health.rejected == storm.request_count and
          health.pending == storm.enabled.outcomes[:enqueued] and
          health.dropped == storm.enabled.outcomes[:queue_full],
      spool_allocation: spool.peak_db_and_wal_bytes <= @spool_disk_max,
      spool_accounting:
        accepted + Map.get(spool.outcomes, "quota_exceeded", 0) +
          Map.get(spool.outcomes, "disk_capacity", 0) == spool.offered and
          accepted < spool.offered and accepted == confirmed and
          spool.before_drain["pending"]["bytes"] <= @spool_max and
          is_nil(spool.after_drain["pending"]),
      spool_drain: spool.drain_ms <= 30_000,
      postgres_commit:
        postgres.measured_commits == postgres.stored_events and postgres.commit_us.p95 <= 20_000,
      postgres_response:
        postgres.response_us.p95 <= 150_000 and
          postgres.projected_events == postgres.stored_events,
      postgres_paging: postgres.query_us.p99 <= 25_000
    }
  end

  defp unique_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end

case Backplane.Diagnostics.Benchmark.main() do
  :ok -> :ok
  :failed -> System.halt(1)
end
