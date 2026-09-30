defmodule Backplane.AuthBenchmark.Metrics do
  use GenServer
  def start_link, do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def reset, do: GenServer.call(__MODULE__, :reset)
  def read, do: GenServer.call(__MODULE__, :read)
  def event(name), do: GenServer.cast(__MODULE__, {:event, name})
  def init(state), do: {:ok, state}
  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}
  def handle_call(:read, _from, state), do: {:reply, state, state}
  def handle_cast({:event, name}, state), do: {:noreply, Map.update(state, name, 1, &(&1 + 1))}

  def handle_info({:trace, _pid, :call, {Bcrypt, :verify_pass, _arguments}}, state),
    do: {:noreply, Map.update(state, :bcrypt_calls, 1, &(&1 + 1))}

  def handle_info({:trace, _pid, :call, {Bcrypt, :no_user_verify, _arguments}}, state),
    do: {:noreply, Map.update(state, :dummy_bcrypt_calls, 1, &(&1 + 1))}

  def handle_info({:trace, _pid, :call, {Task, :start, _arguments}}, state),
    do: {:noreply, Map.update(state, :request_tasks, 1, &(&1 + 1))}
end

defmodule Backplane.AuthBenchmark do
  alias Backplane.AuthBenchmark.Metrics
  alias Backplane.Clients.{Activity, AuthCache, Client}
  alias Backplane.Repo

  def run do
    if Application.get_env(:backplane, :env) == :test,
      do: raise("Use MIX_ENV=dev; this benchmark refuses sandbox authentication")

    database = System.get_env("BACKPLANE_AUTH_BENCH_DATABASE", "backplane_test")

    unless String.ends_with?(database, "_test"),
      do: raise("Use a dedicated database ending in _test")

    repo_config =
      Application.fetch_env!(:backplane_system, Repo)
      |> Keyword.put(:database, database)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)

    Application.put_env(:backplane_system, Repo, repo_config)
    Application.put_env(:backplane_system, :start_audit_writer, false)
    Logger.configure(level: :warning)
    {:ok, _apps} = Application.ensure_all_started(:backplane_system)

    if Repo.aggregate(Client, :count) != 0,
      do:
        raise(
          "The benchmark needs an empty clients table; no existing credentials will be modified"
        )

    compile_baseline()
    {:ok, collector} = Metrics.start_link()
    attach_metrics(collector)
    valid_hash = Bcrypt.hash_pwd_salt("benchmark-valid")
    invalid_hash = Bcrypt.hash_pwd_salt("benchmark-decoy")

    report = %{
      baseline: baseline(),
      environment: Mix.env(),
      database: database,
      bcrypt_cost: String.slice(valid_hash, 4, 2),
      bounds: Map.new(AuthCache.options())
    }

    IO.puts(Jason.encode!(report))

    for count <- [1, 8, 32] do
      clients = seed(count, valid_hash, invalid_hash)

      try do
        :ok = Backplane.Clients.BenchmarkBaseline.init_cache()
        :ok = AuthCache.refresh()

        for mode <- [:before, :after] do
          measure(mode, count, :cold_valid, ["benchmark-valid"])
          measure(mode, count, :warm_valid, List.duplicate("benchmark-valid", 1_000), 1_000)
          measure(mode, count, :repeated_invalid, List.duplicate("benchmark-invalid", 3))
          measure(mode, count, :unique_invalid, Enum.map(1..3, &"benchmark-invalid-#{&1}"))
        end

        if count == 8 do
          concurrency(count)
          saturation(count, :same)
          saturation(count, :different)
        end
      after
        Enum.each(clients, &Repo.delete!/1)
        Backplane.Clients.BenchmarkBaseline.refresh_cache()
        AuthCache.refresh()
      end
    end
  end

  defp baseline,
    do:
      System.get_env("BACKPLANE_AUTH_BENCH_BASELINE", "301ffd41bfadfc806af7d71dc773359ce57c0d02")

  defp compile_baseline do
    {clients, 0} =
      System.cmd("git", ["show", "#{baseline()}:apps/backplane_system/lib/backplane/clients.ex"])

    clients =
      clients
      |> String.replace(
        "defmodule Backplane.Clients do",
        "defmodule Backplane.Clients.BenchmarkBaseline do"
      )
      |> String.replace(":backplane_clients_cache", ":backplane_benchmark_baseline_clients")
      |> String.replace(
        ":backplane_client_token_verifications",
        ":backplane_benchmark_baseline_verifications"
      )
      |> String.replace(":backplane_clients_exist", ":backplane_benchmark_baseline_exists")
      |> String.replace(
        "defp cached_active_clients do",
        "defp cached_active_clients do\n :telemetry.execute([:backplane, :client_auth, :enumeration], %{count: 1}, %{})"
      )
      |> String.replace(
        "defp verify_and_cache(token, key, generation, clients) do",
        "defp verify_and_cache(token, key, generation, clients) do\n :telemetry.execute([:backplane, :client_auth, :scan], %{count: 1}, %{})"
      )

    Code.compile_string(clients, "baseline_clients.ex")

    {tokens, 0} =
      System.cmd("git", ["show", "#{baseline()}:apps/backplane_auth/lib/backplane/auth/tokens.ex"])

    Code.compile_string(
      String.replace(
        tokens,
        "defmodule Backplane.Auth.Tokens do",
        "defmodule Backplane.Auth.BenchmarkBaselineTokens do"
      ),
      "baseline_tokens.ex"
    )

    {plug, 0} =
      System.cmd("git", [
        "show",
        "#{baseline()}:apps/backplane_auth/lib/backplane/auth/resource_auth_plug.ex"
      ])

    plug =
      plug
      |> String.replace(
        "defmodule Backplane.Auth.ResourceAuthPlug do",
        "defmodule Backplane.Auth.BenchmarkBaselinePlug do"
      )
      |> String.replace(
        "alias Backplane.Clients",
        "alias Backplane.Clients.BenchmarkBaseline, as: Clients"
      )
      |> String.replace(
        "alias Backplane.Auth.{BearerChallenge, OAuth, Resources, Tokens}",
        "alias Backplane.Auth.{BearerChallenge, OAuth, Resources}\n alias Backplane.Auth.BenchmarkBaselineTokens, as: Tokens"
      )

    Code.compile_string(plug, "baseline_resource_auth_plug.ex")
  end

  defp attach_metrics(collector) do
    Code.ensure_loaded!(Bcrypt)
    Code.ensure_loaded!(Task)
    :erlang.trace_pattern({Bcrypt, :verify_pass, 2}, true, [])
    :erlang.trace_pattern({Bcrypt, :no_user_verify, 0}, true, [])
    :erlang.trace_pattern({Task, :start, 1}, true, [])
    :erlang.trace(:all, true, [:call, :set_on_spawn, {:tracer, collector}])

    :telemetry.attach(
      "auth-benchmark-sql",
      [:backplane, :repo, :query],
      fn _event, _time, metadata, _config ->
        Metrics.event(:sql_queries)
        query = metadata.query
        if metadata.source == "auth_signing_keys", do: Metrics.event(:signing_key_queries)

        if metadata.source == "clients" and String.starts_with?(query, "SELECT"),
          do: Metrics.event(:client_selects)

        if metadata.source == "clients" and String.starts_with?(query, "UPDATE"),
          do: Metrics.event(:activity_writes)
      end,
      nil
    )

    for event <- [:scan, :enumeration] do
      :telemetry.attach(
        "auth-benchmark-#{event}",
        [:backplane, :client_auth, event],
        fn _event, _time, _metadata, _config -> Metrics.event(event) end,
        nil
      )
    end
  end

  defp seed(count, valid_hash, invalid_hash) do
    Enum.map(1..count, fn position ->
      %Client{}
      |> Client.changeset(%{
        name: "auth-benchmark-#{count}-#{position}",
        token_hash: if(position == 1, do: valid_hash, else: invalid_hash),
        scopes: ["docs::*"]
      })
      |> Repo.insert!()
    end)
  end

  defp verify(mode, token) do
    plug =
      if mode == :before,
        do: Backplane.Auth.BenchmarkBaselinePlug,
        else: Backplane.Auth.ResourceAuthPlug

    conn = Plug.Test.conn(:post, "/mcp") |> Plug.Conn.put_req_header("x-api-key", token)
    conn = plug.call(conn, plug.init(resource: :mcp))

    case conn.status do
      nil -> {:ok, conn.assigns.client}
      401 -> :error
      503 -> {:error, :unavailable}
    end
  end

  defp measure(mode, clients, workload, tokens, activity_count \\ 0) do
    Metrics.reset()
    timed = Enum.map(tokens, fn token -> :timer.tc(fn -> verify(mode, token) end) end)
    successes = Enum.count(timed, fn {_duration, result} -> match?({:ok, _client}, result) end)
    if mode == :before and successes > 0, do: await_writes(successes)
    if mode == :after and activity_count > 0, do: Activity.flush()
    trace_barrier()
    durations = Enum.map(timed, &elem(&1, 0)) |> Enum.sort()

    outcomes =
      Enum.frequencies_by(timed, fn {_duration, result} ->
        case result do
          {:ok, _client} -> :ok
          :error -> :invalid
          {:error, reason} -> reason
        end
      end)

    IO.puts(
      Jason.encode!(%{
        mode: mode,
        clients: clients,
        workload: workload,
        requests: length(tokens),
        p50_us: percentile(durations, 0.50),
        p95_us: percentile(durations, 0.95),
        metrics: Metrics.read(),
        outcomes: outcomes,
        cache: AuthCache.stats()
      })
    )
  end

  defp concurrency(clients) do
    for mode <- [:before, :after] do
      Metrics.reset()
      tasks = for _request <- 1..8, do: Task.async(fn -> verify(mode, "concurrent-invalid") end)
      peak = poll(tasks, mode, 0)
      results = Enum.map(tasks, &Task.await(&1, 60_000))
      trace_barrier()

      IO.puts(
        Jason.encode!(%{
          mode: mode,
          clients: clients,
          workload: :concurrent_same_invalid,
          requests: 8,
          peak_workers: peak,
          metrics: Metrics.read(),
          service_unavailable: Enum.count(results, &(&1 == {:error, :unavailable})),
          cache: AuthCache.stats()
        })
      )
    end
  end

  defp saturation(clients, kind) do
    Metrics.reset()

    tasks =
      for request <- 1..96 do
        token = if kind == :same, do: "flood-same", else: "flood-different-#{request}"
        Task.async(fn -> verify(:after, token) end)
      end

    warm = verify(:after, "benchmark-valid")
    peaks = poll_bounds(tasks, %{workers: 0, waiters: 0, ingress: 0})
    results = Enum.map(tasks, &Task.await(&1, 60_000))
    trace_barrier()

    IO.puts(
      Jason.encode!(%{
        mode: :after,
        clients: clients,
        workload: "saturation_#{kind}_invalid",
        requests: 96,
        warm_authenticated: match?({:ok, _}, warm),
        peaks: peaks,
        service_unavailable: Enum.count(results, &(&1 == {:error, :unavailable})),
        metrics: Metrics.read(),
        cache: AuthCache.stats()
      })
    )
  end

  defp poll_bounds(tasks, peaks) do
    stats = AuthCache.stats()
    peaks = Map.new(peaks, fn {key, peak} -> {key, max(peak, stats[key])} end)

    if Enum.any?(tasks, &Process.alive?(&1.pid)) do
      Process.sleep(5)
      poll_bounds(tasks, peaks)
    else
      peaks
    end
  end

  defp poll(tasks, mode, peak) do
    active = Enum.count(tasks, &Process.alive?(&1.pid))
    workers = if mode == :after, do: AuthCache.stats().workers, else: active
    peak = max(peak, workers)

    if active == 0 do
      peak
    else
      Process.sleep(5)
      poll(tasks, mode, peak)
    end
  end

  defp await_writes(count, attempts \\ 6_000) do
    if Map.get(Metrics.read(), :activity_writes, 0) < count do
      if attempts == 0, do: raise("activity writer did not drain")
      Process.sleep(5)
      await_writes(count, attempts - 1)
    end
  end

  defp trace_barrier do
    reference = :erlang.trace_delivered(:all)
    receive do: ({:trace_delivered, :all, ^reference} -> :ok)
    Metrics.read()
  end

  defp percentile(values, fraction),
    do: Enum.at(values, max(ceil(length(values) * fraction) - 1, 0))
end

Backplane.AuthBenchmark.run()
