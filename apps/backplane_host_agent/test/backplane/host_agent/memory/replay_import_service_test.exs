defmodule Backplane.HostAgent.Memory.ReplayImportServiceTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.ImportSupervisor
  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool
  alias Backplane.HostAgent.Services.Memory

  @moduletag :tmp_dir

  defmodule FakeChannel do
    def push(owner, "memory_import_batch", payload) do
      send(owner, {:import_lifecycle, payload})
      {:ok, %{"ok" => true}}
    end

    def push(owner, "memory_events", %{"batch_id" => batch_id, "events" => events}) do
      send(owner, {:memory_events, events})

      {:ok,
       %{
         "batch_id" => batch_id,
         "results" => Enum.map(events, &%{"event_id" => &1["event_id"], "status" => "accepted"})
       }}
    end
  end

  defmodule BlockingImport do
    def run(_path, opts) do
      owner = Keyword.fetch!(opts, :test_owner)
      send(owner, {:import_started, self(), opts})

      receive do
        :finish -> {:ok, %{}}
      end
    end
  end

  describe "import task supervision" do
    test "a completed import executes once and leaves the supervisor available" do
      supervisor = start_import_supervisor!()
      owner = self()

      assert {:ok, _task} =
               ImportSupervisor.enqueue(fn -> send(owner, :completed_execution) end, supervisor)

      assert_receive :completed_execution
      refute_receive :completed_execution, 50
      assert_supervisor_idle(supervisor)
      assert Process.alive?(Process.whereis(supervisor))
    end

    test "a failed import is not restarted and leaves the supervisor available" do
      supervisor = start_import_supervisor!()
      owner = self()

      assert {:ok, _task} =
               ImportSupervisor.enqueue(
                 fn ->
                   send(owner, :failed_execution)
                   raise "expected import failure"
                 end,
                 supervisor
               )

      assert_receive :failed_execution
      refute_receive :failed_execution, 50
      assert_supervisor_idle(supervisor)
      assert Process.alive?(Process.whereis(supervisor))
    end
  end

  test "acceptance is prompt and uses a UUID batch id independent from request correlation", %{
    tmp_dir: dir
  } do
    supervisor = start_import_supervisor!()
    spool = start_spool!(Path.join(dir, "blocking-capture.db"))
    configure_profile!(dir, Path.join(dir, "session.jsonl"), spool)

    started_at = System.monotonic_time(:millisecond)

    assert {:ok,
            %{
              "status" => "accepted",
              "batch_id" => batch_id,
              "request_id" => "correlation-not-a-uuid"
            }} =
             Memory.call(
               "replay_import",
               %{"profile" => "claude_default", "request_id" => "correlation-not-a-uuid"},
               %{
                 channel: self(),
                 import_module: BlockingImport,
                 import_supervisor: supervisor,
                 import_opts: [test_owner: self()]
               }
             )

    assert System.monotonic_time(:millisecond) - started_at < 100

    assert Regex.match?(
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
             batch_id
           )

    refute batch_id == "correlation-not-a-uuid"
    assert_receive {:import_started, task, opts}
    assert opts[:batch_id] == batch_id

    assert {:ok, %{"status" => "accepted"}} =
             Memory.call(
               "replay_import",
               %{"profile" => "claude_default", "request_id" => "second"},
               %{
                 channel: self(),
                 import_module: BlockingImport,
                 import_supervisor: supervisor,
                 import_opts: [test_owner: self()]
               }
             )

    assert_receive {:import_started, second_task, _opts}

    assert {:error, :import_capacity_reached} =
             Memory.call(
               "replay_import",
               %{"profile" => "claude_default", "request_id" => "third"},
               %{
                 channel: self(),
                 import_module: BlockingImport,
                 import_supervisor: supervisor,
                 import_opts: [test_owner: self()]
               }
             )

    send(task, :finish)
    send(second_task, :finish)
  end

  test "opaque profile resolves on-host and lifecycle completes only after upload acknowledgement",
       %{
         tmp_dir: dir
       } do
    transcript = Path.join(dir, "sessions/session.jsonl")
    File.mkdir_p!(Path.dirname(transcript))

    File.write!(
      transcript,
      Jason.encode!(%{
        "type" => "user",
        "uuid" => "profile-source",
        "sessionId" => "profile-session",
        "timestamp" => "2026-08-12T01:02:03Z",
        "message" => %{"content" => "safe"}
      })
    )

    spool = start_spool!(Path.join(dir, "capture.db"))
    supervisor = start_import_supervisor!()
    configure_profile!(dir, transcript, spool)

    assert {:ok,
            %{"batch_id" => batch_id, "status" => "accepted", "request_id" => "request-profile"}} =
             Memory.call(
               "replay_import",
               %{
                 "profile" => "claude_default",
                 "request_id" => "request-profile",
                 "max_files" => 10,
                 "max_entries" => 10,
                 "max_bytes" => 1_000_000
               },
               %{
                 channel: self(),
                 channel_module: FakeChannel,
                 import_supervisor: supervisor
               }
             )

    assert_receive {:import_lifecycle,
                    %{
                      "protocol" => "host_import.v1",
                      "action" => "started",
                      "batch_id" => ^batch_id,
                      "request_id" => "request-profile",
                      "source_path_fingerprint" => "sha256:" <> _
                    }}

    assert_receive {:memory_events, [%{"session_id" => "profile-session"}]}

    assert_receive {:import_lifecycle,
                    %{
                      "protocol" => "host_import.v1",
                      "action" => "completed",
                      "batch_id" => ^batch_id,
                      "request_id" => "request-profile",
                      "imported_count" => 1
                    }}

    assert [] = Spool.next_batch(spool, 10, 1_000_000)

    assert {:error, :import_profile_not_found} =
             Memory.call("replay_import", %{"profile" => "unknown"}, %{
               channel: self(),
               import_supervisor: supervisor
             })
  end

  test "an accepted import reports a failed lifecycle when the host path is unavailable", %{
    tmp_dir: dir
  } do
    spool = start_spool!(Path.join(dir, "failed-capture.db"))
    supervisor = start_import_supervisor!()
    configure_profile!(dir, Path.join(dir, "missing.jsonl"), spool)

    assert {:ok, %{"batch_id" => batch_id, "status" => "accepted"}} =
             Memory.call(
               "replay_import",
               %{"profile" => "claude_default", "request_id" => "failed-correlation"},
               %{
                 channel: self(),
                 channel_module: FakeChannel,
                 import_supervisor: supervisor
               }
             )

    assert_receive {:import_lifecycle,
                    %{
                      "action" => "started",
                      "batch_id" => ^batch_id,
                      "request_id" => "failed-correlation"
                    }}

    assert_receive {:import_lifecycle,
                    %{
                      "action" => "failed",
                      "batch_id" => ^batch_id,
                      "request_id" => "failed-correlation",
                      "error" => "import_failed"
                    }}
  end

  defp configure_profile!(dir, transcript, spool) do
    memory_before = Application.get_env(:backplane_host_agent, :memory_config)
    runtime_before = Application.get_env(:backplane_host_agent, :capture_runtime)

    on_exit(fn ->
      restore_env(:memory_config, memory_before)
      restore_env(:capture_runtime, runtime_before)
    end)

    Application.put_env(:backplane_host_agent, :memory_config, %{
      import_profiles: %{
        "claude_default" => %{
          path: transcript,
          approved_roots: [dir],
          allow_symlinks: false,
          max_depth: 12
        }
      }
    })

    Application.put_env(:backplane_host_agent, :capture_runtime, %{
      host_id: "host-profile",
      agent_id: "claude_code",
      spool: spool,
      spool_module: Spool
    })
  end

  defp start_import_supervisor! do
    name = String.to_atom("replay_import_supervisor_#{System.unique_integer([:positive])}")
    start_supervised!({ImportSupervisor, name: name})
    name
  end

  defp start_spool!(path) do
    name = String.to_atom("replay_import_spool_#{System.unique_integer([:positive])}")

    start_supervised!(
      {Spool,
       database: path,
       name: name,
       id: {:replay_import_spool, System.unique_integer([:positive])},
       spool_max_bytes: 10_000_000,
       spool_max_age_days: 30,
       compaction_batch_size: 100}
    )

    name
  end

  defp assert_supervisor_idle(supervisor, attempts \\ 20)

  defp assert_supervisor_idle(supervisor, attempts) when attempts > 0 do
    case DynamicSupervisor.count_children(supervisor) do
      %{active: 0, workers: 0} ->
        :ok

      _counts ->
        Process.sleep(5)
        assert_supervisor_idle(supervisor, attempts - 1)
    end
  end

  defp assert_supervisor_idle(supervisor, 0) do
    assert %{active: 0, workers: 0} = DynamicSupervisor.count_children(supervisor)
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane_host_agent, key)
  defp restore_env(key, value), do: Application.put_env(:backplane_host_agent, key, value)
end
