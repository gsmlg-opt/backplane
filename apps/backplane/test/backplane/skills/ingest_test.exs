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

    test "stores archive from the upload path with unchanged hash and ref semantics", %{
      tmp_dir: tmp_dir
    } do
      blob_root = blob_root(tmp_dir)

      archive =
        create_archive!(tmp_dir, [
          {"path-backed/SKILL.md", skill_md(name: "Path Backed Skill")},
          {"path-backed/meta.json", Jason.encode!(%{"slug" => "path-backed"})}
        ])

      archive_hash = archive |> File.stream!([], 2048) |> sha256_stream()

      assert {:ok, %Skill{} = skill} = Ingest.ingest(archive, blob: [root: blob_root])
      assert skill.content_hash == archive_hash
      assert skill.archive_ref == "sha256/#{archive_hash}.tar.gz"
      assert Blob.exists?(skill.archive_ref, root: blob_root)
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
      refute Blob.exists?(first.archive_ref, root: blob_root(tmp_dir))
      assert Blob.exists?(second.archive_ref, root: blob_root(tmp_dir))
      assert second.name == "Replace Skill Updated"
      assert second.version == "2.0.0"
      assert second.license == "Apache-2.0"
      assert second.homepage == "https://example.com/replace"
      assert second.size_bytes == File.stat!(second_archive).size
      assert second.file_count == 2
      assert Repo.aggregate(Skill, :count, :id) == 1
    end

    test "same slug and different hash preserves old blob when another skill references it", %{
      tmp_dir: tmp_dir
    } do
      opts = [blob: [root: blob_root(tmp_dir)]]

      first_archive =
        create_archive!(
          tmp_dir,
          [
            {"shared-old-ref/SKILL.md", skill_md(name: "Shared Old Ref", version: "1.0.0")},
            {"shared-old-ref/meta.json", Jason.encode!(%{"slug" => "shared-old-ref"})}
          ],
          name: "shared-old-ref-v1.tar.gz"
        )

      second_archive =
        create_archive!(
          tmp_dir,
          [
            {"shared-old-ref/SKILL.md",
             skill_md(name: "Shared Old Ref Updated", version: "2.0.0")},
            {"shared-old-ref/meta.json", Jason.encode!(%{"slug" => "shared-old-ref"})}
          ],
          name: "shared-old-ref-v2.tar.gz"
        )

      assert {:ok, first} = Ingest.ingest(first_archive, opts)

      insert_skill!(
        id: "skill/shared-old-ref-consumer",
        slug: "shared-old-ref-consumer",
        name: "Shared Old Ref Consumer",
        archive_ref: first.archive_ref,
        source_kind: "archive"
      )

      assert {:ok, second} = Ingest.ingest(second_archive, opts)

      assert first.archive_ref != second.archive_ref
      assert Blob.exists?(first.archive_ref, root: blob_root(tmp_dir))
      assert Blob.exists?(second.archive_ref, root: blob_root(tmp_dir))
    end

    test "same slug on a non-archive skill returns a conflict without writing a blob", %{
      tmp_dir: tmp_dir
    } do
      blob_root = blob_root(tmp_dir)

      insert_skill!(
        id: "db/conflict-skill",
        slug: "conflict-skill",
        name: "Existing Database Skill",
        source_kind: "db"
      )

      archive =
        create_archive!(tmp_dir, [
          {"conflict-skill/SKILL.md", skill_md(name: "Conflict Skill")},
          {"conflict-skill/meta.json", Jason.encode!(%{"slug" => "conflict-skill"})}
        ])

      assert {:error, {:slug_conflict, "conflict-skill"}} =
               Ingest.ingest(archive, blob: [root: blob_root])

      refute File.exists?(Path.join(blob_root, "sha256"))
      assert Repo.aggregate(Skill, :count, :id) == 1
      assert Repo.get!(Skill, "db/conflict-skill").source_kind == "db"
    end

    test "transaction failure keeps a blob referenced by a committed skill", %{tmp_dir: tmp_dir} do
      blob_root = blob_root(tmp_dir)

      archive =
        create_archive!(tmp_dir, [
          {"shared-ref/SKILL.md", skill_md(name: "Shared Ref Skill")},
          {"shared-ref/meta.json", Jason.encode!(%{"slug" => "shared-ref"})}
        ])

      archive_bytes = File.read!(archive)
      assert {:ok, archive_ref} = Blob.put(archive_bytes, root: blob_root)

      insert_skill!(
        id: "skill/shared-ref",
        slug: "occupied-id",
        name: "Existing Archive Skill",
        content_hash: sha256(archive_bytes),
        archive_ref: archive_ref,
        source_kind: "archive"
      )

      assert {:error, %Ecto.ConstraintError{}} = Ingest.ingest(archive, blob: [root: blob_root])
      assert Blob.exists?(archive_ref, root: blob_root)
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

  defp insert_skill!(attrs) do
    name = Keyword.fetch!(attrs, :name)
    content = Keyword.get(attrs, :content, "# #{name}")

    defaults = %{
      id: Keyword.fetch!(attrs, :id),
      slug: Keyword.fetch!(attrs, :slug),
      name: name,
      description: Keyword.get(attrs, :description, ""),
      tags: Keyword.get(attrs, :tags, []),
      content: content,
      content_hash: Keyword.get(attrs, :content_hash, sha256(content)),
      enabled: true,
      archive_ref: Keyword.get(attrs, :archive_ref),
      source_kind: Keyword.get(attrs, :source_kind)
    }

    %Skill{}
    |> Skill.changeset(defaults)
    |> Repo.insert!()
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp sha256_stream(stream) do
    stream
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
