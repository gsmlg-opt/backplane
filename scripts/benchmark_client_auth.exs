defmodule Backplane.AuthBenchmark do
  @moduledoc false
  alias Backplane.Clients.{AuthCache, Client}
  alias Backplane.Repo

  @requests 1_000
  @trace_functions [
    {Bcrypt, :verify_pass, 2},
    {Bcrypt, :no_user_verify, 0},
    {Task.Supervisor, :async_nolink, 2},
    {Task.Supervisor, :async_nolink, 3},
    {Task, :start, 1},
    {DBConnection, :prepare_execute, 4},
    {DBConnection, :execute, 4},
    {:ets, :lookup, 2},
    {:ets, :tab2list, 1},
    {:ets, :select, 2},
    {:ets, :match_object, 2}
  ]

  def run do
    database = System.fetch_env!("BACKPLANE_AUTH_BENCH_DATABASE")

    unless String.ends_with?(database, "_test") and database != "backplane_test",
      do: raise("Use a dedicated empty benchmark database ending in _test")

    config = Application.fetch_env!(:backplane_system, Repo)
    config = Keyword.delete(config, :url)
    config = Keyword.merge(config, database: database, pool: DBConnection.ConnectionPool)
    Application.put_env(:backplane_system, Repo, config)
    Application.put_env(:backplane_system, :start_audit_writer, false)
    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:backplane_system)

    unless Repo.aggregate(Client, :count) == 0,
      do: raise("Benchmark requires an empty clients table; existing rows will not be modified")

    for {module, _, _} <- @trace_functions, do: Code.ensure_loaded!(module)
    for mfa <- @trace_functions, do: :erlang.trace_pattern(mfa, true, [])

    try do
      calibrate_sql_counter()
      for count <- [1, 32, 1_000, 10_000], do: benchmark_size(count)
    after
      for mfa <- @trace_functions, do: :erlang.trace_pattern(mfa, false, [])
    end
  end

  # Client query telemetry is intentionally suppressed to prevent params/results
  # from exposing digests. Count adapter activity below that boundary instead,
  # and prove the counter sees a query with telemetry and SQL logging disabled.
  defp calibrate_sql_counter do
    parent = self()
    collector = spawn(fn -> collect(%{}, parent) end)
    :erlang.trace(self(), true, [:call, {:tracer, collector}])
    Ecto.Adapters.SQL.query!(Repo, "SELECT 1", [], log: false, telemetry_event: nil)
    barrier = :erlang.trace_delivered(self())
    receive do: ({:trace_delivered, _pid, ^barrier} -> :ok)
    :erlang.trace(self(), false, [:call])
    send(collector, :read)
    metrics = receive do: ({:metrics, ^collector, metrics} -> metrics)
    if Map.get(metrics, :sql, 0) < 1, do: raise("SQL call-trace calibration failed")

    IO.puts(
      Jason.encode!(%{
        workload: :sql_trace_calibration,
        suppressed_query_detected: true,
        metrics: metrics
      })
    )
  end

  defp benchmark_size(count) do
    now = DateTime.utc_now()
    credentials = for position <- 1..count, do: {position, token()}
    valid = credentials |> hd() |> elem(1)

    rows =
      Enum.map(credentials, fn {position, secret} ->
        %{
          id: Ecto.UUID.generate(),
          name: "auth-benchmark-#{position}",
          token_digest: :crypto.hash(:sha256, secret),
          active: true,
          scopes: ["docs::*"],
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      end)

    ids = Enum.map(rows, & &1.id)
    # Only the rows inserted by this run are ever deleted.
    try do
      Enum.each(Enum.chunk_every(rows, 1_000), fn batch ->
        {inserted, _} = Repo.insert_all(Client, batch)
        true = inserted == length(batch)
      end)

      {refresh_us, :ok} = :timer.tc(fn -> AuthCache.refresh() end)

      IO.puts(
        Jason.encode!(%{
          clients: count,
          workload: :background_refresh,
          wall_us: refresh_us,
          cache: AuthCache.stats()
        })
      )

      handle = %{AuthCache.default_handle() | activity: false}
      measure(count, :first_valid, [valid], handle)
      measure(count, :repeat_valid, List.duplicate(valid, @requests), handle)
      measure(count, :unique_invalid, for(_ <- 1..@requests, do: token()), handle)
      measure(count, :malformed, List.duplicate("retired-or-malformed-token", @requests), handle)
      :ok = AuthCache.refresh()
      measure(count, :after_refresh, [valid], handle)

      # Restart uses the real supervised owner and requires a fresh publication.
      :ok = Supervisor.terminate_child(Backplane.Clients.AuthSupervisor, AuthCache)
      {:ok, _pid} = Supervisor.restart_child(Backplane.Clients.AuthSupervisor, AuthCache)
      :ok = AuthCache.refresh()
      measure(count, :after_restart, [valid], %{AuthCache.default_handle() | activity: false})
    after
      import Ecto.Query
      Repo.delete_all(from(client in Client, where: client.id in ^ids))
      AuthCache.refresh()
    end
  end

  defp measure(count, workload, tokens, handle) do
    parent = self()
    collector = spawn(fn -> collect(%{}, parent) end)
    :erlang.trace(self(), true, [:call, :procs, {:tracer, collector}])
    {cpu_before, _} = :erlang.statistics(:runtime)
    {:reductions, reductions_before} = Process.info(self(), :reductions)
    {:memory, memory_before} = Process.info(self(), :memory)

    timed =
      Enum.map(tokens, fn secret -> :timer.tc(fn -> AuthCache.verify(secret, handle) end) end)

    {:memory, memory_after} = Process.info(self(), :memory)
    {:reductions, reductions_after} = Process.info(self(), :reductions)
    {cpu_after, _} = :erlang.statistics(:runtime)
    barrier = :erlang.trace_delivered(self())
    receive do: ({:trace_delivered, _pid, ^barrier} -> :ok)
    :erlang.trace(self(), false, [:call, :procs])
    send(collector, :read)
    metrics = receive do: ({:metrics, ^collector, metrics} -> metrics)

    durations = Enum.map(timed, &elem(&1, 0)) |> Enum.sort()

    outcomes =
      Enum.frequencies_by(timed, fn
        {_us, {:ok, _}} -> :ok
        {_us, :error} -> :invalid
        {_us, {:error, reason}} -> reason
      end)

    report = %{
      clients: count,
      workload: workload,
      requests: length(tokens),
      p50_us: percentile(durations, 0.50),
      p95_us: percentile(durations, 0.95),
      vm_cpu_ms: cpu_after - cpu_before,
      reductions: reductions_after - reductions_before,
      process_memory_delta_bytes: memory_after - memory_before,
      outcomes: outcomes,
      metrics:
        Map.merge(
          %{
            bcrypt: 0,
            sql: 0,
            tasks: 0,
            spawns: 0,
            scans: 0,
            digest_lookups: 0,
            client_lookups: 0,
            control_lookups: 0
          },
          metrics
        )
    }

    IO.puts(Jason.encode!(report))

    if Enum.any?([:bcrypt, :sql, :tasks, :spawns, :scans], &(report.metrics[&1] != 0)),
      do: raise("Unexpected client authentication work detected")
  end

  defp collect(metrics, parent) do
    receive do
      :read ->
        send(parent, {:metrics, self(), metrics})

      event ->
        key =
          case event do
            {:trace, _, :call, {DBConnection, function, _}}
            when function in [:prepare_execute, :execute] ->
              :sql

            {:trace, _, :spawn, _, _} ->
              :spawns

            {:trace, _, :call, {Bcrypt, _, _}} ->
              :bcrypt

            {:trace, _, :call, {Task.Supervisor, _, _}} ->
              :tasks

            {:trace, _, :call, {Task, _, _}} ->
              :tasks

            {:trace, _, :call, {:ets, :lookup, [:backplane_client_auth_digests, _]}} ->
              :digest_lookups

            {:trace, _, :call, {:ets, :lookup, [:backplane_clients_cache, _]}} ->
              :client_lookups

            {:trace, _, :call, {:ets, :lookup, [_, :snapshot]}} ->
              :control_lookups

            {:trace, _, :call, {:ets, fun, _}} when fun in [:tab2list, :select, :match_object] ->
              :scans

            _ ->
              nil
          end

        metrics = if key, do: Map.update(metrics, key, 1, &(&1 + 1)), else: metrics
        collect(metrics, parent)
    end
  end

  defp token, do: "bp2_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp percentile(values, fraction),
    do: Enum.at(values, max(ceil(length(values) * fraction) - 1, 0))
end

Backplane.AuthBenchmark.run()
