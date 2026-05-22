defmodule Backplane.HostAgent.SkillBundleTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.SkillBundle

  @tag :tmp_dir
  test "validates extracted root containing SKILL.md", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "repo-review")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "SKILL.md"), "# Repo Review")

    assert {:ok, ^root} = SkillBundle.validate(root)
  end

  @tag :tmp_dir
  test "rejects missing bundle root", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "missing")

    assert {:error, :missing_bundle_root} = SkillBundle.validate(root)
  end

  @tag :tmp_dir
  test "rejects missing SKILL.md", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "bad")
    File.mkdir_p!(root)

    assert {:error, :missing_skill_md} = SkillBundle.validate(root)
  end

  @tag :tmp_dir
  test "rejects symlinks in extracted bundle", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "repo-review")
    outside = Path.join(tmp_dir, "outside.txt")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "SKILL.md"), "# Repo Review")
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(root, "outside-link"))

    assert {:error, {:unsafe_bundle_path, _path}} = SkillBundle.validate(root)
  end

  @tag :tmp_dir
  test "rejects symlinked extracted bundle root", %{tmp_dir: tmp_dir} do
    real_root = Path.join(tmp_dir, "repo-review-real")
    symlink_root = Path.join(tmp_dir, "repo-review")

    File.mkdir_p!(real_root)
    File.write!(Path.join(real_root, "SKILL.md"), "# Repo Review")
    File.ln_s!(real_root, symlink_root)

    assert {:error, {:unsafe_bundle_path, ^symlink_root}} = SkillBundle.validate(symlink_root)
  end
end
