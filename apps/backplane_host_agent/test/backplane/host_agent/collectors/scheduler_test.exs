defmodule Backplane.HostAgent.Collectors.SchedulerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Backplane.HostAgent.Collectors.{Command, Scheduler}
  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool

  @moduletag :tmp_dir

  defmodule FakeCollector do
    @behaviour Backplane.HostAgent.Collectors.Collector
    def config_key, do: :docker

    def collect(_config, _env) do
      [{:items, items}] = :ets.lookup(:fake_collector, :items)
      [%{collector: "docker", unit: "local", complete: true, items: items}]
    end
  end

  defmodule RaisingCollector do
    @behaviour Backplane.HostAgent.Collectors.Collector
    def config_key, do: :git
    def collect(_config, _env), do: raise("boom")
  end

  defmodule MixedCollector do
    @behaviour Backplane.HostAgent.Collectors.Collector
    def config_key, do: :services

    def collect(_config, _env) do
      [
        %{collector: "systemd", unit: "local", complete: true, items: [%{name: <<"bad", 0xE9>>}]},
        %{collector: "systemd", unit: nil, complete: true, items: []},
        %{collector: "launchd", unit: "local", complete: true},
        %{collector: "launchd", unit: "local", complete: true, items: [%{label: "ok.job"}]}
      ]
    end
  end

  defmodule UnscannedCollector do
    @behaviour Backplane.HostAgent.Collectors.Collector
    def config_key, do: :git

    def collect(_config, _env) do
      [{:unscanned, unscanned}] = :ets.lookup(:fake_collector, :unscanned)

      [
        %{
          collector: "git",
          unit: "/work",
          complete: true,
          unscanned: unscanned,
          items: [%{"path" => "/work/a", "repository_id" => nil, "branch" => nil, "head" => nil}]
        }
      ]
    end
  end

  defmodule FailingSpool do
    def append(_spool, _envelope), do: {:error, :disk_full}
  end

  setup %{tmp_dir: dir} do
    :ets.new(:fake_collector, [:named_table, :public])
    set_items([%{name: "web", image: "nginx", state: "running", ports: ["80"]}])
    suffix = System.unique_integer([:positive])

    spool =
      start_supervised!({Spool, database: Path.join(dir, "spool.db"), name: :"spool_#{suffix}"})

    %{spool: spool, state_path: Path.join(dir, "collector_state.json"), suffix: suffix}
  end

  defp set_items(items), do: :ets.insert(:fake_collector, {:items, items})

  defp start_scheduler(ctx, extra \\ []) do
    opts =
      Keyword.merge(
        [
          name: :"scheduler_#{System.unique_integer([:positive])}",
          host_id: "host-1",
          spool: ctx.spool,
          state_path: ctx.state_path,
          collectors: [FakeCollector],
          auto_run: false
        ],
        extra
      )

    {:ok, pid} = Scheduler.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp batch(ctx), do: Spool.next_batch(ctx.spool, 100, 1_000_000)

  test "first run emits one contract-shaped event, unchanged emits none, change emits one", ctx do
    scheduler = start_scheduler(ctx)

    assert %{emitted: 1, unchanged: 0} = Scheduler.run_once(scheduler)
    assert [event] = batch(ctx)
    assert event["event_type"] == "host.snapshot.collected"
    assert event["integration"] == "host_collector"
    assert event["client_id"] == "host_collector"
    assert event["agent_id"] == "host-collector"
    assert event["host_id"] == "host-1"
    refute Map.has_key?(event, "session_id")
    assert {:ok, _, 0} = DateTime.from_iso8601(event["occurred_at"])

    assert event["idempotency_key"] =~
             ~r/^host_collector:docker:local:[0-9a-f]{64}:#{Regex.escape(event["occurred_at"])}$/

    assert %{"collector" => "docker", "unit" => "local", "complete" => true, "items" => [_]} =
             event["payload"]

    assert %{emitted: 0, unchanged: 1} = Scheduler.run_once(scheduler)

    set_items([%{name: "web", image: "nginx:2", state: "running", ports: ["80"]}])
    assert %{emitted: 1} = Scheduler.run_once(scheduler)
    assert length(batch(ctx)) == 2
  end

  test "item order does not change the fingerprint", ctx do
    a = %{name: "a", image: "i", state: "running", ports: []}
    b = %{name: "b", image: "i", state: "running", ports: []}
    set_items([a, b])
    scheduler = start_scheduler(ctx)
    assert %{emitted: 1} = Scheduler.run_once(scheduler)
    set_items([b, a])
    assert %{emitted: 0, unchanged: 1} = Scheduler.run_once(scheduler)
  end

  test "state persists across scheduler restart", ctx do
    first = start_scheduler(ctx)
    assert %{emitted: 1} = Scheduler.run_once(first)
    assert File.exists?(ctx.state_path)
    refute File.exists?(ctx.state_path <> ".tmp")
    GenServer.stop(first)

    second = start_scheduler(ctx)
    assert %{emitted: 0, unchanged: 1} = Scheduler.run_once(second)
  end

  test "append failure keeps state so the next run emits", ctx do
    failing = start_scheduler(ctx, spool_module: FailingSpool)

    log = capture_log(fn -> assert %{emitted: 0} = Scheduler.run_once(failing) end)
    assert log =~ "not spooled"
    refute File.exists?(ctx.state_path)
    GenServer.stop(failing)

    working = start_scheduler(ctx)
    assert %{emitted: 1} = Scheduler.run_once(working)
  end

  test "a raising or undefined collector does not stop others", ctx do
    scheduler =
      start_scheduler(ctx,
        collectors: [RaisingCollector, Backplane.HostAgent.Collectors.DoesNotExist, FakeCollector]
      )

    log =
      capture_log(fn -> assert %{emitted: 1} = Scheduler.run_once(scheduler) end)

    assert log =~ "RaisingCollector"
    assert log =~ "DoesNotExist"
  end

  test "skips collectors whose config section is disabled", ctx do
    scheduler = start_scheduler(ctx, config: %{docker: %{enabled: false}})
    assert %{emitted: 0, unchanged: 0} = Scheduler.run_once(scheduler)
  end

  test "a snapshot that cannot be encoded or is malformed does not stop the others", ctx do
    scheduler = start_scheduler(ctx, collectors: [MixedCollector, FakeCollector])

    log =
      capture_log(fn -> assert %{emitted: 2, unchanged: 0} = Scheduler.run_once(scheduler) end)

    assert log =~ "host snapshot skipped"

    payloads = ctx |> batch() |> Enum.map(& &1["payload"])
    assert Enum.map(payloads, & &1["collector"]) |> Enum.sort() == ["docker", "launchd"]

    # The skipped snapshots keep no fingerprint, so a later run retries them.
    log = capture_log(fn -> assert %{unchanged: 2} = Scheduler.run_once(scheduler) end)
    assert log =~ "host snapshot skipped"
  end

  test "payload carries the host label; a blank label falls back to the hostname", ctx do
    labelled = start_scheduler(ctx, host_label: "db02")
    assert %{emitted: 1} = Scheduler.run_once(labelled)
    assert [%{"payload" => %{"host_label" => "db02"}}] = batch(ctx)
    GenServer.stop(labelled)
    File.rm!(ctx.state_path)

    {:ok, hostname} = :inet.gethostname()
    blank = start_scheduler(ctx, host_label: "  ")
    assert %{emitted: 1} = Scheduler.run_once(blank)
    assert [_, %{"payload" => %{"host_label" => label}}] = batch(ctx)
    assert label == to_string(hostname)
  end

  test "a host label change re-emits unchanged items", ctx do
    first = start_scheduler(ctx, host_label: "old")
    assert %{emitted: 1} = Scheduler.run_once(first)
    GenServer.stop(first)

    second = start_scheduler(ctx, host_label: "new")
    assert %{emitted: 1} = Scheduler.run_once(second)
  end

  test "persisted state of another host id is discarded", ctx do
    first = start_scheduler(ctx)
    assert %{emitted: 1} = Scheduler.run_once(first)
    GenServer.stop(first)
    assert %{"host_id" => "host-1"} = ctx.state_path |> File.read!() |> Jason.decode!()

    other = start_scheduler(ctx, host_id: "host-2")
    assert %{emitted: 1, unchanged: 0} = Scheduler.run_once(other)
    GenServer.stop(other)

    same = start_scheduler(ctx, host_id: "host-2")
    assert %{emitted: 0, unchanged: 1} = Scheduler.run_once(same)
  end

  test "unscanned directories are carried into the payload and the fingerprint", ctx do
    :ets.insert(:fake_collector, {:unscanned, []})
    scheduler = start_scheduler(ctx, collectors: [UnscannedCollector])

    assert %{emitted: 1} = Scheduler.run_once(scheduler)
    assert [%{"payload" => %{"unscanned" => []}}] = batch(ctx)

    :ets.insert(:fake_collector, {:unscanned, ["/work/private"]})
    assert %{emitted: 1} = Scheduler.run_once(scheduler)
    assert [_, %{"payload" => %{"unscanned" => ["/work/private"]}}] = batch(ctx)
  end

  test "an oversized snapshot drops items from the end and is marked incomplete", ctx do
    items =
      for n <- 1..20 do
        %{
          name: "c#{String.pad_leading("#{n}", 2, "0")}",
          image: String.duplicate("i", 200),
          state: "running",
          ports: []
        }
      end

    set_items(items)
    scheduler = start_scheduler(ctx, max_bytes: 3_000)

    log = capture_log(fn -> assert %{emitted: 1} = Scheduler.run_once(scheduler) end)
    assert log =~ "exceeds"

    assert [event] = batch(ctx)
    assert byte_size(Jason.encode!(event)) <= 3_000
    assert %{"complete" => false, "items" => kept} = event["payload"]
    assert kept != [] and length(kept) < 20
    assert Enum.map(kept, & &1["name"]) == items |> Enum.take(length(kept)) |> Enum.map(& &1.name)

    # The truncated snapshot is deterministic: an unchanged host does not re-emit.
    capture_log(fn -> assert %{emitted: 0, unchanged: 1} = Scheduler.run_once(scheduler) end)
  end

  describe "Command.run/3" do
    test "returns output, not_found, exit status and timeout" do
      assert {:ok, "hi\n"} = Command.run("echo", ["hi"])
      assert {:error, :not_found} = Command.run("definitely-not-a-binary-xyz", [])
      assert {:error, {:exit, 3}} = Command.run("sh", ["-c", "exit 3"])
      assert {:error, :timeout} = Command.run("sleep", ["5.25"], timeout: 100)
    end

    test "output_on_error returns the output with a non-zero exit status" do
      assert {:error, {:exit, 3, "out\n"}} =
               Command.run("sh", ["-c", "echo out; exit 3"], output_on_error: true)

      assert {:error, {:exit, 3}} = Command.run("sh", ["-c", "echo out; exit 3"])
    end

    test "stderr is discarded, not merged into the output" do
      assert {:ok, "out\n"} = Command.run("sh", ["-c", "echo err >&2; echo out"])
    end

    test "timeout kills the OS process" do
      assert {:error, :timeout} = Command.run("sleep", ["30.5"], timeout: 200)
      Process.sleep(200)
      {out, status} = System.cmd("pgrep", ["-f", "sleep 30\\.5"], stderr_to_stdout: true)
      assert {out, status} == {"", 1}
    end

    test "runs in the caller and reports unrunnable files as exit 127", %{tmp_dir: dir} do
      path = Path.join(dir, "noexec")
      File.write!(path, "#!/nonexistent/interpreter\n")
      File.chmod!(path, 0o755)
      assert {:error, {:exit, status}} = Command.run(path, [])
      assert is_integer(status) and status != 0
    end
  end
end
