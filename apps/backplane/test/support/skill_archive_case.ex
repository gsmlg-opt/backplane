defmodule Backplane.SkillArchiveCase do
  @moduledoc """
  Helpers for building skill archives in tests.
  """

  def skill_md(attrs \\ []) do
    name = Keyword.get(attrs, :name, "example-skill")
    description = Keyword.get(attrs, :description, "Example skill")
    version = Keyword.get(attrs, :version, "1.2.3")

    """
    ---
    name: #{name}
    description: #{description}
    tags: [archive, test]
    version: "#{version}"
    ---

    # #{name}

    Use this skill in archive tests.
    """
  end

  def create_archive!(tmp_dir, entries, opts \\ []) do
    archive_path = Path.join(tmp_dir, Keyword.get(opts, :name, "skill.tar.gz"))

    tar_entries =
      Enum.map(entries, fn {path, content} ->
        {String.to_charlist(path), IO.iodata_to_binary(content)}
      end)

    :ok = :erl_tar.create(String.to_charlist(archive_path), tar_entries, [:compressed])
    archive_path
  end

  def create_symlink_archive!(tmp_dir) do
    stage_dir = Path.join(tmp_dir, "stage")
    archive_path = Path.join(tmp_dir, "symlink-skill.tar.gz")

    File.mkdir_p!(Path.join(stage_dir, "skill"))
    File.write!(Path.join(stage_dir, "skill/SKILL.md"), skill_md())
    File.ln_s!("SKILL.md", Path.join(stage_dir, "skill/link.md"))

    File.cd!(stage_dir, fn ->
      :ok =
        :erl_tar.create(
          String.to_charlist(archive_path),
          [~c"skill/SKILL.md", ~c"skill/link.md"],
          [:compressed]
        )
    end)

    archive_path
  end
end
