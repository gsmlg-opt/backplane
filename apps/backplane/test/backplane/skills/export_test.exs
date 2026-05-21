defmodule Backplane.Skills.ExportTest do
  use Backplane.DataCase, async: false

  import Backplane.SkillArchiveCase

  alias Backplane.Repo
  alias Backplane.Skills
  alias Backplane.Skills.Skill

  @moduletag :tmp_dir
  @blob_setting "skills.blob.local_root"

  setup %{tmp_dir: tmp_dir} do
    previous_blob_root = Backplane.Settings.get(@blob_setting)
    blob_root = Path.join(tmp_dir, "blobs")

    :ets.insert(:backplane_settings, {@blob_setting, blob_root})

    on_exit(fn ->
      :ets.insert(:backplane_settings, {@blob_setting, previous_blob_root})
    end)

    {:ok, blob_root: blob_root}
  end

  describe "export/1" do
    test "writes a collection archive with a manifest and unchanged stored archives", %{
      tmp_dir: tmp_dir
    } do
      alpha = ingest_archive!(tmp_dir, "alpha-skill", name: "Alpha Skill")
      beta = ingest_archive!(tmp_dir, "beta-skill", name: "Beta Skill")
      collection = Path.join(tmp_dir, "collection.tar.gz")

      assert {:ok, %{path: ^collection, count: 2}} = Skills.export(path: collection)

      assert {:ok, entries} = extract_collection(collection)

      assert %{
               "manifest.json" => manifest_json,
               "archives/alpha-skill.tar.gz" => alpha_bytes,
               "archives/beta-skill.tar.gz" => beta_bytes
             } = entries

      assert File.read!(alpha) == alpha_bytes
      assert File.read!(beta) == beta_bytes

      assert %{
               "count" => 2,
               "skills" => [
                 %{"slug" => "alpha-skill", "archive_path" => "archives/alpha-skill.tar.gz"},
                 %{"slug" => "beta-skill", "archive_path" => "archives/beta-skill.tar.gz"}
               ]
             } = Jason.decode!(manifest_json)
    end
  end

  describe "import/2" do
    test "ingests every archive and is idempotent for unchanged hashes", %{tmp_dir: tmp_dir} do
      first_archive = ingest_archive!(tmp_dir, "first-skill", name: "First Skill")
      second_archive = ingest_archive!(tmp_dir, "second-skill", name: "Second Skill")
      collection = Path.join(tmp_dir, "collection.tar.gz")

      assert {:ok, %{count: 2}} = Skills.export(path: collection)

      assert {:ok, first} = Skills.get_by_slug("first-skill")
      assert {:ok, second} = Skills.get_by_slug("second-skill")
      original_hashes = {first.content_hash, second.content_hash}

      assert {:ok, _deleted} = Skills.delete(first)
      assert {:ok, _deleted} = Skills.delete(second)
      assert Repo.aggregate(Skill, :count, :id) == 0

      assert {:ok, %{count: 2, skills: imported}} = Skills.import(collection, [])
      assert [%Skill{slug: "first-skill"}, %Skill{slug: "second-skill"}] = imported

      assert {:ok, first_imported} = Skills.get_by_slug("first-skill")
      assert {:ok, second_imported} = Skills.get_by_slug("second-skill")
      assert {first_imported.content_hash, second_imported.content_hash} == original_hashes
      assert first_imported.content_hash == sha256_file(first_archive)
      assert second_imported.content_hash == sha256_file(second_archive)

      assert {:ok, %{count: 2, skills: second_import}} = Skills.import(collection, [])
      assert [%Skill{slug: "first-skill"}, %Skill{slug: "second-skill"}] = second_import
      assert Repo.aggregate(Skill, :count, :id) == 2

      assert {:ok, first_again} = Skills.get_by_slug("first-skill")
      assert {:ok, second_again} = Skills.get_by_slug("second-skill")
      assert first_again.content_hash == first_imported.content_hash
      assert first_again.archive_ref == first_imported.archive_ref
      assert second_again.content_hash == second_imported.content_hash
      assert second_again.archive_ref == second_imported.archive_ref
    end

    test "rejects unsafe collection entry names", %{tmp_dir: tmp_dir} do
      collection =
        create_archive!(
          tmp_dir,
          [
            {"manifest.json", Jason.encode!(%{"count" => 0, "skills" => []})},
            {"archives/../evil.tar.gz", "not a skill archive"}
          ],
          name: "unsafe-collection.tar.gz"
        )

      assert {:error, {:unsafe_path, "archives/../evil.tar.gz"}} =
               Skills.import(collection, [])
    end

    test "rejects unsupported collection paths outside archives", %{tmp_dir: tmp_dir} do
      collection =
        create_archive!(
          tmp_dir,
          [
            {"manifest.json", Jason.encode!(%{"count" => 0, "skills" => []})},
            {"payload.tar.gz", "not a supported collection entry"}
          ],
          name: "unsupported-collection.tar.gz"
        )

      assert {:error, {:unsupported_path, "payload.tar.gz"}} = Skills.import(collection, [])
    end
  end

  defp ingest_archive!(tmp_dir, slug, attrs) do
    archive = create_skill_archive!(tmp_dir, slug, attrs)
    assert {:ok, _skill} = Skills.ingest_archive(archive, [])
    archive
  end

  defp create_skill_archive!(tmp_dir, slug, attrs) do
    create_archive!(
      tmp_dir,
      [
        {"#{slug}/SKILL.md", skill_content(attrs)},
        {"#{slug}/meta.json", Jason.encode!(%{"slug" => slug})}
      ],
      name: "#{slug}.tar.gz"
    )
  end

  defp skill_content(attrs) do
    name = Keyword.get(attrs, :name, "Example Skill")

    """
    ---
    name: #{name}
    description: #{name} description
    tags: [archive, test]
    version: "1.0.0"
    ---

    # #{name}
    """
  end

  defp extract_collection(path) do
    case :erl_tar.extract(String.to_charlist(path), [:compressed, :memory]) do
      {:ok, entries} ->
        entries =
          Map.new(entries, fn {name, content} ->
            {IO.chardata_to_string(name), IO.iodata_to_binary(content)}
          end)

        {:ok, entries}

      {:error, _} = error ->
        error
    end
  end

  defp sha256_file(path) do
    path
    |> File.stream!([], 2048)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
