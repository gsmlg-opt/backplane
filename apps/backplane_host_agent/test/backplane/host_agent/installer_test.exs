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
  test "downloads verifies extracts and installs assigned archive", %{tmp_dir: tmp_dir} do
    archive = skill_archive(tmp_dir, "repo-review", "# Repo Review")
    checksum = "sha256:" <> sha256_file(archive)
    target = Path.join(tmp_dir, "target")
    work_dir = Path.join(tmp_dir, "work")
    File.mkdir_p!(target)

    skill = %{
      "slug" => "repo-review",
      "checksum" => checksum,
      "targets" => ["agents"],
      "download_url" => "/api/host-agent/skills/repo-review/download"
    }

    config = %{
      hub_url: "http://backplane.test",
      token: "host-token",
      work_dir: work_dir,
      targets: [%{name: "agents", path: target, enabled: true}],
      download_fun: fn url, headers, destination ->
        assert url == "http://backplane.test/api/host-agent/skills/repo-review/download"
        assert headers == [{"X-Backplane-Host-Token", "host-token"}]
        File.cp(archive, destination)
      end
    }

    assert {:ok, ["agents"]} = Installer.install(skill, config)
    assert File.read!(Path.join([target, "repo-review", "SKILL.md"])) == "# Repo Review"
    assert File.ls!(work_dir) == []
  end

  @tag :tmp_dir
  test "does not install archive with mismatched checksum", %{tmp_dir: tmp_dir} do
    archive = skill_archive(tmp_dir, "repo-review", "# Repo Review")
    target = Path.join(tmp_dir, "target")
    File.mkdir_p!(target)

    skill = %{
      "slug" => "repo-review",
      "checksum" => "sha256:" <> String.duplicate("0", 64),
      "targets" => ["agents"],
      "download_url" => "http://backplane.test/archive.tar.gz"
    }

    config = %{
      work_dir: Path.join(tmp_dir, "work"),
      targets: [%{name: "agents", path: target, enabled: true}],
      download_fun: fn _url, _headers, destination -> File.cp(archive, destination) end
    }

    assert {:error, :checksum_mismatch} = Installer.install(skill, config)
    refute File.exists?(Path.join([target, "repo-review"]))
  end

  @tag :tmp_dir
  test "rejects archive entries that escape the skill root", %{tmp_dir: tmp_dir} do
    archive =
      skill_archive_from_entries(tmp_dir, "traversal", [
        {"repo-review/SKILL.md", "# Repo Review"},
        {"../outside.txt", "outside"}
      ])

    target = Path.join(tmp_dir, "target")
    File.mkdir_p!(target)

    assert {:error, {:unsafe_path, "../outside.txt"}} =
             Installer.install(archive_skill(archive), archive_config(tmp_dir, target, archive))

    refute File.exists?(Path.join(tmp_dir, "outside.txt"))
    refute File.exists?(Path.join([target, "repo-review"]))
  end

  @tag :tmp_dir
  test "rejects archive with multiple skill roots", %{tmp_dir: tmp_dir} do
    archive =
      skill_archive_from_entries(tmp_dir, "ambiguous", [
        {"repo-review/SKILL.md", "# Repo Review"},
        {"other-skill/SKILL.md", "# Other Skill"}
      ])

    target = Path.join(tmp_dir, "target")
    File.mkdir_p!(target)

    assert {:error, :ambiguous_skill_md} =
             Installer.install(archive_skill(archive), archive_config(tmp_dir, target, archive))

    assert File.ls!(target) == []
  end

  @tag :tmp_dir
  test "rejects archive without a skill definition", %{tmp_dir: tmp_dir} do
    archive =
      skill_archive_from_entries(tmp_dir, "missing-skill-md", [{"repo-review/README.md", "docs"}])

    target = Path.join(tmp_dir, "target")
    File.mkdir_p!(target)

    assert {:error, :missing_skill_md} =
             Installer.install(archive_skill(archive), archive_config(tmp_dir, target, archive))

    assert File.ls!(target) == []
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

  defp skill_archive(tmp_dir, slug, skill_md) do
    skill_archive_from_entries(tmp_dir, slug, [{"#{slug}/SKILL.md", skill_md}])
  end

  defp skill_archive_from_entries(tmp_dir, name, entries) do
    archive = Path.join(tmp_dir, "#{name}.tar.gz")

    tar_entries =
      Enum.map(entries, fn {path, content} ->
        {String.to_charlist(path), IO.iodata_to_binary(content)}
      end)

    :ok = :erl_tar.create(String.to_charlist(archive), tar_entries, [:compressed])
    archive
  end

  defp archive_skill(archive) do
    %{
      "slug" => "repo-review",
      "checksum" => "sha256:" <> sha256_file(archive),
      "targets" => ["agents"],
      "download_url" => "http://backplane.test/archive.tar.gz"
    }
  end

  defp archive_config(tmp_dir, target, archive) do
    %{
      work_dir: Path.join(tmp_dir, "work"),
      targets: [%{name: "agents", path: target, enabled: true}],
      download_fun: fn _url, _headers, destination -> File.cp(archive, destination) end
    }
  end

  defp sha256_file(path) do
    path
    |> File.stream!([], 2048)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, context ->
      :crypto.hash_update(context, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
