ExUnit.start()
System.put_env("MEMORY_LOCAL_POLICY_LIBRARY", "1")
Code.require_file("../memory_local_policy.exs", __DIR__)

defmodule MemoryLocalPolicyTest do
  use ExUnit.Case, async: false
  alias MemoryLocalPolicy, as: Policy

  defmodule UnavailableTimeZoneDatabase do
    def time_zone_period_from_utc_iso_days(_, _), do: raise("timezone service unavailable")
  end

  test "loading guard helpers starts no repository, Settings, or worker application" do
    refute Process.whereis(Backplane.Repo)
    assert :ets.whereis(:backplane_settings) == :undefined
    started = Enum.map(Application.started_applications(), &elem(&1, 0))
    refute Enum.any?([:backplane_system, :backplane_memory, :backplane, :styx], &(&1 in started))
  end

  test "historical retention cutoff precedes every existing row and never uses a future today" do
    actual = ~D[2026-10-20]
    assert {~D[2024-10-20], actual} == Policy.retention_clock!(actual, 730, nil)

    assert {~D[2020-01-01], ~D[2021-12-31]} ==
             Policy.retention_clock!(actual, 730, ~D[2020-01-02])

    assert_raise MemoryLocalPolicy.Failure, fn ->
      Policy.retention_clock!(actual, 730, ~D[0001-01-01])
    end
  end

  test "UTC policy offsets need no configured timezone service and preserve boundary precision" do
    previous = Calendar.get_time_zone_database()
    Calendar.put_time_zone_database(UnavailableTimeZoneDatabase)
    on_exit(fn -> Calendar.put_time_zone_database(previous) end)

    now = ~U[2026-10-20 23:59:59.123456Z]
    assert Policy.utc_add(now, 86_400) == ~U[2026-10-21 23:59:59.123456Z]
    assert Policy.utc_add(now, -2 * 86_400) == ~U[2026-10-18 23:59:59.123456Z]
    assert Policy.utc_add(now, 240) == ~U[2026-10-21 00:03:59.123456Z]
  end

  test "controller initializes the configured timezone before default Styx time arithmetic" do
    previous = Calendar.get_time_zone_database()
    Calendar.put_time_zone_database(Tzdata.TimeZoneDatabase)

    on_exit(fn ->
      Calendar.put_time_zone_database(previous)
      Application.stop(:tzdata)
    end)

    refute Process.whereis(Tzdata.EtsHolder)
    assert_raise ArgumentError, fn -> DateTime.add(DateTime.utc_now(), 30_000, :millisecond) end
    assert :ok == Policy.initialize_clock!()
    now = DateTime.utc_now()
    assert DateTime.diff(DateTime.add(now, 30_000, :millisecond), now) == 30
    assert {:ok, %DateTime{time_zone: "Etc/UTC"}} = DateTime.now("Etc/UTC")
    refute Process.whereis(Backplane.Repo)
    refute Process.whereis(Backplane.Supervisor)
  end

  test "resume requires the exact stopped, job-free, same-day failed run and targets" do
    {prior, opts, partition, current} = resume_fixture()
    resume = Policy.resume!(prior, opts, partition, current)
    assert resume.ids == prior["target_ids"]
    assert resume.now == ~U[2026-10-20 10:00:00Z]
    assert resume.cutoff == ~D[2024-10-20]

    invalid = [
      Map.put(prior, "status", "passed"),
      Map.put(prior, "failure", "policy_jobs_timeout"),
      Map.put(prior, "scheduler_stopped", false),
      Map.put(prior, "last_jobs", [%{"id" => 1}]),
      Map.put(prior, "cron_roots", [%{"id" => 1}]),
      Map.put(prior, "marker", "l16-other"),
      Map.put(prior, "partition", %{}),
      Map.put(prior, "target_ids", [hd(prior["target_ids"]), hd(prior["target_ids"])]),
      Map.put(prior, "api_receipts", []),
      put_in(prior, ["clocks", "now"], "2026-10-19T10:00:00Z"),
      put_in(prior, ["clocks", "retention_today"], "2026-10-21")
    ]

    for bad <- invalid do
      assert_raise MemoryLocalPolicy.Failure, fn ->
        Policy.resume!(bad, opts, partition, current)
      end
    end
  end

  test "resume refuses changed targets, controls, activity, nonfixture data or service identity" do
    {prior, _opts, _partition, _current} = resume_fixture()

    keys =
      ~w(services_before database policy targets_before protected_controls_setup activity_setup nonfixture_before)

    snapshot = Map.take(prior, keys)
    assert :ok == Policy.resume_unchanged!(prior, snapshot)

    for key <- keys do
      assert_raise MemoryLocalPolicy.Failure, fn ->
        Policy.resume_unchanged!(prior, Map.put(snapshot, key, "changed"))
      end
    end
  end

  defp resume_fixture do
    ids = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"]
    partition = Map.new(~w(memory_space_id host_id client_id scope namespace), &{&1, &1})
    opts = [marker: "l16-test", run: "test"]

    prior = %{
      "scenario" => "L16",
      "status" => "incomplete",
      "failure" => "cron_timer_timeout",
      "stage" => "real_cron_timer",
      "scheduler_stopped" => true,
      "last_jobs" => [],
      "run_id" => "test",
      "marker" => "l16-test",
      "partition" => partition,
      "target_ids" => ids,
      "api_receipts" =>
        Enum.zip_with(ids, ["recent", "archive"], fn id, kind ->
          %{"method" => "lesson_save", "status" => 200, "memory_id" => id, "kind" => kind}
        end),
      "clocks" => %{
        "now" => "2026-10-20T10:00:00Z",
        "cutoff" => "2024-10-20",
        "retention_today" => "2026-10-20"
      },
      "services_before" => [%{"pid" => 10}],
      "database" => %{"database" => "test"},
      "policy" => %{"retention_days" => 730},
      "targets_before" => Enum.map(ids, &%{"memory_id" => &1}),
      "protected_controls_setup" => [],
      "activity_setup" => %{"rows" => "unchanged"},
      "nonfixture_before" => %{"digest" => "unchanged"}
    }

    {prior, opts, partition, ~U[2026-10-20 10:05:00Z]}
  end

  test "eligible identities must be a subset of explicitly declared synthetic controls" do
    assert :ok == Policy.eligible!(~w(target control), ~w(target control))

    assert_raise MemoryLocalPolicy.Failure, fn ->
      Policy.eligible!(~w(target developer), ~w(target control))
    end
  end

  test "unexpected failure diagnostics retain locations and never arguments or state" do
    trace = [
      {__MODULE__, :failed, [%{token: "private-token", state: "private-state"}],
       [file: ~c"/private/workspace/policy.exs", line: 42, state: "private-state"]},
      {Enum, :map, 2, []}
    ]

    assert Policy.stack_locations(trace) == [
             %{
               module: Atom.to_string(__MODULE__),
               function: "failed",
               arity: 1,
               file: "policy.exs",
               line: 42
             },
             %{module: "Elixir.Enum", function: "map", arity: 2, file: "unknown", line: nil}
           ]

    assert length(Policy.stack_locations(List.duplicate(hd(trace), 20))) == 12
  end

  test "fixture guard binds run, host name, and all five partition fields" do
    partition = %{
      "memory_space_id" => "ae7f6fd1-ebd1-4233-a390-a0ec81bd6816",
      "host_id" => "a26d5ff6-1ff2-42c8-8f38-c8e82d795b27",
      "client_id" => "host:a26d5ff6-1ff2-42c8-8f38-c8e82d795b27",
      "scope" => "memory_local_oct20_primary",
      "namespace" => "private"
    }

    fixture = %{
      "run_id" => "oct20",
      "hosts" => [
        %{
          "name" => "memory-local-oct20-primary",
          "host_id" => partition["host_id"],
          "partition" => partition
        }
      ]
    }

    assert Policy.fixture!(fixture, "oct20") == partition

    for bad <- [
          put_in(fixture, ["run_id"], "other"),
          put_in(fixture, ["hosts", Access.at(0), "partition", "host_id"], "other"),
          put_in(fixture, ["hosts", Access.at(0), "partition", "client_id"], "other"),
          put_in(fixture, ["hosts", Access.at(0), "name"], "developer")
        ] do
      assert_raise MemoryLocalPolicy.Failure, fn -> Policy.fixture!(bad, "oct20") end
    end
  end

  test "root validation requires real Cron metadata" do
    roots =
      for worker <- ~w(sweep retention),
          do: %{
            "id" => worker,
            "worker" => worker,
            "state" => "completed",
            "meta" => %{
              "cron" => true,
              "cron_expr" => "@reboot",
              "l16_run" => "run",
              "cron_tz" => "Etc/UTC",
              "cron_name" => "123"
            }
          }

    assert Policy.roots!(roots, "run", ~w(sweep retention)) == roots

    assert_raise MemoryLocalPolicy.Failure, fn ->
      Policy.roots!(
        [put_in(hd(roots), ["meta", "cron"], false), List.last(roots)],
        "run",
        ~w(sweep retention)
      )
    end
  end

  test "only exact-partition synthetic eligible lessons can be protected" do
    p = Map.new(~w(memory_space_id host_id client_id scope namespace), &{&1, &1})

    row =
      Map.merge(p, %{
        "status" => "active",
        "lifecycle_state" => "active",
        "project" => "/synthetic/backplane-memory/oct20",
        "session_id" => nil
      })

    for status <- ~w(candidate active disputed) do
      control = Map.merge(row, %{"status" => status, "lifecycle_state" => status})
      assert :ok == Policy.control!(control, p, "oct20")

      session_control =
        Map.merge(control, %{
          "project" => nil,
          "session_id" => "memory-local-oct20-session-2"
        })

      assert :ok == Policy.control!(session_control, p, "oct20")
    end

    foreign = for field <- Map.keys(p), do: Map.put(row, field, "foreign")

    ineligible =
      for {field, statuses} <- [
            {"status", ~w(archived superseded unknown)},
            {"lifecycle_state", ~w(archived superseded tombstoned unknown)}
          ],
          status <- statuses,
          do: Map.put(row, field, status)

    for bad <- foreign ++ ineligible ++ [Map.put(row, "project", "/developer")] do
      assert_raise MemoryLocalPolicy.Failure, fn -> Policy.control!(bad, p, "oct20") end
    end
  end

  test "validated scheduler has no consumers and schedules the real sweep and retention workers" do
    opts = Policy.scheduler_opts("l16-guard", ~U[2026-10-20 10:00:00Z], ~D[2020-01-01])
    assert opts[:queues] == []
    assert opts[:stager] == false
    assert opts[:testing] == :disabled
    assert opts[:name] != Styx
    assert :ok == Styx.Config.validate(opts)
    [{Styx.Cron, cron}] = opts[:plugins]

    assert [
             {"@reboot", Backplane.Memory.Workers.LessonDecaySweepWorker, _},
             {"@reboot", Backplane.Memory.Workers.ActivityRetentionWorker, _}
           ] = cron[:crontab]
  end
end
