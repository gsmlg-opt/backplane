defmodule Backplane.Plugins.RegistryTest do
  use BackplanePlugins.DataCase, async: false
  alias Backplane.Plugins
  alias Backplane.PluginProtocol.Archive

  defp files(content \\ "original") do
    %{
      "plugin.json" =>
        Jason.encode!(%{
          "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
          "name" => "example",
          "version" => "upstream-custom"
        }),
      "skills/example/SKILL.md" =>
        "---\nname: example\ndescription: Example skill\n---\n\n" <> content,
      "skills/example/scripts/run.sh" => "#!/bin/sh\necho " <> content,
      "assets/example.bin" => <<0, 1, 2>>,
      "mcp.json" =>
        Jason.encode!(%{"mcpServers" => %{"example" => %{"command" => "echo", "args" => ["ok"]}}})
    }
  end

  test "independent identities and immutable releases retain optional upstream metadata and full resources" do
    {:ok, first} =
      Plugins.import_files(files(), %{publisher: "first", source_commit: "commit-one"})

    {:ok, other} = Plugins.import_files(files(), %{publisher: "second"})
    assert first.plugin_id != other.plugin_id
    assert {:error, :not_found} = Plugins.artifact_by_digest(first.artifact_digest)
    {:ok, _} = Plugins.publish_release(first.id)

    {:ok, second} =
      Plugins.import_files(files("updated"), %{publisher: "first", source_commit: "commit-two"})

    {:ok, _} = Plugins.publish_release(second.id)
    assert first.upstream_version == second.upstream_version
    assert {:ok, original} = Plugins.artifact(first.plugin_id, first.id)
    assert {:ok, restored} = Archive.unpack(original)
    assert restored == files()
    assert {:ok, selected} = Plugins.resolve(first.plugin_id)
    assert selected.release_id == second.id
    assert {:ok, old} = Plugins.resolve(first.plugin_id, first.id)
    assert old.source_commit == "commit-one"
    assert first.raw_manifest == files()["plugin.json"]
  end

  test "archive imports canonicalize and candidate imports are idempotent" do
    {:ok, bytes} = Archive.pack(files())
    {:ok, first} = Plugins.import_archive(bytes)
    {:ok, repeated} = Plugins.import_files(files())
    assert first.id == repeated.id
    assert first.artifact_digest == Archive.digest(bytes)
    assert Plugins.catalog().data == []
  end

  test "different fixed commits retain distinct provenance even when content is unchanged" do
    {:ok, first} = Plugins.import_files(files(), %{source_commit: "first"})
    {:ok, next} = Plugins.import_files(files(), %{source_commit: "second"})
    assert first.id != next.id
    assert first.artifact_digest == next.artifact_digest
  end

  test "channels and desired versus actual installation are independent" do
    {:ok, first} = Plugins.import_files(files())
    {:ok, _} = Plugins.publish_release(first.id)
    {:ok, second} = Plugins.import_files(files("updated"))
    {:ok, _} = Plugins.publish_release(second.id, "preview")
    {:ok, installation} = Plugins.set_desired("sigma:test", first.plugin_id, second.id)

    {:ok, report} =
      Plugins.report_installation(installation.id, %{
        actual_release_id: first.id,
        status: "partial",
        components: %{"skill" => "ready", "mcp" => "authentication_required"}
      })

    assert report.desired_release_id == second.id
    assert report.actual_release_id == first.id
    assert report.status == "partial"
    assert {:ok, selected} = Plugins.resolve(first.plugin_id)
    assert selected.release_id == first.id
    assert {:ok, preview} = Plugins.resolve(first.plugin_id, nil, channel: "preview")
    assert preview.release_id == second.id
  end

  test "Codex snapshot retains every release resource and keeps release mapping outside manifest" do
    {:ok, release} = Plugins.import_files(files())
    {:ok, _} = Plugins.publish_release(release.id)
    {:ok, snapshot, [mapping]} = Plugins.Codex.snapshot()
    prefix = mapping.path <> "/"

    assert Map.new(files(), fn {path, bytes} -> {prefix <> path, bytes} end)
           |> Enum.all?(fn {path, bytes} -> snapshot[path] == bytes end)

    assert mapping.release_id == release.id
    assert mapping.artifact_digest == release.artifact_digest
    manifest = Jason.decode!(snapshot[".agents/plugins/marketplace.json"])
    assert [%{"source" => %{"source" => "local", "path" => path}}] = manifest["plugins"]
    assert path == "./" <> mapping.path
    assert snapshot[prefix <> "plugin.json"] == files()["plugin.json"]
    destination = Path.join(System.tmp_dir!(), "plugin-export-test-" <> Ecto.UUID.generate())
    on_exit(fn -> File.rm_rf!(destination) end)
    assert {:ok, _} = Plugins.Codex.export(destination)
    assert File.read!(Path.join(destination, prefix <> "assets/example.bin")) == <<0, 1, 2>>
    assert {:error, :destination_exists} = Plugins.Codex.export(destination)
  end

  test "composition snapshots a selected skill revision including scripts and assets" do
    directory = Path.join(System.tmp_dir!(), "plugin-compose-" <> Ecto.UUID.generate())
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    name = "compose-" <> String.replace(Ecto.UUID.generate(), "-", "")
    archive = Path.join(directory, "skill.tar.gz")

    entries = [
      {String.to_charlist(name <> "/SKILL.md"),
       "---\nname: " <>
         name <> "\ndescription: Composition resource test\n---\n\nOriginal revision"},
      {String.to_charlist(name <> "/scripts/run.sh"), "echo old"},
      {String.to_charlist(name <> "/assets/data.bin"), <<7, 8, 9>>}
    ]

    assert :ok = :erl_tar.create(String.to_charlist(archive), entries, [:compressed])
    assert {:ok, skill} = Backplane.Skills.Ingest.ingest(archive)
    on_exit(fn -> Backplane.Skills.Blob.delete(skill.archive_ref) end)

    manifest = %{
      "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
      "name" => "composed"
    }

    assert {:ok, release} =
             Plugins.compose(manifest, [
               %{skill_id: skill.id, revision: skill.current_revision, name: name}
             ])

    assert {:ok, package} = Archive.unpack(release.artifact)
    assert package["skills/" <> name <> "/scripts/run.sh"] == "echo old"
    assert package["skills/" <> name <> "/assets/data.bin"] == <<7, 8, 9>>

    assert {:error, :exact_skill_revision_required} =
             Plugins.compose(manifest, [%{skill_id: skill.id, name: name}])
  end

  test "failed installation report retains prior actual release and separates enabled state" do
    {:ok, first} = Plugins.import_files(files())
    {:ok, _} = Plugins.publish_release(first.id)

    {:ok, installation} =
      Plugins.set_desired("codex:test", first.plugin_id, first.id, %{enabled: true})

    {:ok, installed} =
      Plugins.report_installation(installation.id, %{actual_release_id: first.id, enabled: false})

    assert installed.enabled
    refute installed.actual_enabled

    {:ok, failed} =
      Plugins.report_installation(installation.id, %{
        status: "failed",
        components: %{"mcp" => %{"status" => "failed", "token" => "secret"}}
      })

    assert failed.actual_release_id == first.id
    refute failed.actual_enabled
    assert failed.components == %{"mcp" => %{"status" => "failed"}}
    assert {:error, _} = Plugins.report_installation(installation.id, %{status: "unrecognized"})

    assert {:ok, malformed} =
             Plugins.report_installation(installation.id, %{
               components: %{"mcp" => %{"status" => %{}}}
             })

    assert malformed.components == %{"mcp" => %{"status" => "unavailable"}}
  end

  test "archive imports and Codex exports preserve executable resources" do
    modes = %{"skills/example/scripts/run.sh" => 0o755}
    {:ok, bytes} = Archive.pack(files(), modes: modes)
    {:ok, release} = Plugins.import_archive(bytes)
    {:ok, _} = Plugins.publish_release(release.id)
    assert {:ok, %{modes: restored}} = Archive.unpack_with_metadata(release.artifact)
    assert restored["skills/example/scripts/run.sh"] == 0o755
    destination = Path.join(System.tmp_dir!(), "plugin-mode-export-" <> Ecto.UUID.generate())
    on_exit(fn -> File.rm_rf!(destination) end)
    {:ok, %{releases: [mapping]}} = Plugins.Codex.export(destination)

    {:ok, stat} =
      File.stat(Path.join([destination, mapping.path, "skills/example/scripts/run.sh"]))

    assert Bitwise.band(stat.mode, 0o777) == 0o755
  end

  test "Codex exports require original unique names and allow explicit independent identity scope" do
    {:ok, first} = Plugins.import_files(files(), %{publisher: "first"})
    {:ok, second} = Plugins.import_files(files("other"), %{publisher: "second"})
    {:ok, _} = Plugins.publish_release(first.id)
    {:ok, _} = Plugins.publish_release(second.id)
    assert first.plugin_id != second.plugin_id
    assert {:error, :duplicate_codex_plugin_name} = Plugins.Codex.snapshot()
    assert {:ok, snapshot, [mapping]} = Plugins.Codex.snapshot(plugin_ids: [first.plugin_id])
    assert mapping.plugin_id == first.plugin_id

    assert [%{"name" => "example"}] =
             Jason.decode!(snapshot[".agents/plugins/marketplace.json"])["plugins"]

    assert snapshot[mapping.path <> "/plugin.json"] == files()["plugin.json"]
    {:ok, _} = Plugins.publish_release(second.id, "alternate")
    assert {:ok, _, [%{plugin_id: plugin_id}]} = Plugins.Codex.snapshot(channel: "alternate")
    assert plugin_id == second.plugin_id
  end

  test "Codex names follow the selected release after a stable identity is renamed" do
    original_files = files()

    renamed_files =
      Map.update!(original_files, "plugin.json", fn bytes ->
        bytes |> Jason.decode!() |> Map.put("name", "renamed") |> Jason.encode!()
      end)

    attrs = %{identity: "source:fixed/plugin"}
    {:ok, original} = Plugins.import_files(original_files, attrs)
    {:ok, renamed} = Plugins.import_files(renamed_files, attrs)
    assert original.plugin_id == renamed.plugin_id
    {:ok, _} = Plugins.publish_release(original.id, "original")
    {:ok, _} = Plugins.publish_release(renamed.id)

    for {channel, release, name, package} <- [
          {"original", original, "example", original_files},
          {"stable", renamed, "renamed", renamed_files}
        ] do
      assert {:ok, snapshot, [mapping]} = Plugins.Codex.snapshot(channel: channel)
      assert mapping.release_id == release.id

      assert [%{"name" => ^name}] =
               Jason.decode!(snapshot[".agents/plugins/marketplace.json"])["plugins"]

      assert snapshot[mapping.path <> "/plugin.json"] == package["plugin.json"]
    end

    {:ok, duplicate} = Plugins.import_files(renamed_files, %{publisher: "another"})
    {:ok, _} = Plugins.publish_release(duplicate.id)
    assert {:error, :duplicate_codex_plugin_name} = Plugins.Codex.snapshot()
  end
end
