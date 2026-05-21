defmodule Backplane.Tools.SkillTest do
  use Backplane.DataCase, async: false

  alias Backplane.Settings
  alias Backplane.SkillArchiveCase
  alias Backplane.Skills.Registry
  alias Backplane.Tools.Skill, as: SkillTool

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    :ok = Settings.set("skills.blob.local_root", tmp_dir)

    if :ets.whereis(:backplane_skills) != :undefined do
      :ets.delete_all_objects(:backplane_skills)
    end

    ingest_archive("elixir-patterns", "Elixir Patterns", ["elixir", "otp"])
    ingest_archive("react-guide", "React Guide", ["react"])
    Registry.refresh()

    on_exit(fn ->
      if Process.whereis(Settings), do: Settings.set("skills.blob.local_root", nil)
    end)

    :ok
  end

  test "registers v1 skill tools" do
    names = Enum.map(SkillTool.tools(), & &1.name)

    assert "skill::list" in names
    assert "skill::search" in names
    assert "skill::load" in names
    assert "skill::download" in names
    assert "skill::publish" in names
  end

  describe "skill::list" do
    test "returns metadata without content" do
      {:ok, skills} = SkillTool.call(%{"_handler" => "list"})

      assert Enum.any?(skills, &(&1.slug == "elixir-patterns"))
      refute Enum.any?(skills, &Map.has_key?(&1, :content))
    end

    test "filters by tags" do
      {:ok, skills} = SkillTool.call(%{"_handler" => "list", "tags" => ["otp"]})

      assert Enum.map(skills, & &1.slug) == ["elixir-patterns"]
    end
  end

  describe "skill::search" do
    test "supports query, tags, and limit" do
      {:ok, results} =
        SkillTool.call(%{
          "_handler" => "search",
          "query" => "Elixir",
          "tags" => ["otp"],
          "limit" => 1
        })

      assert [%{slug: "elixir-patterns"}] = results
      refute Map.has_key?(hd(results), :content)
    end
  end

  describe "skill::load" do
    test "accepts slug and returns skill archive context" do
      {:ok, result} = SkillTool.call(%{"_handler" => "load", "slug" => "elixir-patterns"})

      assert result.slug == "elixir-patterns"
      assert result.skill_md =~ "Elixir Patterns"
      assert result.meta["slug"] == "elixir-patterns"
      assert result.meta_json =~ "\"slug\":\"elixir-patterns\""
      assert result.files == ["SKILL.md", "meta.json"]
      assert result.archive.hash == result.content_hash
      assert result.archive.size_bytes == result.size_bytes
    end

    test "returns error for nonexistent slug" do
      {:error, msg} = SkillTool.call(%{"_handler" => "load", "slug" => "missing"})
      assert msg =~ "not found"
    end
  end

  describe "skill::download" do
    test "returns archive URL and metadata" do
      {:ok, result} = SkillTool.call(%{"_handler" => "download", "slug" => "elixir-patterns"})

      assert result.url == "/api/skills/elixir-patterns/archive"
      assert result.hash == result.content_hash
      assert result.size_bytes > 0
      assert result.metadata.slug == "elixir-patterns"
    end
  end

  describe "skill::publish" do
    test "accepts base64 archive and ingests it" do
      archive = archive("published-skill", "Published Skill", ["publish"])

      {:ok, result} =
        SkillTool.call(%{
          "_handler" => "publish",
          "archive_base64" => Base.encode64(archive),
          "filename" => "published-skill.tar.gz"
        })

      assert result.slug == "published-skill"
      assert {:ok, cached} = Registry.fetch("published-skill")
      assert cached.slug == "published-skill"
    end
  end

  describe "unknown handler" do
    test "returns error for unknown handler" do
      {:error, msg} = SkillTool.call(%{"unknown" => "handler"})
      assert msg =~ "Unknown skill tool handler"
    end
  end

  defp ingest_archive(slug, name, tags) do
    {:ok, _skill} =
      slug
      |> archive(name, tags)
      |> Backplane.Skills.ingest_archive(filename: "#{slug}.tar.gz")
  end

  defp archive(slug, name, tags) do
    skill_md = """
    ---
    name: #{name}
    description: #{name} description
    tags: #{inspect(tags)}
    ---

    # #{name}
    """

    SkillArchiveCase.tar_gz([
      {"#{slug}/SKILL.md", skill_md},
      {"#{slug}/meta.json", SkillArchiveCase.meta_json(%{"slug" => slug})}
    ])
  end
end
