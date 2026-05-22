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
end
