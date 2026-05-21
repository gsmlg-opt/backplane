defmodule Backplane.Tools.SkillTest do
  use Backplane.DataCase, async: false

  import Backplane.SkillArchiveCase

  alias Backplane.Skills
  alias Backplane.Skills.Registry
  alias Backplane.Fixtures
  alias Backplane.Tools.Skill, as: SkillTool

  @moduletag :tmp_dir
  @blob_setting "skills.blob.local_root"
  @max_archive_setting "skills.archive.max_bytes"

  setup %{tmp_dir: tmp_dir} do
    previous_blob_root = Backplane.Settings.get(@blob_setting)
    previous_max_archive_bytes = Backplane.Settings.get(@max_archive_setting)
    :ets.insert(:backplane_settings, {@blob_setting, Path.join(tmp_dir, "blobs")})
    Registry.refresh()

    on_exit(fn ->
      :ets.insert(:backplane_settings, {@blob_setting, previous_blob_root})
      :ets.insert(:backplane_settings, {@max_archive_setting, previous_max_archive_bytes})
    end)

    :ok
  end

  describe "tool registration" do
    test "exposes v1 archive tools without legacy create/update tools" do
      tools = SkillTool.tools()
      names = Enum.map(tools, & &1.name)

      assert "skill::list" in names
      assert "skill::search" in names
      assert "skill::load" in names
      assert "skill::download" in names
      assert "skill::publish" in names
      refute "skill::create" in names
      refute "skill::update" in names
      refute "skill::versions" in names

      assert %{input_schema: %{"required" => ["slug"]}} =
               Enum.find(tools, &(&1.name == "skill::load"))

      load_schema = Enum.find(tools, &(&1.name == "skill::load")).input_schema
      refute Map.has_key?(load_schema["properties"], "skill_id")

      for tool_name <- ["skill::list", "skill::search"] do
        schema = Enum.find(tools, &(&1.name == tool_name)).input_schema
        assert schema["properties"]["limit"]["minimum"] == 1
        assert schema["properties"]["limit"]["maximum"] == 100
      end
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

    test "omits legacy database skills without archive refs", %{tmp_dir: tmp_dir} do
      Fixtures.insert_skill(name: "Legacy Skill", slug: "legacy-skill", source_kind: "database")
      archive_skill!(tmp_dir, "archive-list-skill", name: "Archive List Skill")

      assert {:ok, [%{slug: "archive-list-skill"}]} = SkillTool.call(%{"_handler" => "list"})
    end

    test "clamps direct handler limit to at least one", %{tmp_dir: tmp_dir} do
      archive_skill!(tmp_dir, "first-list-skill", name: "First List Skill")
      archive_skill!(tmp_dir, "second-list-skill", name: "Second List Skill")

      assert {:ok, [_skill]} = SkillTool.call(%{"_handler" => "list", "limit" => -10})
      assert {:ok, [_skill]} = SkillTool.call(%{"_handler" => "list", "limit" => 0})
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

    test "omits legacy database skills without archive refs", %{tmp_dir: tmp_dir} do
      Fixtures.insert_skill(
        name: "Legacy Search Skill",
        slug: "legacy-search-skill",
        content: "legacy searchable content",
        source_kind: "database"
      )

      archive_skill!(tmp_dir, "archive-search-skill",
        name: "Archive Search Skill",
        description: "searchable archive content"
      )

      assert {:ok, [%{slug: "archive-search-skill"}]} =
               SkillTool.call(%{"_handler" => "search", "query" => "searchable"})
    end

    test "returns archive skills when legacy matches exceed the SQL search cap", %{
      tmp_dir: tmp_dir
    } do
      query = "crowdout"
      repeated_query = String.duplicate("#{query} ", 20)

      for index <- 1..101 do
        Fixtures.insert_skill(
          name: "Legacy Crowdout Skill #{index}",
          slug: "legacy-crowdout-skill-#{index}",
          description: repeated_query,
          content: "# Legacy Crowdout Skill #{index}\n\n#{repeated_query}",
          source_kind: "database"
        )
      end

      archive_skill!(tmp_dir, "archive-crowdout-skill",
        name: "Archive Crowdout Skill",
        description: query
      )

      assert {:ok, [%{slug: "archive-crowdout-skill"}]} =
               SkillTool.call(%{"_handler" => "search", "query" => query})
    end

    test "clamps direct handler limit to at least one", %{tmp_dir: tmp_dir} do
      archive_skill!(tmp_dir, "first-search-skill",
        name: "First Search Skill",
        description: "shared searchable content"
      )

      archive_skill!(tmp_dir, "second-search-skill",
        name: "Second Search Skill",
        description: "shared searchable content"
      )

      assert {:ok, [_skill]} =
               SkillTool.call(%{"_handler" => "search", "query" => "searchable", "limit" => -10})

      assert {:ok, [_skill]} =
               SkillTool.call(%{"_handler" => "search", "query" => "searchable", "limit" => 0})
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

    test "rejects legacy database skills" do
      Fixtures.insert_skill(
        name: "Legacy Load Skill",
        slug: "legacy-load-skill",
        source_kind: "database"
      )

      assert {:error, msg} =
               SkillTool.call(%{"_handler" => "load", "slug" => "legacy-load-skill"})

      assert msg =~ "archive-backed"
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

    test "rejects legacy database skills" do
      Fixtures.insert_skill(
        name: "Legacy Download Skill",
        slug: "legacy-download-skill",
        source_kind: "database"
      )

      assert {:error, msg} =
               SkillTool.call(%{"_handler" => "download", "slug" => "legacy-download-skill"})

      assert msg =~ "archive-backed"
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

    test "rejects invalid base64 archives" do
      assert {:error, msg} =
               SkillTool.call(%{"_handler" => "publish", "archive_base64" => "not base64!"})

      assert msg == "Invalid base64 archive"
    end

    test "rejects oversized base64 input before decoding" do
      :ets.insert(:backplane_settings, {@max_archive_setting, 1})

      archive_base64 = Base.encode64(:binary.copy(<<0>>, 12))

      assert {:error, msg} =
               SkillTool.call(%{"_handler" => "publish", "archive_base64" => archive_base64})

      assert msg =~ "exceeds maximum archive size"
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
