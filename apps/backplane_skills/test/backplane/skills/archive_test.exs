defmodule Backplane.Skills.ArchiveTest do
  use ExUnit.Case, async: true

  import Backplane.SkillArchiveCase

  alias Backplane.Skills.Archive

  @moduletag :tmp_dir

  describe "inspect/2" do
    test "accepts a .tar.gz directory containing SKILL.md", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"example-skill/SKILL.md", skill_md(name: "archive-reader")},
          {"example-skill/README.md", "# Extra notes\n"}
        ])

      assert {:ok, result} = Archive.inspect(archive)
      assert result.skill_md =~ "name: archive-reader"
      assert result.skill_entry.name == "archive-reader"
      assert result.skill_entry.version == "1.2.3"
      assert result.meta == %{}
      assert result.file_count == 2
      assert result.size_bytes == File.stat!(archive).size
    end

    test "reads optional meta.json", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/meta.json", Jason.encode!(%{"license" => "MIT", "levels" => [1, 2]})}
        ])

      assert {:ok, result} = Archive.inspect(archive)
      assert result.meta == %{"license" => "MIT", "levels" => [1, 2]}
    end

    test "returns the file list relative to the skill root", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/docs/guide.md", "# Guide\n"},
          {"example-skill/lib/helper.ex", "defmodule Helper, do: :ok\n"}
        ])

      assert {:ok, result} = Archive.inspect(archive)
      assert result.files == ["SKILL.md", "docs/guide.md", "lib/helper.ex"]
    end

    test "rejects missing SKILL.md", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"example-skill/README.md", "# Missing skill\n"}
        ])

      assert {:error, :missing_skill_md} = Archive.inspect(archive)
    end

    test "rejects absolute paths", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"/example-skill/SKILL.md", skill_md()}
        ])

      assert {:error, {:unsafe_path, "/example-skill/SKILL.md"}} = Archive.inspect(archive)
    end

    test "rejects Windows drive absolute paths", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"C:/skill/SKILL.md", skill_md()}
        ])

      assert {:error, {:unsafe_path, "C:/skill/SKILL.md"}} = Archive.inspect(archive)
    end

    test "rejects Windows drive absolute paths with backslashes", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"C:\\skill\\SKILL.md", skill_md()}
        ])

      assert {:error, {:unsafe_path, "C:\\skill\\SKILL.md"}} = Archive.inspect(archive)
    end

    test "rejects nested Windows drive-like path segments", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/C:/x.txt", "suspicious"}
        ])

      assert {:error, {:unsafe_path, "example-skill/C:/x.txt"}} = Archive.inspect(archive)
    end

    test "rejects .. path traversal", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/../outside.txt", "outside"}
        ])

      assert {:error, {:unsafe_path, "example-skill/../outside.txt"}} = Archive.inspect(archive)
    end

    test "rejects percent-encoded traversal-like path segments", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/%2e%2E/x.txt", "suspicious"}
        ])

      assert {:error, {:unsafe_path, "example-skill/%2e%2E/x.txt"}} =
               Archive.inspect(archive)
    end

    test "rejects backslash path traversal", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/..\\outside.txt", "outside"}
        ])

      assert {:error, {:unsafe_path, "example-skill/..\\outside.txt"}} =
               Archive.inspect(archive)
    end

    test "rejects Windows separator path traversal", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill\\..\\outside.txt", "outside"}
        ])

      assert {:error, {:unsafe_path, "example-skill\\..\\outside.txt"}} =
               Archive.inspect(archive)
    end

    test "rejects symlink entries", %{tmp_dir: tmp_dir} do
      archive = create_symlink_archive!(tmp_dir)

      assert {:error, {:unsupported_entry_type, "skill/link.md", :symlink}} =
               Archive.inspect(archive)
    end

    test "rejects archives above configured max file count", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/one.txt", "one"},
          {"example-skill/two.txt", "two"}
        ])

      assert {:error, {:too_many_files, 3, 2}} = Archive.inspect(archive, max_files: 2)
    end

    test "rejects required archive content above configured max bytes", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"example-skill/SKILL.md", skill_md()}
        ])

      assert {:error, {:too_many_bytes, _, 8}} = Archive.inspect(archive, max_bytes: 8)
    end

    test "does not need unrelated payload content for max bytes", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/payload.bin", String.duplicate("x", 2048)}
        ])

      assert {:ok, result} = Archive.inspect(archive, max_bytes: 512)
      assert result.files == ["SKILL.md", "payload.bin"]
      refute Map.has_key?(result, :contents)
    end

    test "rejects malformed meta.json", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/meta.json", "{"}
        ])

      assert {:error, :malformed_meta_json} = Archive.inspect(archive)
    end

    test "rejects non-object meta.json", %{tmp_dir: tmp_dir} do
      archive =
        create_archive!(tmp_dir, [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/meta.json", "[1, 2]"}
        ])

      assert {:error, :malformed_meta_json} = Archive.inspect(archive)
    end

    test "rejects malformed tar or gzip input", %{tmp_dir: tmp_dir} do
      archive = Path.join(tmp_dir, "bad.tar.gz")
      File.write!(archive, "not a tarball")

      assert {:error, _reason} = Archive.inspect(archive)
    end
  end
end
