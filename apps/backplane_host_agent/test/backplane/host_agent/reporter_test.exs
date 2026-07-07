defmodule Backplane.HostAgent.ReporterTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Reporter

  test "formats heartbeat payload" do
    config = %{
      machine_name: "t430",
      targets: [
        %{name: "agents", runtime: "agent-skills", path: "/tmp/skills", enabled: true}
      ]
    }

    payload = Reporter.heartbeat(config)

    assert %{
             "agent_version" => "0.1.0",
             "hostname" => hostname,
             "machine_name" => "t430",
             "metadata" => %{"otp_release" => otp_release},
             "targets" => [
               %{
                 "enabled" => true,
                 "name" => "agents",
                 "path" => "/tmp/skills",
                 "runtime" => "agent-skills"
               }
             ]
           } = payload

    assert is_binary(hostname)
    assert hostname != ""
    assert otp_release == System.otp_release()
  end

  test "formats loaded config report payload with token redacted" do
    config = %{
      host_id: "host-1",
      machine_name: "t430",
      hub_url: "http://localhost:4220",
      token: "secret-token",
      interval_ms: 60_000,
      manifest_path: "/tmp/manifest.json",
      work_dir: "/tmp/work",
      http_bind: "127.0.0.1",
      http_port: 4222,
      memory: %{
        enabled: true,
        db_path: "/tmp/work/memory/host_agent_memory.db",
        bound_scope: "proj_local",
        local_ttl_days: 90,
        sync_interval_ms: 5_000,
        sync_batch_size: 50,
        max_attempts: 5,
        tombstone_relearn: "block"
      },
      telemetry: %{
        enabled: true,
        dir: "/tmp/work/telemetry",
        sync_interval_ms: 10_000,
        sync_batch_size: 100,
        retention_days: 14
      },
      targets: [
        %{name: "agents", runtime: "agent-skills", path: "/tmp/work/skills", enabled: true}
      ]
    }

    assert %{
             "agent" => %{
               "host_id" => "host-1",
               "machine_name" => "t430",
               "hub_url" => "http://localhost:4220",
               "token" => "REDACTED",
               "interval_ms" => 60_000,
               "manifest_path" => "/tmp/manifest.json",
               "work_dir" => "/tmp/work",
               "http_bind" => "127.0.0.1",
               "http_port" => 4222
             },
             "memory" => %{"bound_scope" => "proj_local"},
             "telemetry" => %{"dir" => "/tmp/work/telemetry"},
             "targets" => [
               %{
                 "enabled" => true,
                 "name" => "agents",
                 "path" => "/tmp/work/skills",
                 "runtime" => "agent-skills"
               }
             ]
           } = Reporter.config_report(config)
  end

  test "formats sync result payload" do
    payload =
      Reporter.sync_result(:synced, [
        %{"skill_name" => "Repo Review", "status" => "synced"}
      ])

    assert %{
             "finished_at" => finished_at,
             "results" => [%{"skill_name" => "Repo Review", "status" => "synced"}],
             "started_at" => started_at,
             "status" => "synced"
           } = payload

    assert {:ok, _started, _offset} = DateTime.from_iso8601(started_at)
    assert {:ok, _finished, _offset} = DateTime.from_iso8601(finished_at)
  end

  test "uses the supplied sync result start time" do
    started_at = ~U[2026-06-17 12:34:56Z]

    payload = Reporter.sync_result(:synced, [], started_at)

    assert payload["started_at"] == DateTime.to_iso8601(started_at)
  end
end
