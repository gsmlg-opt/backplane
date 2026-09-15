defmodule Backplane.SkillProtocol.ArchiveHelpers do
  def skill_md(name \\ "example-skill", extra \\ "") do
    """
    ---
    name: #{name}
    description: Example skill
    #{extra}---
    # #{name}

    Read bundled resources without executing them.
    """
  end

  def archive!(tmp_dir, entries, name \\ "bundle.tar.gz") do
    path = Path.join(tmp_dir, name)
    tar_entries = Enum.map(entries, fn {entry, bytes} -> {String.to_charlist(entry), bytes} end)
    :ok = :erl_tar.create(String.to_charlist(path), tar_entries, [:compressed])
    path
  end

  def symlink_archive!(tmp_dir) do
    stage = Path.join(tmp_dir, "symlink-stage")
    archive = Path.join(tmp_dir, "symlink.tar.gz")
    File.mkdir_p!(Path.join(stage, "example-skill"))
    File.write!(Path.join(stage, "example-skill/SKILL.md"), skill_md())
    File.ln_s!("SKILL.md", Path.join(stage, "example-skill/link"))

    File.cd!(stage, fn ->
      :ok =
        :erl_tar.create(
          String.to_charlist(archive),
          [~c"example-skill/SKILL.md", ~c"example-skill/link"],
          [:compressed]
        )
    end)

    archive
  end

  def hardlink_archive!(tmp_dir) do
    stage = Path.join(tmp_dir, "hardlink-stage")
    root = Path.join(stage, "example-skill")
    archive = Path.join(tmp_dir, "hardlink.tar.gz")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "SKILL.md"), skill_md())
    File.write!(Path.join(root, "target"), "hardlink target")
    File.ln!(Path.join(root, "target"), Path.join(root, "link"))

    create_filesystem_archive!(archive, stage, ["example-skill"])
  end

  def character_device_archive!(tmp_dir) do
    stage = Path.join(tmp_dir, "device-stage")
    root = Path.join(stage, "example-skill")
    archive = Path.join(tmp_dir, "character-device.tar.gz")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "SKILL.md"), skill_md())

    create_filesystem_archive!(archive, stage, ["example-skill", "-C", "/dev", "null"])
  end

  defp create_filesystem_archive!(archive, stage, entries) do
    tar = System.find_executable("tar") || raise "tar executable is required for archive fixtures"

    {_output, 0} =
      System.cmd(
        tar,
        ["--format", "ustar", "-czf", archive, "-C", stage | entries],
        stderr_to_stdout: true
      )

    archive
  end
end
