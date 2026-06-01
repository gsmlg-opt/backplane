defmodule BackplaneWeb.HostAgentSyncE2ETest do
  use Backplane.ChannelCase, async: false

  alias Backplane.Fixtures
  alias Backplane.Skills.{Assignments, DesiredState, Hosts}

  test "host receives desired state for an assigned archive-backed skill" do
    archive_hash = String.duplicate("c", 64)

    {:ok, host} = Hosts.create_agent(%{"name" => "sync-host"})

    skill =
      Fixtures.insert_skill(
        id: "db/sync-review",
        slug: "sync-review",
        name: "Sync Review",
        content_hash: "sha256:#{archive_hash}",
        archive_ref: "sha256/#{archive_hash}.tar.gz",
        source_kind: "archive",
        enabled: true
      )

    assert {:ok, _assignment} =
             Assignments.assign_skill(host, skill, %{"targets" => ["agents", "commands"]})

    assert {:ok, %{skills: [desired_skill]}} = DesiredState.for_host(host)

    assert %{
             slug: "sync-review",
             targets: ["agents", "commands"],
             bundle: %{transport: "websocket", event: "get_skill_bundle"}
           } = desired_skill

    refute Map.has_key?(desired_skill, :download_url)
  end
end
