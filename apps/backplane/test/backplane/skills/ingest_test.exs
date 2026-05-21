defmodule Backplane.Skills.IngestTest do
  use Backplane.DataCase, async: false

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Settings
  alias Backplane.SkillArchiveCase
  alias Backplane.Skills.{Blob.LocalFS, Ingest, Registry, Skill}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    :ok = Settings.set("skills.blob.local_root", tmp_dir)

    if :ets.whereis(:backplane_skills) != :undefined do
      :ets.delete_all_objects(:backplane_skills)
    end

    on_exit(fn ->
      if Process.whereis(Settings), do: Settings.set("skills.blob.local_root", nil)
    end)

    :ok
  end

  test "uses meta.json slug before SKILL.md name" do
    archive =
      SkillArchiveCase.tar_gz([
        {"folder/SKILL.md", SkillArchiveCase.skill_md("Readable Name")},
        {"folder/meta.json", SkillArchiveCase.meta_json(%{"slug" => "stable-slug"})}
      ])

    assert {:ok, skill} = Ingest.ingest(archive, filename: "ignored.tar.gz")
    assert skill.slug == "stable-slug"
    assert skill.name == "Readable Name"
    assert skill.archive_ref == archive_ref(archive)
  end

  test "derives slug from SKILL.md name when meta.json slug is absent" do
    archive =
      SkillArchiveCase.tar_gz([
        {"folder/SKILL.md", SkillArchiveCase.skill_md("Readable Name")}
      ])

    assert {:ok, skill} = Ingest.ingest(archive, filename: "ignored.tar.gz")
    assert skill.slug == "readable-name"
  end

  test "falls back to archive filename when SKILL.md has no name" do
    archive =
      SkillArchiveCase.tar_gz([
        {"folder/SKILL.md", "---\ndescription: Nameless\n---\n\n# Body\n"}
      ])

    assert {:ok, skill} = Ingest.ingest(archive, filename: "fallback-name.tar.gz")
    assert skill.slug == "fallback-name"
    assert skill.name == "fallback-name"
  end

  test "same slug and same hash is a no-op" do
    archive =
      SkillArchiveCase.tar_gz([
        {"folder/SKILL.md", SkillArchiveCase.skill_md("Same Hash")},
        {"folder/meta.json", SkillArchiveCase.meta_json(%{"slug" => "same-hash"})}
      ])

    assert {:ok, first} = Ingest.ingest(archive)
    assert {:ok, second} = Ingest.ingest(archive)

    assert first.id == second.id
    assert first.updated_at == second.updated_at
    assert Repo.aggregate(from(s in Skill, where: s.slug == "same-hash"), :count) == 1
  end

  test "same slug and different hash replaces archive metadata" do
    archive_v1 =
      SkillArchiveCase.tar_gz([
        {"folder/SKILL.md", SkillArchiveCase.skill_md("Replace Me")},
        {"folder/meta.json", SkillArchiveCase.meta_json(%{"slug" => "replace-me"})}
      ])

    archive_v2 =
      SkillArchiveCase.tar_gz([
        {"folder/SKILL.md",
         String.replace(SkillArchiveCase.skill_md("Replace Me"), "uploaded", "new")},
        {"folder/meta.json",
         SkillArchiveCase.meta_json(%{"slug" => "replace-me", "version" => "2.0.0"})}
      ])

    assert {:ok, first} = Ingest.ingest(archive_v1)
    assert {:ok, second} = Ingest.ingest(archive_v2)

    assert first.id == second.id
    assert second.content_hash == hash(archive_v2)
    assert second.archive_ref == archive_ref(archive_v2)
    assert second.version == "2.0.0"
    assert LocalFS.exists?(hash(archive_v2))
  end

  test "invalid archive does not write a blob" do
    archive = "not a gzip archive"

    assert {:error, :invalid_archive} = Ingest.ingest(archive)
    refute LocalFS.exists?(hash(archive))
  end

  test "successful ingest refreshes registry and broadcasts prompt list change" do
    Phoenix.PubSub.subscribe(
      Backplane.PubSub,
      Backplane.PubSubBroadcaster.mcp_notifications_topic()
    )

    archive =
      SkillArchiveCase.tar_gz([
        {"folder/SKILL.md", SkillArchiveCase.skill_md("Broadcast Skill")},
        {"folder/meta.json", SkillArchiveCase.meta_json(%{"slug" => "broadcast-skill"})}
      ])

    assert {:ok, skill} = Ingest.ingest(archive)
    assert {:ok, cached} = Registry.fetch("broadcast-skill")
    assert cached.id == skill.id
    assert cached.slug == "broadcast-skill"
    assert cached.archive_ref == archive_ref(archive)

    assert_receive {:mcp_notification,
                    %{jsonrpc: "2.0", method: "notifications/prompts/list_changed"}}
  end

  defp hash(archive), do: :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)
  defp archive_ref(archive), do: "sha256/#{hash(archive)}.tar.gz"
end
