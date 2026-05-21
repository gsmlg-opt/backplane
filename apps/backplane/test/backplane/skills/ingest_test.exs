defmodule Backplane.Skills.IngestTest do
  use Backplane.DataCase, async: false

  import Backplane.SkillArchiveCase

  alias Backplane.PubSubBroadcaster
  alias Backplane.Repo
  alias Backplane.Skills
  alias Backplane.Skills.{Blob, Ingest, Registry, Skill}

  @moduletag :tmp_dir

  describe "ingest/2 slug resolution" do
    test "uses meta.json slug before SKILL.md name", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"meta-slug/SKILL.md", skill_md(name: "Skill Name Slug")},
          {"meta-slug/meta.json", Jason.encode!(%{"slug" => "meta-wins"})}
        ])

      assert {:ok, %Skill{} = skill} = Ingest.ingest(archive, blob: [root: blob_root(tmp_dir)])
      assert skill.id == "skill/meta-wins"
      assert skill.slug == "meta-wins"
      assert skill.name == "Skill Name Slug"
    end

    test "uses SKILL.md name when meta.json slug is blank", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"name-slug/SKILL.md", skill_md(name: "Skill Name Slug")},
          {"name-slug/meta.json", Jason.encode!(%{"slug" => "  "})}
        ])

      assert {:ok, %Skill{} = skill} = Ingest.ingest(archive, blob: [root: blob_root(tmp_dir)])
      assert skill.id == "skill/skill-name-slug"
      assert skill.slug == "skill-name-slug"
    end

    test "uses archive filename when meta and SKILL.md name are not usable", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(
          tmp_dir,
          [
            {"filename-slug/SKILL.md", skill_md(name: "\"!!!\"")},
            {"filename-slug/meta.json", Jason.encode!(%{"slug" => nil})}
          ],
          name: "Fallback Archive.tar.gz"
        )

      assert {:ok, %Skill{} = skill} = Ingest.ingest(archive, blob: [root: blob_root(tmp_dir)])
      assert skill.id == "skill/fallback-archive"
      assert skill.slug == "fallback-archive"
    end
  end

  describe "ingest/2 persistence" do
    test "same slug and same hash is a no-op", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"noop-skill/SKILL.md", skill_md(name: "Noop Skill")},
          {"noop-skill/meta.json", Jason.encode!(%{"slug" => "noop-skill"})}
        ])

      opts = [blob: [root: blob_root(tmp_dir)]]

      assert {:ok, first} = Ingest.ingest(archive, opts)
      assert {:ok, second} = Ingest.ingest(archive, opts)

      assert first.id == second.id
      assert first.content_hash == second.content_hash
      assert first.archive_ref == second.archive_ref
      assert Repo.aggregate(Skill, :count, :id) == 1
    end

    test "same slug and different hash replaces archive metadata", %{tmp_dir: tmp_dir} do
      opts = [blob: [root: blob_root(tmp_dir)]]

      first_archive =
        create_archive!(
          tmp_dir,
          [
            {"replace-skill/SKILL.md", skill_md(name: "Replace Skill", version: "1.0.0")},
            {"replace-skill/meta.json",
             Jason.encode!(%{"slug" => "replace-skill", "license" => "MIT"})}
          ],
          name: "replace-v1.tar.gz"
        )

      second_archive =
        create_archive!(
          tmp_dir,
          [
            {"replace-skill/SKILL.md", skill_md(name: "Replace Skill Updated", version: "2.0.0")},
            {"replace-skill/meta.json",
             Jason.encode!(%{
               "slug" => "replace-skill",
               "license" => "Apache-2.0",
               "homepage" => "https://example.com/replace"
             })}
          ],
          name: "replace-v2.tar.gz"
        )

      assert {:ok, first} = Ingest.ingest(first_archive, opts)
      assert {:ok, second} = Ingest.ingest(second_archive, opts)

      assert first.id == second.id
      assert first.content_hash != second.content_hash
      assert first.archive_ref != second.archive_ref
      assert second.name == "Replace Skill Updated"
      assert second.version == "2.0.0"
      assert second.license == "Apache-2.0"
      assert second.homepage == "https://example.com/replace"
      assert second.size_bytes == File.stat!(second_archive).size
      assert second.file_count == 2
      assert Repo.aggregate(Skill, :count, :id) == 1
    end

    test "invalid archive does not write a blob", %{tmp_dir: tmp_dir} do
      archive = Path.join(tmp_dir, "invalid.tar.gz")
      blob_root = blob_root(tmp_dir)
      File.write!(archive, "not a tarball")

      assert {:error, _reason} = Ingest.ingest(archive, blob: [root: blob_root])
      refute File.exists?(Path.join(blob_root, "sha256"))
      assert Repo.aggregate(Skill, :count, :id) == 0
    end

    test "successful ingest refreshes registry and broadcasts prompt list changes", %{
      tmp_dir: tmp_dir
    } do
      PubSubBroadcaster.subscribe(PubSubBroadcaster.mcp_notifications_topic())

      archive =
        create_archive!(tmp_dir, [
          {"refresh-skill/SKILL.md", skill_md(name: "Refresh Skill")},
          {"refresh-skill/meta.json",
           Jason.encode!(%{
             "slug" => "refresh-skill",
             "license" => "MIT",
             "homepage" => "https://example.com/refresh"
           })}
        ])

      assert {:ok, skill} = Skills.ingest_archive(archive, %{blob: [root: blob_root(tmp_dir)]})
      assert Blob.exists?(skill.archive_ref, root: blob_root(tmp_dir))
      assert {:ok, entry} = Registry.fetch("skill/refresh-skill")
      assert entry.slug == "refresh-skill"
      assert entry.version == "1.2.3"
      assert entry.license == "MIT"
      assert entry.homepage == "https://example.com/refresh"
      assert entry.archive_ref == skill.archive_ref
      assert entry.size_bytes == File.stat!(archive).size
      assert entry.file_count == 2
      assert entry.source_kind == "archive"

      assert_receive {:mcp_notification,
                      %{jsonrpc: "2.0", method: "notifications/prompts/list_changed"}}
    end
  end

  defp blob_root(tmp_dir), do: Path.join(tmp_dir, "blobs")
end
