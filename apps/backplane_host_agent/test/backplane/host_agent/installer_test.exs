defmodule Backplane.HostAgent.InstallerTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Installer

  @tag :tmp_dir
  test "installs validated extracted skill into existing target root", %{tmp_dir: tmp_dir} do
    source = skill_source(tmp_dir, "repo-review", "# Repo Review")
    target = Path.join(tmp_dir, "target")
    File.mkdir_p!(target)

    skill = %{"slug" => "repo-review", "targets" => ["agents"]}
    targets = [%{name: "agents", path: target, enabled: true}]

    assert {:ok, ["agents"]} = Installer.install_extracted(source, skill, targets)
    assert File.read!(Path.join([target, "repo-review", "SKILL.md"])) == "# Repo Review"
  end

  @tag :tmp_dir
  test "reports target missing when target is not configured", %{tmp_dir: tmp_dir} do
    source = skill_source(tmp_dir, "repo-review", "# Repo Review")
    target = Path.join(tmp_dir, "target")
    File.mkdir_p!(target)

    skill = %{"slug" => "repo-review", "targets" => ["agents"]}
    targets = [%{name: "codex", path: target, enabled: true}]

    assert {:error, {:target_missing, "agents"}} =
             Installer.install_extracted(source, skill, targets)
  end

  @tag :tmp_dir
  test "reports target missing when target root is missing", %{tmp_dir: tmp_dir} do
    source = skill_source(tmp_dir, "repo-review", "# Repo Review")

    skill = %{"slug" => "repo-review", "targets" => ["agents"]}
    targets = [%{name: "agents", path: Path.join(tmp_dir, "missing"), enabled: true}]

    assert {:error, {:target_missing, "agents"}} =
             Installer.install_extracted(source, skill, targets)
  end

  @tag :tmp_dir
  test "preflights all target roots before installing any target", %{tmp_dir: tmp_dir} do
    source = skill_source(tmp_dir, "repo-review", "# Repo Review")
    agents = Path.join(tmp_dir, "agents")
    File.mkdir_p!(agents)

    skill = %{"slug" => "repo-review", "targets" => ["agents", "codex"]}

    targets = [
      %{name: "agents", path: agents, enabled: true},
      %{name: "codex", path: Path.join(tmp_dir, "missing-codex"), enabled: true}
    ]

    assert {:error, {:target_missing, "codex"}} =
             Installer.install_extracted(source, skill, targets)

    refute File.exists?(Path.join([agents, "repo-review"]))
  end

  @tag :tmp_dir
  test "skips disabled configured target", %{tmp_dir: tmp_dir} do
    source = skill_source(tmp_dir, "repo-review", "# Repo Review")
    target = Path.join(tmp_dir, "target")
    File.mkdir_p!(target)

    skill = %{"slug" => "repo-review", "targets" => ["agents"]}
    targets = [%{name: "agents", path: target, enabled: false}]

    assert {:ok, []} = Installer.install_extracted(source, skill, targets)
    refute File.exists?(Path.join([target, "repo-review"]))
  end

  @tag :tmp_dir
  test "replaces existing install with valid source", %{tmp_dir: tmp_dir} do
    source = skill_source(tmp_dir, "repo-review", "# New Repo Review")
    target = Path.join(tmp_dir, "target")
    existing = Path.join([target, "repo-review"])
    File.mkdir_p!(existing)
    File.write!(Path.join(existing, "SKILL.md"), "# Old Repo Review")
    File.write!(Path.join(existing, "old.txt"), "stale")

    skill = %{"slug" => "repo-review", "targets" => ["agents"]}
    targets = [%{name: "agents", path: target, enabled: true}]

    assert {:ok, ["agents"]} = Installer.install_extracted(source, skill, targets)
    assert File.read!(Path.join(existing, "SKILL.md")) == "# New Repo Review"
    refute File.exists?(Path.join(existing, "old.txt"))
    refute File.exists?(existing <> ".backplane-backup")
  end

  @tag :tmp_dir
  test "does not delete sibling path that looks like an old backup", %{tmp_dir: tmp_dir} do
    source = skill_source(tmp_dir, "repo-review", "# New Repo Review")
    target = Path.join(tmp_dir, "target")
    existing = Path.join([target, "repo-review"])
    sibling = existing <> ".backplane-backup"

    File.mkdir_p!(existing)
    File.write!(Path.join(existing, "SKILL.md"), "# Old Repo Review")
    File.mkdir_p!(sibling)
    File.write!(Path.join(sibling, "SKILL.md"), "# Manual Sibling")

    skill = %{"slug" => "repo-review", "targets" => ["agents"]}
    targets = [%{name: "agents", path: target, enabled: true}]

    assert {:ok, ["agents"]} = Installer.install_extracted(source, skill, targets)
    assert File.read!(Path.join(existing, "SKILL.md")) == "# New Repo Review"
    assert File.read!(Path.join(sibling, "SKILL.md")) == "# Manual Sibling"
  end

  @tag :tmp_dir
  test "rejects traversal slug before touching target root", %{tmp_dir: tmp_dir} do
    source = skill_source(tmp_dir, "repo-review", "# Repo Review")
    target = Path.join(tmp_dir, "target")
    File.mkdir_p!(target)

    skill = %{"slug" => "../outside", "targets" => ["agents"]}
    targets = [%{name: "agents", path: target, enabled: true}]

    assert {:error, {:invalid_slug, "../outside"}} =
             Installer.install_extracted(source, skill, targets)

    refute File.exists?(Path.join(tmp_dir, "outside"))
    assert File.ls!(target) == []
  end

  @tag :tmp_dir
  test "rejects non canonical slug before touching target root", %{tmp_dir: tmp_dir} do
    source = skill_source(tmp_dir, "repo-review", "# Repo Review")
    target = Path.join(tmp_dir, "target")
    File.mkdir_p!(target)

    skill = %{"slug" => "repo_review.backplane-backup", "targets" => ["agents"]}
    targets = [%{name: "agents", path: target, enabled: true}]

    assert {:error, {:invalid_slug, "repo_review.backplane-backup"}} =
             Installer.install_extracted(source, skill, targets)

    assert File.ls!(target) == []
  end

  defp skill_source(tmp_dir, slug, skill_md) do
    source = Path.join([tmp_dir, "source", slug])

    File.mkdir_p!(source)
    File.write!(Path.join(source, "SKILL.md"), skill_md)

    source
  end
end
