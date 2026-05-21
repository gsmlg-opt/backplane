defmodule Backplane.Skills.ArchiveTest do
  use ExUnit.Case, async: true

  alias Backplane.SkillArchiveCase
  alias Backplane.Skills.Archive

  test "accepts a tar.gz skill directory containing SKILL.md" do
    archive =
      SkillArchiveCase.tar_gz([
        {"my-skill/", :dir},
        {"my-skill/SKILL.md", SkillArchiveCase.skill_md("my-skill")},
        {"my-skill/scripts/run.sh", "echo ok\n"}
      ])

    assert {:ok, info} = Archive.inspect(archive)
    assert info.skill_entry.name == "my-skill"
    assert info.skill_entry.description == "Archive-backed skill"
    assert info.skill_entry.tags == ["archive", "test"]
    assert info.skill_entry.slug == "my-skill"
    assert info.skill_md =~ "Use this skill"
    assert info.meta == %{}
    assert info.files == ["SKILL.md", "scripts/run.sh"]
    assert info.file_count == 2
    assert info.size_bytes == byte_size(archive)
  end

  test "reads optional meta.json and uses its slug" do
    archive =
      SkillArchiveCase.tar_gz([
        {"folder/SKILL.md", SkillArchiveCase.skill_md("Readable Name")},
        {"folder/meta.json", SkillArchiveCase.meta_json(%{"slug" => "stable-slug"})}
      ])

    assert {:ok, info} = Archive.inspect(archive)
    assert info.meta["version"] == "1.2.0"
    assert info.skill_entry.slug == "stable-slug"
    assert info.files == ["SKILL.md", "meta.json"]
  end

  test "rejects missing SKILL.md" do
    archive = SkillArchiveCase.tar_gz([{"skill/README.md", "missing\n"}])

    assert {:error, :missing_skill_md} = Archive.inspect(archive)
  end

  test "rejects absolute paths" do
    archive =
      SkillArchiveCase.tar_gz([
        {"/tmp/skill/SKILL.md", SkillArchiveCase.skill_md()}
      ])

    assert {:error, :unsafe_path} = Archive.inspect(archive)
  end

  test "rejects path traversal" do
    archive =
      SkillArchiveCase.tar_gz([
        {"skill/SKILL.md", SkillArchiveCase.skill_md()},
        {"skill/../escape.txt", "bad\n"}
      ])

    assert {:error, :unsafe_path} = Archive.inspect(archive)
  end

  test "rejects symlink entries" do
    archive =
      SkillArchiveCase.tar_gz([
        {"skill/SKILL.md", SkillArchiveCase.skill_md()},
        {"skill/link", {:symlink, "SKILL.md"}}
      ])

    assert {:error, :unsupported_entry} = Archive.inspect(archive)
  end

  test "rejects archives above configured max file count" do
    archive =
      SkillArchiveCase.tar_gz([
        {"skill/SKILL.md", SkillArchiveCase.skill_md()},
        {"skill/extra.txt", "extra\n"}
      ])

    assert {:error, :too_many_files} = Archive.inspect(archive, max_files: 1)
  end

  test "rejects malformed meta.json" do
    archive =
      SkillArchiveCase.tar_gz([
        {"skill/SKILL.md", SkillArchiveCase.skill_md()},
        {"skill/meta.json", "{not-json"}
      ])

    assert {:error, :malformed_meta} = Archive.inspect(archive)
  end
end
