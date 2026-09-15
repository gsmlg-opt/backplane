defmodule Backplane.Skills.PublicationTest do
  use BackplaneSkills.DataCase, async: false

  import Backplane.SkillArchiveCase

  alias Backplane.Repo
  alias Backplane.Skills
  alias Backplane.Skills.{Blob, Ingest, Publication, Revision, Skill}

  @moduletag :tmp_dir

  test "published revisions retain exact metadata and bytes across replacement", %{
    tmp_dir: tmp_dir
  } do
    blob_root = Path.join(tmp_dir, "blobs")
    opts = [blob: [root: blob_root]]

    first = archive(tmp_dir, "retained", "Retained A", "A resource", "a.txt")
    assert {:ok, %Skill{current_revision: revision_a}} = Ingest.ingest(first, opts)

    assert {:ok, published_a} = Publication.resolve("skill/retained", revision_a)
    assert published_a.manifest["document_metadata"]["description"] == "A resource"

    assert {:ok, bytes_a} =
             Publication.artifact("skill/retained", revision_a, blob: [root: blob_root])

    second = archive(tmp_dir, "retained", "Retained B", "B resource", "b.txt")
    assert {:ok, %Skill{current_revision: revision_b}} = Ingest.ingest(second, opts)
    refute revision_b == revision_a

    assert {:ok, current} = Publication.resolve("skill/retained")
    assert current.revision == revision_b
    assert current.manifest["document_metadata"]["description"] == "B resource"

    assert {:ok, retained_a} = Publication.resolve("skill/retained", revision_a)
    assert retained_a.manifest == published_a.manifest

    assert Publication.artifact("skill/retained", revision_a, blob: [root: blob_root]) ==
             {:ok, bytes_a}
  end

  test "resolve rejects malformed or empty explicit revisions", %{tmp_dir: tmp_dir} do
    path = archive(tmp_dir, "revision-shape", "Revision shape", "Revision shape", "revision.txt")
    assert {:ok, _skill} = Ingest.ingest(path, blob: [root: Path.join(tmp_dir, "blobs")])
    assert {:error, :invalid_request} = Publication.resolve("skill/revision-shape", [])
    assert {:error, :invalid_request} = Publication.resolve("skill/revision-shape", "")

    assert {:error, :invalid_request} =
             Publication.resolve("skill/revision-shape", %{"old" => true})
  end

  test "publication is idempotent and invalid replacement leaves current unchanged", %{
    tmp_dir: tmp_dir
  } do
    blob_root = Path.join(tmp_dir, "blobs")
    opts = [blob: [root: blob_root]]
    valid = archive(tmp_dir, "stable", "Stable", "Stable description", "stable.txt")

    assert {:ok, %Skill{current_revision: revision}} = Ingest.ingest(valid, opts)
    assert {:ok, %Skill{current_revision: ^revision}} = Ingest.ingest(valid, opts)
    assert revision_count("skill/stable") == 1

    invalid =
      create_archive!(
        tmp_dir,
        [
          {"stable/SKILL.md", skill_md(name: "Stable", description: "")},
          {"stable/new.txt", "new"}
        ],
        name: "invalid.tar.gz"
      )

    assert {:ok, %Skill{} = updated} = Ingest.ingest(invalid, opts)
    assert updated.current_revision == revision
    assert updated.publication_status == "invalid"
    assert updated.publication_diagnostic["code"] in ["invalid_document", "invalid_bundle"]
    assert {:ok, %{revision: ^revision}} = Publication.resolve("skill/stable")
  end

  test "cleanup retains shared and historical blobs until no database reference remains", %{
    tmp_dir: tmp_dir
  } do
    blob_root = Path.join(tmp_dir, "blobs")
    opts = [blob: [root: blob_root]]
    shared = archive(tmp_dir, "shared", "Shared", "Shared description", "same")

    assert {:ok, first} = Ingest.ingest(shared, opts)
    bytes = File.read!(shared)
    assert {:ok, shared_ref} = Blob.put(bytes, root: blob_root)

    second =
      %Skill{}
      |> Skill.changeset(%{
        id: "skill/shared-two",
        slug: "shared-two",
        name: "Shared",
        description: "Shared description",
        content: first.content,
        content_hash: first.content_hash,
        archive_ref: shared_ref,
        source_kind: "archive"
      })
      |> Repo.insert!()

    assert {:ok, _revision} =
             Publication.publish_existing(second, shared, blob: [root: blob_root])

    assert {:ok, _deleted} = Skills.delete(first, blob: [root: blob_root])
    assert Blob.exists?(shared_ref, root: blob_root)
  end

  test "backfill dry-run is non-mutating and apply is idempotent", %{tmp_dir: tmp_dir} do
    blob_root = Path.join(tmp_dir, "blobs")
    valid = archive(tmp_dir, "backfill", "Backfill", "Backfill description", "source")
    assert {:ok, blob_ref} = Blob.put_file(valid, root: blob_root)

    skill =
      %Skill{}
      |> Skill.changeset(%{
        id: "skill/backfill",
        slug: "backfill",
        name: "Backfill",
        description: "Backfill description",
        content: "legacy",
        archive_ref: blob_ref,
        source_kind: "archive"
      })
      |> Repo.insert!()

    assert %{published: [], publishable: [report]} =
             Publication.backfill(dry_run: true, blob: [root: blob_root])

    assert report.skill_id == skill.id
    assert revision_count(skill.id) == 0

    assert %{published: [%{skill_id: "skill/backfill"}]} =
             Publication.backfill(blob: [root: blob_root])

    assert %{unchanged: [%{skill_id: "skill/backfill"}]} =
             Publication.backfill(blob: [root: blob_root])

    assert revision_count(skill.id) == 1
  end

  test "backfill reports absent blobs and records without archives", %{tmp_dir: tmp_dir} do
    missing =
      insert_skill!(%{
        id: "skill/missing-blob",
        slug: "missing-blob",
        archive_ref: "sha256/#{String.duplicate("0", 64)}.tar.gz",
        source_kind: "archive"
      })

    unsupported =
      insert_skill!(%{
        id: "db/unsupported",
        slug: "unsupported",
        archive_ref: nil,
        source_kind: "database"
      })

    report = Publication.backfill(blob: [root: Path.join(tmp_dir, "blobs")])

    assert %{skill_id: missing_id, detail: :missing_blob} =
             Enum.find(report.missing, &(&1.skill_id == missing.id))

    assert missing_id == missing.id

    assert %{skill_id: unsupported_id, detail: :missing_archive} =
             Enum.find(report.unsupported, &(&1.skill_id == unsupported.id))

    assert unsupported_id == unsupported.id
    assert report.published == []
  end

  test "bulk tag changes preserve current and mark publication pending", %{tmp_dir: tmp_dir} do
    blob_root = Path.join(tmp_dir, "blobs")
    path = archive(tmp_dir, "mutable-tags", "Mutable tags", "Original tags", "resource")
    assert {:ok, skill} = Ingest.ingest(path, blob: [root: blob_root])
    revision = skill.current_revision

    assert {1, nil} = Skills.bulk_update_tags([skill.id], ["changed"])
    updated = Repo.reload!(skill)

    assert updated.current_revision == revision
    assert updated.publication_status == "pending"
    assert updated.publication_diagnostic == %{"code" => "publication_pending"}
    assert {:ok, published} = Publication.resolve(skill.id, revision)
    assert published.manifest["document_metadata"]["tags"] == ["archive", "test"]
  end

  test "competing publishers leave a coherent current pointer", %{tmp_dir: tmp_dir} do
    blob_root = Path.join(tmp_dir, "blobs")
    opts = [blob: [root: blob_root]]
    first = archive(tmp_dir, "race", "Race A", "Race A", "a")
    second = archive(tmp_dir, "race", "Race B", "Race B", "b")
    parent = self()

    tasks =
      Enum.map([first, second], fn path ->
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          receive do: (:go -> Ingest.ingest(path, opts))
        end)
      end)

    Enum.each(tasks, &send(&1.pid, :go))
    assert Enum.all?(Task.await_many(tasks), &match?({:ok, %Skill{}}, &1))

    assert {:ok, current} = Publication.resolve("skill/race")
    assert %Revision{} = Repo.get_by(Revision, skill_id: "skill/race", revision: current.revision)
    assert current.manifest["artifact_digest"] == current.artifact_digest

    assert {:ok, _bytes} =
             Publication.artifact("skill/race", current.revision, blob: [root: blob_root])

    assert revision_count("skill/race") == 2
  end

  test "invalid generated content records a diagnostic without a fabricated revision" do
    attrs = %{
      id: "generated/invalid",
      slug: "invalid-generated",
      name: "Invalid Generated",
      description: "",
      content: "# Invalid",
      content_hash: "invalid",
      source_kind: "generated"
    }

    assert {:ok, %Skill{} = skill} = Publication.publish_generated(attrs)
    assert skill.publication_status == "invalid"
    assert skill.current_revision == nil
    assert skill.publication_diagnostic["code"] in ["invalid_document", "invalid_bundle"]
    assert Publication.resolve(skill.id) == {:error, :not_found}
  end

  defp archive(tmp_dir, slug, name, description, resource) do
    create_archive!(
      tmp_dir,
      [
        {"#{slug}/SKILL.md", skill_md(name: slug, description: description)},
        {"#{slug}/resource.txt", resource},
        {"#{slug}/meta.json", Jason.encode!(%{"slug" => slug, "display_name" => name})}
      ],
      name: "#{slug}-#{System.unique_integer([:positive])}.tar.gz"
    )
  end

  defp insert_skill!(attrs) do
    defaults = %{
      name: "Backfill fixture",
      description: "Backfill fixture",
      content: "# Backfill fixture",
      content_hash: "legacy"
    }

    %Skill{}
    |> Skill.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp revision_count(skill_id) do
    Repo.aggregate(from(r in Revision, where: r.skill_id == ^skill_id), :count, :revision)
  end
end
