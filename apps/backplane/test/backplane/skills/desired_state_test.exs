defmodule Backplane.Skills.DesiredStateTest do
  use Backplane.DataCase, async: true

  alias Backplane.Repo
  alias Backplane.Skills.{Assignments, DesiredState, Hosts, Skill}

  describe "for_host/1" do
    test "returns enabled assignments with slug download URLs" do
      {:ok, host, _token} = Hosts.create_host(%{"name" => "t430"})
      skill = insert_skill!("db/repo-review", "repo-review", "Repo Review")

      {:ok, _assignment} = Assignments.assign_skill(host, skill, %{"targets" => ["agents"]})

      assert {:ok, desired} = DesiredState.for_host(host)

      assert %{
               schema_version: 1,
               host: %{id: host_id, name: "t430"},
               skills: [entry]
             } = desired

      assert host_id == host.id

      assert %{
               id: "db/repo-review",
               slug: "repo-review",
               name: "Repo Review",
               version: "0.1.0",
               checksum: checksum,
               targets: ["agents"],
               enabled: true,
               download_url: "/api/host-agent/skills/repo-review/download"
             } = entry

      assert checksum == skill.content_hash

      assert Map.keys(entry) |> Enum.sort() ==
               [:checksum, :download_url, :enabled, :id, :name, :slug, :targets, :version]
    end

    test "excludes disabled assignments and disabled skills" do
      {:ok, host, _token} = Hosts.create_host(%{"name" => "t430"})
      enabled_skill = insert_skill!("db/enabled-skill", "enabled-skill", "Enabled Skill")

      disabled_assignment_skill =
        insert_skill!("db/disabled-assignment", "disabled-assignment", "Disabled Assignment")

      disabled_skill =
        insert_skill!("db/disabled-skill", "disabled-skill", "Disabled Skill", enabled: false)

      {:ok, _enabled_assignment} =
        Assignments.assign_skill(host, enabled_skill, %{"targets" => ["agents"]})

      {:ok, assignment} =
        Assignments.assign_skill(host, disabled_assignment_skill, %{"targets" => ["agents"]})

      {:ok, _disabled_assignment} =
        Assignments.update_assignment(assignment, %{"enabled" => false})

      {:ok, _disabled_skill_assignment} =
        Assignments.assign_skill(host, disabled_skill, %{"targets" => ["agents"]})

      assert {:ok, %{skills: [%{slug: "enabled-skill"}]}} = DesiredState.for_host(host)
    end

    test "excludes enabled assigned skills that are not archive-backed" do
      {:ok, host, _token} = Hosts.create_host(%{"name" => "t430"})
      archive_skill = insert_skill!("db/archive-skill", "archive-skill", "Archive Skill")

      non_archive_skill =
        insert_skill!("db/plain-skill", "plain-skill", "Plain Skill", archive?: false)

      {:ok, _archive_assignment} =
        Assignments.assign_skill(host, archive_skill, %{"targets" => ["agents"]})

      {:ok, _plain_assignment} =
        Assignments.assign_skill(host, non_archive_skill, %{"targets" => ["agents"]})

      assert {:ok, %{skills: [%{slug: "archive-skill"}]}} = DesiredState.for_host(host)
    end
  end

  defp insert_skill!(id, slug, name, attrs \\ []) do
    hash = Keyword.get_lazy(attrs, :hash, fn -> "sha256:" <> String.duplicate("b", 64) end)
    archive_hash = String.replace_prefix(hash, "sha256:", "")
    archive? = Keyword.get(attrs, :archive?, true)

    Repo.insert!(%Skill{
      id: id,
      slug: slug,
      name: name,
      version: Keyword.get(attrs, :version, "0.1.0"),
      content: "# #{name}",
      content_hash: hash,
      archive_ref: if(archive?, do: "sha256/#{archive_hash}.tar.gz"),
      source_kind: if(archive?, do: "archive", else: "database"),
      enabled: Keyword.get(attrs, :enabled, true)
    })
  end
end
