defmodule Backplane.Plugins.SyncTest do
  use BackplanePlugins.DataCase, async: false
  alias Backplane.Plugins
  alias Backplane.PluginProtocol.Archive

  setup do
    directory = Path.join(System.tmp_dir!(), "plugin-source-test-" <> Ecto.UUID.generate())
    File.mkdir_p!(directory)
    git!(directory, ["init", "--quiet"])
    git!(directory, ["config", "user.name", "Plugin test"])
    git!(directory, ["config", "user.email", "plugins@example.test"])
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  test "root and subdir imports pin one commit and preserve old release on invalid update", %{
    directory: directory
  } do
    write_plugin(directory, "nested", "old")
    File.mkdir_p!(Path.join(directory, "nested/scripts"))
    File.write!(Path.join(directory, "nested/scripts/run.sh"), "#!/bin/sh\necho pinned")
    File.chmod!(Path.join(directory, "nested/scripts/run.sh"), 0o755)
    old_commit = commit!(directory)

    {:ok, source} =
      Plugins.create_source(%{
        name: "fixture",
        url: directory,
        path: "nested",
        auto_publish: true
      })

    assert {:ok, %{releases: [old], source: synced}} =
             Plugins.sync_source(source.id, allow_local: true)

    assert old.source_commit == old_commit
    {:ok, %{modes: modes}} = Archive.unpack_with_metadata(old.artifact)
    assert modes["scripts/run.sh"] == 0o755
    assert synced.last_success_at
    write_plugin(directory, "nested", "new")
    new_commit = commit!(directory)
    assert {:ok, %{releases: [new]}} = Plugins.sync_source(source.id, allow_local: true)
    assert new.source_commit == new_commit
    assert old.id != new.id
    assert {:ok, bytes} = Plugins.artifact(old.plugin_id, old.id)
    assert {:ok, files} = Archive.unpack(bytes)
    assert files["assets/resource.txt"] == "old"
    File.write!(Path.join(directory, "nested/plugin.json"), "invalid")
    commit!(directory)

    assert {:ok, %{diagnostics: [_], source: failed}} =
             Plugins.sync_source(source.id, allow_local: true)

    assert failed.status == "partial"
    assert failed.last_success_at
    assert {:ok, current} = Plugins.resolve(old.plugin_id)
    assert current.release_id == new.id
    assert {:ok, _} = Plugins.artifact(old.plugin_id, old.id)
  end

  test "marketplace records catalog and independent remote plugin commits and allows partial failure",
       %{directory: directory} do
    remote = directory <> "-remote"
    File.mkdir_p!(remote)
    on_exit(fn -> File.rm_rf!(remote) end)
    git!(remote, ["init", "--quiet"])
    git!(remote, ["config", "user.name", "Plugin test"])
    git!(remote, ["config", "user.email", "plugins@example.test"])
    write_plugin(remote, "", "remote pinned")
    remote_commit = commit!(remote)
    write_plugin(directory, "local", "catalog local")

    marketplace = %{
      "name" => "fixture",
      "plugins" => [
        %{"name" => "local", "source" => %{"source" => "local", "path" => "./local"}},
        %{
          "name" => "remote",
          "source" => %{"source" => "url", "url" => remote, "sha" => remote_commit}
        },
        %{"name" => "missing", "source" => "./missing"}
      ]
    }

    File.mkdir_p!(Path.join(directory, ".agents/plugins"))

    File.write!(
      Path.join(directory, ".agents/plugins/marketplace.json"),
      Jason.encode!(marketplace)
    )

    catalog_commit = commit!(directory)

    {:ok, source} =
      Plugins.create_source(%{
        name: "market",
        url: directory,
        kind: "marketplace",
        auto_publish: true
      })

    assert {:ok, %{releases: releases, diagnostics: [_], source: synced}} =
             Plugins.sync_source(source.id, allow_local: true)

    assert length(releases) == 2
    assert synced.source_commit == catalog_commit
    remote_release = Enum.find(releases, &(&1.source_commit == remote_commit))
    assert remote_release.provenance["catalog_commit"] == catalog_commit
    assert remote_release.source_path == "."
    assert length(Plugins.catalog().data) == 2
  end

  test "fetch failures retain prior success and published content", %{directory: directory} do
    write_plugin(directory, "", "available")
    commit!(directory)
    {:ok, source} = Plugins.create_source(%{name: "root", url: directory, auto_publish: true})

    {:ok, %{releases: [release], source: synced}} =
      Plugins.sync_source(source.id, allow_local: true)

    {:ok, source} = Plugins.update_source(synced, %{ref: "missing-ref"})
    assert {:error, {:git_failed, _}} = Plugins.sync_source(source.id, allow_local: true)
    failed = Plugins.get_source(source.id)
    assert failed.last_success_at == synced.last_success_at
    assert failed.source_commit == synced.source_commit
    assert failed.status == "failed"
    assert {:ok, _} = Plugins.artifact(release.plugin_id, release.id)
  end

  test "Git marketplace publishing writes only an explicitly selected local fixture repository",
       %{directory: directory} do
    File.write!(Path.join(directory, "README.md"), "Fixture remains available")
    commit!(directory)
    branch = git!(directory, ["branch", "--show-current"]) |> String.trim()
    remote = directory <> "-bare"

    {_, 0} =
      System.cmd("git", ["clone", "--quiet", "--bare", directory, remote], stderr_to_stdout: true)

    on_exit(fn -> File.rm_rf!(remote) end)

    manifest =
      Jason.encode!(%{
        "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
        "name" => "published"
      })

    {:ok, release} = Plugins.import_files(%{"plugin.json" => manifest, "assets/data" => "exact"})
    {:ok, _} = Plugins.publish_release(release.id)

    assert {:ok, %{commit: commit, releases: [mapping]}} =
             Plugins.Codex.publish_git(%{url: remote, branch: branch}, allow_local: true)

    assert git!(remote, ["show", commit <> ":" <> mapping.path <> "/plugin.json"]) == manifest
    assert git!(remote, ["show", commit <> ":" <> mapping.path <> "/assets/data"]) == "exact"
    assert git!(remote, ["show", commit <> ":README.md"]) == "Fixture remains available"
  end

  test "Git marketplace publishing rejects tracked symlink ancestors", %{directory: directory} do
    File.ln_s!(System.tmp_dir!(), Path.join(directory, "plugins"))
    commit!(directory)
    branch = git!(directory, ["branch", "--show-current"]) |> String.trim()

    {:ok, release} =
      Plugins.import_files(%{
        "plugin.json" =>
          Jason.encode!(%{
            "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
            "name" => "safe"
          })
      })

    {:ok, _} = Plugins.publish_release(release.id)

    assert {:error, :unsafe_export_path} =
             Plugins.Codex.publish_git(%{url: directory, branch: branch}, allow_local: true)
  end

  test "scheduler attempts due enabled sources and leaves paused sources untouched" do
    {:ok, active} =
      Plugins.create_source(%{name: "scheduled", url: "invalid-source", interval_seconds: 60})

    {:ok, paused} =
      Plugins.create_source(%{name: "paused", url: "invalid-source", enabled: false})

    scheduler = start_supervised!(Backplane.Plugins.Scheduler)
    send(scheduler, :tick)
    assert eventually(fn -> Plugins.get_source(active.id).status == "failed" end)
    assert Plugins.get_source(active.id).last_attempt_at
    assert Plugins.get_source(paused.id).last_attempt_at == nil
  end

  test "malformed marketplace entries keep valid imports and safe persistent diagnostics", %{
    directory: directory
  } do
    write_plugin(directory, "valid", "original")
    write_marketplace(directory, [%{"name" => "valid", "source" => "./valid"}])
    commit!(directory)

    {:ok, source} =
      Plugins.create_source(%{
        name: "mixed",
        url: directory,
        kind: "marketplace",
        auto_publish: true
      })

    {:ok, %{releases: [previous], source: synced}} =
      Plugins.sync_source(source.id, allow_local: true)

    write_plugin(directory, "valid", "updated")

    invalid = [
      "private-invalid-entry",
      [],
      nil,
      %{"name" => [], "source" => "./valid"},
      %{"id" => %{}, "source" => "./valid"},
      %{"id" => "../private-invalid-entry", "source" => "./valid"},
      %{"source" => nil},
      %{},
      %{"source" => %{"source" => "github", "repo" => []}},
      %{"source" => %{"source" => "url", "url" => []}},
      %{"source" => %{"source" => "url", "url" => directory, "ref" => %{}}},
      %{"source" => %{"source" => "local", "path" => []}},
      %{"source" => "../valid"},
      %{"source" => "/valid"},
      %{"source" => "valid/../valid"},
      %{"source" => "valid//nested"},
      %{"source" => "C:/valid"},
      %{"source" => "valid\\nested"},
      %{"source" => "valid" <> <<0>>}
    ]

    healthy = %{
      "name" => "valid",
      "source" => %{
        "source" => "local",
        "path" => "./valid",
        "repo" => [],
        "url" => %{"token" => "private-invalid-entry"}
      }
    }

    write_marketplace(directory, invalid ++ [healthy])
    commit!(directory)

    assert {:ok, %{releases: [current], diagnostics: diagnostics, source: partial}} =
             Plugins.sync_source(source.id, allow_local: true)

    assert length(diagnostics) == length(invalid)
    assert partial.status == "partial"
    assert partial.last_attempt_at
    assert partial.last_success_at == synced.last_success_at
    assert Plugins.get_source(source.id).diagnostics == diagnostics
    refute Jason.encode!(diagnostics) =~ "private-invalid-entry"
    refute Jason.encode!(current.provenance) =~ "private-invalid-entry"
    assert current.plugin_id == previous.plugin_id
    assert {:ok, _} = Plugins.artifact(previous.plugin_id, previous.id)
    assert {:ok, selected} = Plugins.resolve(previous.plugin_id)
    assert selected.release_id == current.id
  end

  test "invalid marketplace top levels preserve last success and prior release", %{
    directory: directory
  } do
    write_plugin(directory, "valid", "available")
    write_marketplace(directory, [%{"name" => "valid", "source" => "valid"}])
    commit!(directory)

    {:ok, source} =
      Plugins.create_source(%{
        name: "top-level",
        url: directory,
        kind: "marketplace",
        auto_publish: true
      })

    {:ok, %{releases: [previous], source: synced}} =
      Plugins.sync_source(source.id, allow_local: true)

    for top_level <- [
          nil,
          [],
          %{"plugins" => []},
          %{"name" => nil, "plugins" => []},
          %{"name" => "fixture", "plugins" => nil},
          %{"name" => "fixture", "plugins" => %{}},
          %{"name" => "fixture", "plugins" => "invalid"}
        ] do
      File.write!(
        Path.join(directory, ".agents/plugins/marketplace.json"),
        Jason.encode!(top_level)
      )

      commit!(directory)
      assert {:error, :invalid_marketplace} = Plugins.sync_source(source.id, allow_local: true)
      failed = Plugins.get_source(source.id)
      assert failed.status == "failed"
      assert failed.last_attempt_at
      assert failed.last_success_at == synced.last_success_at
      assert failed.source_commit == synced.source_commit
      assert [_] = failed.diagnostics
      assert {:ok, _} = Plugins.artifact(previous.plugin_id, previous.id)
    end
  end

  test "dot roots normalize and harmless double dots remain valid relative names", %{
    directory: directory
  } do
    write_plugin(directory, "", "root")
    write_plugin(directory, "foo..bar", "subdirectory")
    commit!(directory)

    for path <- [".", "./", "", "foo..bar", "./foo..bar/"] do
      {:ok, source} = Plugins.create_source(%{name: "normalized", url: directory, path: path})

      assert {:ok, %{releases: [release], diagnostics: []}} =
               Plugins.sync_source(source.id, allow_local: true)

      assert {:ok, package} = Archive.unpack(release.artifact)
      expected = if String.contains?(path, "foo..bar"), do: "subdirectory", else: "root"
      assert package["assets/resource.txt"] == expected
    end
  end

  defp write_marketplace(directory, entries) do
    File.mkdir_p!(Path.join(directory, ".agents/plugins"))

    File.write!(
      Path.join(directory, ".agents/plugins/marketplace.json"),
      Jason.encode!(%{"name" => "fixture", "plugins" => entries})
    )
  end

  defp eventually(check, remaining \\ 100)
  defp eventually(check, 0), do: check.()

  defp eventually(check, remaining) do
    if check.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(check, remaining - 1)
        )
  end

  defp write_plugin(directory, path, content) do
    root = Path.join(directory, path)
    File.mkdir_p!(Path.join(root, "assets"))

    File.write!(
      Path.join(root, "plugin.json"),
      Jason.encode!(%{
        "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
        "name" => "example"
      })
    )

    File.write!(Path.join(root, "assets/resource.txt"), content)
  end

  defp commit!(directory) do
    git!(directory, ["add", "--force", "."])
    git!(directory, ["commit", "--quiet", "-m", "fixture"])
    git!(directory, ["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git!(directory, args) do
    {output, 0} = System.cmd("git", ["-C", directory | args], stderr_to_stdout: true)
    output
  end
end
