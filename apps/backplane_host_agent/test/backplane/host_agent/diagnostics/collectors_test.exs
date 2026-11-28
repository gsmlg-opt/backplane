defmodule Backplane.HostAgent.Diagnostics.CollectorsTest do
  use ExUnit.Case, async: true

  alias Backplane.DiagnosticsClient.{Envelope, Redaction}

  alias Backplane.HostAgent.Diagnostics.Collectors.{
    CrashArtifact,
    Log,
    Observation,
    Resource,
    Runner,
    Service
  }

  alias Backplane.HostAgent.Diagnostics.Collectors.Process, as: ProcessProbe

  @moduletag :tmp_dir
  @boot "a9d434d2-06fc-48d4-8305-d9ce690f2657"

  test "pins a direct process identity and reports only the original instance on PID reuse" do
    [target] = Runner.targets([%{"id" => "api", "source_id" => "host", "pid" => 34}])
    first_env = linux_process(91, "R")
    first = ProcessProbe.sample(34, first_env)
    assert %{status: :running, instance: old_instance, start: "91"} = first
    assert %{instance: later_instance} = ProcessProbe.sample(34, linux_process(92, "S"))
    refute later_instance == old_instance

    assert %{instance: another_boot} =
             ProcessProbe.sample(34, %{first_env | boot_id: "another-boot"})

    refute another_boot == old_instance

    {_, previous} = Observation.sample(target, %{}, first_env)
    {records, current} = Observation.sample(target, previous, linux_process(92, "S"))

    assert [
             %{
               fields: %{
                 "event_type" => "process_exit",
                 "correlation" => %{"process_instance" => ^old_instance},
                 "evidence" => %{"exception" => %{"code" => "pid_reused"}},
                 "quality" => %{"stack" => "unavailable"}
               }
             },
             %{fields: %{"event_type" => "resource_sample"}}
           ] = records

    {again, _} = Observation.sample(target, current, linux_process(92, "S"))
    assert [%{fields: %{"event_type" => "resource_sample"}}] = again
  end

  test "observes a stopped systemd service then restart and retains explicit OOM evidence" do
    service = %{"manager" => "systemd", "name" => "worker.service"}
    [target] = Runner.targets([%{"id" => "worker", "source_id" => "host", "service" => service}])
    original = systemd_env("active", 34, 0, "success", 91)
    {_, before} = Observation.sample(target, %{}, original)
    assert %{"status" => "active"} = before["service"]

    {exit, stopped} =
      Observation.sample(target, before, systemd_env("failed", 0, 0, "oom-kill", nil))

    assert %{"event_type" => "process_exit", "quality" => %{"stack" => "unavailable"}} =
             hd(exit).fields

    assert Enum.any?(exit, fn %{fields: fields} ->
             get_in(fields, ["evidence", "exception", "code"]) == "oom_kill"
           end)

    {restart, _} =
      Observation.sample(target, stopped, systemd_env("active", 34, 1, "success", 92))

    assert Enum.any?(restart, &(&1.fields["event_type"] == "service_restart"))

    assert Service.capabilities(:linux) == ["systemd", "docker"]
    assert Service.capabilities(:darwin) == ["launchd", "docker"]

    assert %{status: "unavailable", reason: "unsupported_platform"} =
             Service.sample(Service.parse(service), %{platform: :darwin})

    assert %{status: "unavailable", reason: "probe_unavailable"} =
             Service.sample(Service.parse(service), %{
               platform: :linux,
               command: fn _, _ -> {:error, :eacces} end
             })

    assert Service.parse(%{"manager" => "systemd", "name" => "--other.service"}) == nil
  end

  test "Darwin uses only the registered launchd job and treats failed disk probes as unknown" do
    service = %{"manager" => "launchd", "name" => "test.worker"}

    command = fn
      "launchctl", ["list", "test.worker"] ->
        {:ok, "{\n\t\"PID\" = 91;\n\t\"LastExitStatus\" = 15;\n\t\"Label\" = \"test.worker\";\n}"}

      "ps", ["-p", "91" | _] ->
        {:ok, "Sat Nov 28 01:11:28 2026       4960   0:00.10 Ss"}

      "sysctl", ["-n", "hw.memsize"] ->
        {:ok, "34359738368\n"}

      "sysctl", ["-n", "vm.loadavg"] ->
        {:ok, "{ 5.82 6.52 6.90 }"}

      "df", ["-Pk", "/operator-path"] ->
        {:error, :eacces}
    end

    env = %{platform: :darwin, command: command, boot_id: @boot}

    assert %{status: "active", pid: 91, exit_status: 15, manager: "launchd"} =
             Service.sample(Service.parse(service), env)

    assert %{
             status: :running,
             metrics: %{"process_rss_kib" => 4_960, "process_cpu_centiseconds" => 10}
           } = process = ProcessProbe.sample(91, env)

    summary = Resource.sample(process, "/operator-path", env)
    assert %{"name" => "host_load_average_1m", "value" => "5.82"} in summary.measurements

    assert %{"kind" => "measurement_unavailable", "reference" => "disk_blocks_total_kib"} in summary.unavailable

    refute Enum.any?(summary.measurements, &String.starts_with?(&1["name"], "disk_"))
  end

  test "container lifecycle config requires an explicit local socket and never attributes a guest PID to the host" do
    target = Service.parse(%{"manager" => "docker", "name" => "worker-container"})

    assert %{status: "unavailable", reason: "socket_unconfigured"} =
             Service.sample(target, %{platform: :darwin})

    command = fn
      "docker",
      [
        "--host",
        "unix:///operator/run/docker.sock",
        "inspect",
        "--type",
        "container",
        "--format",
        _format,
        "--",
        "worker-container"
      ] ->
        {:ok, "#{String.duplicate("d", 64)} exited 137 true 4 2026-11-28T00:00:00Z\n"}
    end

    env = %{platform: :darwin, docker_socket: "/operator/run/docker.sock", command: command}

    assert %{status: "exited", exit_status: 137, exit_reason: "oom_kill", restarts: 4, pid: nil} =
             Service.sample(target, env)
  end

  test "follows retained log rotations and advances only complete records", %{tmp_dir: dir} do
    file = Path.join(dir, "api.log")
    archive = file <> ".1"
    prefix = ~s({"level":"fatal","message":"synthetic-secret-alpha"}\n)
    File.write!(file, prefix <> "[ERROR] partial")

    assert %{
             status: :available,
             cursor: cursor,
             records: [%{measurements: %{"error_lines" => 1}}]
           } = Log.sample(file, archive, nil)

    assert cursor["offset"] == byte_size(prefix)

    File.write!(file, " entry\n", [:append])
    File.rename!(file, archive)
    File.write!(file, "[CRITICAL] synthetic-secret-beta\n")

    assert %{
             cursor: old_done,
             records: [%{kind: "structured_log_errors", measurements: %{"error_lines" => 1}}]
           } = Log.sample(file, archive, cursor)

    assert old_done["file"] == cursor["file"]

    assert %{
             cursor: new_done,
             records: [%{kind: "structured_log_errors", measurements: %{"error_lines" => 1}}]
           } = transformed = Log.sample(file, archive, old_done)

    refute new_done["file"] == cursor["file"]
    refute inspect(transformed) =~ "synthetic-secret"
    assert %{records: []} = Log.sample(file, archive, new_done)
  end

  test "emits a gap for copy-truncate and for overlong records", %{tmp_dir: dir} do
    file = Path.join(dir, "log")
    File.write!(file, "[ERROR] initial entry which is longer than the next one\n")
    assert %{cursor: cursor} = Log.sample(file, nil, nil)

    File.write!(file, "[ERROR] second\n")

    assert %{records: [%{kind: "log_truncated"}, %{kind: "structured_log_errors"}]} =
             Log.sample(file, nil, cursor)

    long_log = Path.join(dir, "long.log")
    File.write!(long_log, String.duplicate("x", 36 * 1_024) <> "\n[ERROR] recovered\n")

    assert %{cursor: skipped, records: [%{kind: "overlong_log_line"}]} =
             Log.sample(long_log, nil, nil)

    assert skipped["skip"]

    assert %{cursor: resumed, records: [%{kind: "structured_log_errors"}]} =
             Log.sample(long_log, nil, skipped)

    refute resumed["skip"]
  end

  test "summarizes only registered crash file metadata and refuses symlinks", %{tmp_dir: dir} do
    file = Path.join(dir, "worker.ips")
    secret = "synthetic-secret-crash-args"
    File.write!(file, secret)

    assert %{status: :available, bytes: bytes, reference: "crash-artifact:" <> _} =
             summary = CrashArtifact.sample(file)

    assert bytes == byte_size(secret)
    refute inspect(summary) =~ secret
    refute inspect(summary) =~ dir

    link = Path.join(dir, "link.ips")
    File.ln_s!(file, link)
    assert %{status: :unavailable} = CrashArtifact.sample(link)
    assert %{status: :unavailable, records: []} = Log.sample(link, nil, nil)
  end

  test "resumes the identical persisted observations after failed delivery and keeps health independent",
       %{tmp_dir: dir} do
    path = Path.join(dir, "worker.log")
    File.write!(path, "[ERROR] synthetic-secret-log-token\n")
    parent = self()

    opts = [
      name: __MODULE__.Runner,
      targets: [%{"id" => "worker", "source_id" => "host-ops", "log_path" => path}],
      cursor_path: Path.join(dir, "cursors.json"),
      platform: :unsupported,
      interval_ms: 3_600_000
    ]

    opts_fail =
      Keyword.put(opts, :emit, fn source, record ->
        send(parent, {:first_emit, self(), source, record})
        receive do: (:release -> {:error, :quota_exceeded})
      end)

    start_supervised!({Runner, opts_fail})
    assert :ok = Runner.trigger(__MODULE__.Runner, "worker")
    assert_receive {:first_emit, worker, "host-ops", observation}, 1_000
    assert %{"sampling" => true, "samples" => 0} = Runner.health(__MODULE__.Runner)
    ref = Process.monitor(worker)
    assert :ok = stop_supervised(Runner)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000

    opts_resume =
      Keyword.put(opts, :emit, fn source, record ->
        send(parent, {:replayed, source, record})
        :ok
      end)

    start_supervised!({Runner, opts_resume})
    assert :ok = Runner.trigger(__MODULE__.Runner, "worker")
    assert_receive {:replayed, "host-ops", ^observation}, 1_000
    assert_receive {:replayed, "host-ops", baseline}, 1_000
    assert observation.fields["source_sequence"] == 1
    assert baseline.fields["source_sequence"] == 2
    refute File.read!(Keyword.fetch!(opts, :cursor_path)) =~ "synthetic-secret-log-token"

    assert {:ok, _, _} =
             observation.fields
             |> Map.merge(%{
               "schema_version" => 1,
               "source_id" => "host-ops",
               "application" => "host"
             })
             |> Redaction.project()
             |> Envelope.seal()
  end

  defp linux_process(start, state) do
    read = fn
      "/proc/34/stat", _ ->
        if is_integer(start), do: {:ok, stat_line(start, state)}, else: {:error, :enoent}

      _, _ ->
        {:error, :eacces}
    end

    %{platform: :linux, boot_id: @boot, read: read}
  end

  defp stat_line(start, state) do
    parts = [state | List.duplicate("0", 21)] |> List.replace_at(19, Integer.to_string(start))
    "34 (name ) weird) " <> Enum.join(parts, " ")
  end

  defp systemd_env(status, pid, restarts, result, start) do
    command = fn "systemctl",
                 ["show", "--no-pager", "--property=" <> _, "--", "worker.service"] ->
      {:ok,
       "LoadState=loaded\nActiveState=#{status}\nMainPID=#{pid}\nNRestarts=#{restarts}\nExecMainStatus=9\nExecMainCode=2\nResult=#{result}\nInvocationID=#{String.duplicate(Integer.to_string(restarts + 1), 32)}\n"}
    end

    Map.put(linux_process(start, "S"), :command, command)
  end
end
