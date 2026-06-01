defmodule Backplane.Skills.AssignmentsTest do
  use Backplane.DataCase, async: false

  alias Backplane.Repo
  alias Backplane.Skills.{AgentManage, Assignments, Hosts, Skill}

  setup do
    AgentManage.clear()
    on_exit(fn -> AgentManage.clear() end)

    {:ok, host} = Hosts.create_agent(%{"name" => "t430"})

    skill =
      Repo.insert!(%Skill{
        id: "db/host-agent-test",
        slug: "host-agent-test",
        name: "Host Agent Test",
        content: "# Host Agent Test",
        content_hash: "sha256:" <> String.duplicate("a", 64),
        archive_ref: "sha256/#{String.duplicate("a", 64)}.tar.gz",
        enabled: true
      })

    %{host: host, skill: skill}
  end

  test "assigns a skill to a host", %{host: host, skill: skill} do
    assert {:ok, assignment} =
             Assignments.assign_skill(host, skill, %{
               "targets" => ["agents"],
               "metadata" => %{"reason" => "test"}
             })

    assert assignment.host_id == host.id
    assert assignment.skill_id == skill.id
    assert assignment.targets == ["agents"]
    assert assignment.enabled == true
  end

  test "list_enabled_for_host excludes disabled assignments", %{host: host, skill: skill} do
    assert {:ok, assignment} = Assignments.assign_skill(host, skill, %{"targets" => ["agents"]})
    assert [%{id: id}] = Assignments.list_enabled_for_host(host)
    assert id == assignment.id

    assert {:ok, _disabled} = Assignments.update_assignment(assignment, %{"enabled" => false})
    assert [] = Assignments.list_enabled_for_host(host)
  end

  test "assign_skill returns changeset errors for stale host or skill", %{
    host: host,
    skill: skill
  } do
    Repo.delete!(host)

    assert {:error, host_changeset} = Assignments.assign_skill(host, skill, %{})
    assert {"does not exist", _} = host_changeset.errors[:host_id]

    {:ok, fresh_host} = Hosts.create_agent(%{"name" => "fresh-host"})
    Repo.delete!(skill)

    assert {:error, skill_changeset} = Assignments.assign_skill(fresh_host, skill, %{})
    assert {"does not exist", _} = skill_changeset.errors[:skill_id]
  end
end
