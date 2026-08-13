defmodule Backplane.HostAgent.ReporterTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Reporter

  defmodule CaptureSpool do
    def stats(:capture_spool) do
      %{
        pending_depth: 3,
        pending_bytes: 4096,
        oldest_occurred_at:
          DateTime.utc_now() |> DateTime.add(-7, :second) |> DateTime.to_iso8601(),
        captured_count: 12,
        redacted_count: 4,
        rejected_count: 2,
        retry_count: 1,
        dead_letter_count: 1
      }
    end
  end

  defmodule CaptureUploader do
    def status(:capture_uploader) do
      %{
        connection_state: :connected,
        upload_latency_ms: 14,
        ack_latency_ms: 9
      }
    end
  end

  defmodule UnavailableCaptureSpool do
    def stats(:capture_spool), do: raise("spool telemetry unavailable")
  end

  defmodule UnavailableCaptureUploader do
    def status(:capture_uploader), do: exit(:uploader_telemetry_unavailable)
  end

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

  test "heartbeat includes content-free capture runtime metrics" do
    payload =
      Reporter.heartbeat(%{
        machine_name: "t430",
        capture: %{
          enabled: true,
          spool: :capture_spool,
          spool_module: CaptureSpool,
          uploader: :capture_uploader,
          uploader_module: CaptureUploader
        }
      })

    assert %{
             "connection_state" => "connected",
             "spool_depth" => 3,
             "spool_bytes" => 4096,
             "oldest_event_age_ms" => age,
             "captured_count" => 12,
             "redacted_count" => 4,
             "rejected_count" => 2,
             "retry_count" => 1,
             "dead_letter_count" => 1,
             "upload_latency_ms" => 14,
             "ack_latency_ms" => 9
           } = payload["capture"]

    assert age in 6_000..8_000
    refute inspect(payload["capture"]) =~ "prompt"
  end

  test "heartbeat reports unavailable capture measurements when telemetry reads fail" do
    payload =
      Reporter.heartbeat(%{
        machine_name: "t430",
        capture: %{
          enabled: true,
          spool: :capture_spool,
          spool_module: UnavailableCaptureSpool,
          uploader: :capture_uploader,
          uploader_module: UnavailableCaptureUploader
        }
      })

    assert %{
             "connection_state" => "disconnected",
             "spool_depth" => nil,
             "spool_bytes" => nil,
             "oldest_event_age_ms" => nil,
             "age_warning" => nil,
             "captured_count" => nil,
             "redacted_count" => nil,
             "rejected_count" => nil,
             "retry_count" => nil,
             "dead_letter_count" => nil,
             "upload_latency_ms" => nil,
             "ack_latency_ms" => nil
           } = payload["capture"]
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
