defmodule Backplane.Tools.SkillTest do
  use Backplane.DataCase, async: false

  import Backplane.SkillArchiveCase

  alias Backplane.Skills
  alias Backplane.Skills.Registry
  alias Backplane.Tools.Skill, as: SkillTool

  @moduletag :tmp_dir
  @blob_setting "skills.blob.local_root"

  setup %{tmp_dir: tmp_dir} do
    previous_blob_root = Backplane.Settings.get(@blob_setting)
    :ets.insert(:backplane_settings, {@blob_setting, Path.join(tmp_dir, "blobs")})
    Registry.refresh()

    on_exit(fn ->
      :ets.insert(:backplane_settings, {@blob_setting, previous_blob_root})
    end)

    :ok
  end

  describe "tool registration" do
    test "exposes v1 archive tools without legacy create/update tools" do
      names = SkillTool.tools() |> Enum.map(& &1.name)

      assert "skill::list" in names
      assert "skill::search" in names
      assert "skill::load" in names
      assert "skill::download" in names
      assert "skill::publish" in names
      refute "skill::create" in names
      refute "skill::update" in names
      refute "skill::versions" in names
    end
  end

  describe "skill::list" do
    test "returns metadata without content", %{tmp_dir: tmp_dir} do
      archive_skill!(tmp_dir, "listable-skill", name: "Listable Skill")

      assert {:ok, [skill]} = SkillTool.call(%{"_handler" => "list"})
      assert skill.slug == "listable-skill"
      assert skill.name == "Listable Skill"
      assert skill.content_hash
      assert skill.size_bytes > 0
      refute Map.has_key?(skill, :content)
      refute Map.has_key?(skill, "content")
    end
  end

  describe "skill::search" do
    test "supports query, tags, and limit", %{tmp_dir: tmp_dir} do
      archive_skill!(tmp_dir, "alpha-skill", name: "Alpha Skill", tags: ["archive", "alpha"])
      archive_skill!(tmp_dir, "beta-skill", name: "Beta Skill", tags: ["archive", "beta"])

      assert {:ok, [%{slug: "alpha-skill"} = result]} =
               SkillTool.call(%{
                 "_handler" => "search",
                 "query" => "skill",
                 "tags" => ["alpha"],
                 "limit" => 1
               })

      assert result.tags == ["archive", "alpha"]
      refute Map.has_key?(result, :content)
    end
  end

  describe "skill::load" do
    test "accepts slug and returns skill content, meta, files, and archive metadata", %{
      tmp_dir: tmp_dir
    } do
      archive =
        archive_skill!(tmp_dir, "loadable-skill",
          name: "Loadable Skill",
          meta: %{"channel" => "stable"},
          entries: [{"loadable-skill/README.md", "extra docs"}]
        )

      assert {:ok, result} =
               SkillTool.call(%{"_handler" => "load", "slug" => "loadable-skill"})

      assert result.slug == "loadable-skill"
      assert result.name == "Loadable Skill"
      assert result.skill_md =~ "# Loadable Skill"
      assert result.meta_json == %{"slug" => "loadable-skill", "channel" => "stable"}
      assert result.files == ["README.md", "SKILL.md", "meta.json"]
      assert result.content_hash == sha256_file(archive)
      assert result.archive_ref =~ ~r/^sha256\/[a-f0-9]{64}\.tar\.gz$/
      assert result.size_bytes == File.stat!(archive).size
      assert result.file_count == 3
      refute Map.has_key?(result, :content)
    end

    test "returns an error for a missing slug" do
      assert {:error, msg} = SkillTool.call(%{"_handler" => "load", "slug" => "missing"})
      assert msg =~ "not found"
    end
  end

  describe "skill::download" do
    test "returns archive URL, hash, size, and metadata", %{tmp_dir: tmp_dir} do
      archive =
        archive_skill!(tmp_dir, "downloadable-skill",
          name: "Downloadable Skill",
          tags: ["archive", "download"]
        )

      assert {:ok, result} =
               SkillTool.call(%{"_handler" => "download", "slug" => "downloadable-skill"})

      assert result.archive_url == "/api/skills/downloadable-skill/archive"
      assert result.content_hash == sha256_file(archive)
      assert result.size_bytes == File.stat!(archive).size
      assert result.metadata.slug == "downloadable-skill"
      assert result.metadata.name == "Downloadable Skill"
      assert result.metadata.tags == ["archive", "download"]
      refute Map.has_key?(result.metadata, :content)
    end
  end

  describe "skill::publish" do
    test "accepts a base64 tar.gz archive and ingests it", %{tmp_dir: tmp_dir} do
      archive =
        create_skill_archive!(tmp_dir, "published-skill",
          name: "Published Skill",
          tags: ["archive", "publish"]
        )

      assert {:ok, result} =
               SkillTool.call(%{
                 "_handler" => "publish",
                 "archive_base64" => Base.encode64(File.read!(archive))
               })

      assert result.slug == "published-skill"
      assert result.name == "Published Skill"
      assert result.content_hash == sha256_file(archive)
      assert result.size_bytes == File.stat!(archive).size
      assert {:ok, skill} = Skills.get_by_slug("published-skill")
      assert skill.archive_ref == result.archive_ref
    end
  end

  describe "unknown handler" do
    test "returns error for unknown handler" do
      assert {:error, msg} = SkillTool.call(%{"unknown" => "handler"})
      assert msg =~ "Unknown skill tool handler"
    end
  end

  defp archive_skill!(tmp_dir, slug, attrs) do
    archive = create_skill_archive!(tmp_dir, slug, attrs)
    assert {:ok, _skill} = Skills.ingest_archive(archive, [])
    archive
  end

  defp create_skill_archive!(tmp_dir, slug, attrs) do
    meta =
      attrs
      |> Keyword.get(:meta, %{})
      |> Map.put("slug", slug)

    create_archive!(
      tmp_dir,
      [
        {"#{slug}/SKILL.md", skill_content(attrs)},
        {"#{slug}/meta.json", Jason.encode!(meta)}
      ] ++ Keyword.get(attrs, :entries, []),
      name: "#{slug}.tar.gz"
    )
  end

  defp skill_content(attrs) do
    name = Keyword.get(attrs, :name, "Example Skill")
    description = Keyword.get(attrs, :description, "Example skill")
    version = Keyword.get(attrs, :version, "1.2.3")
    tags = attrs |> Keyword.get(:tags, ["archive", "test"]) |> Enum.join(", ")

    """
    ---
    name: #{name}
    description: #{description}
    tags: [#{tags}]
    version: "#{version}"
    ---

    # #{name}

    Use this skill in MCP tool tests.
    """
  end

  defp sha256_file(path) do
    path
    |> File.stream!([], 2048)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
