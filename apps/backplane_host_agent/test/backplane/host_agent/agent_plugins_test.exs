defmodule Backplane.HostAgent.AgentPluginsTest do
  use ExUnit.Case, async: false
  alias Backplane.HostAgent.AgentPlugins
  alias Backplane.PluginProtocol.Archive
  @moduletag :tmp_dir

  defp archive(marker) do
    {:ok, files} =
      Archive.read_directory(
        Path.expand("../../../../backplane_agent_runtime/examples/plugin", __DIR__)
      )

    files = Map.put(files, "skills/plugin-hello/references/marker.txt", marker)
    {:ok, bytes} = Archive.pack(files)

    {%{
       plugin_id: "plugin-one",
       release_id: "release-" <> marker,
       artifact_digest: Archive.digest(bytes)
     }, bytes}
  end

  test "upgrades preserve old releases/data and rollback selects exact cached content", %{
    tmp_dir: dir
  } do
    {first, one} = archive("one")
    {:ok, installed} = AgentPlugins.install_archive(first, one, root: dir)
    File.write!(Path.join(installed.data_dir, "database"), "keep")
    {:ok, installed} = AgentPlugins.set_enabled(first.plugin_id, true, root: dir)
    assert installed.enabled
    {second, two} = archive("two")
    {:ok, next} = AgentPlugins.install_archive(second, two, root: dir)

    assert File.read!(Path.join(installed.root, "skills/plugin-hello/references/marker.txt")) ==
             "one"

    assert File.read!(Path.join(next.root, "skills/plugin-hello/references/marker.txt")) == "two"
    assert File.read!(Path.join(next.data_dir, "database")) == "keep"
    assert next.enabled
    {:ok, restored} = AgentPlugins.rollback(first.plugin_id, first.release_id, root: dir)
    assert restored.release_id == first.release_id
    assert restored.root == installed.root
    assert restored.data_dir == next.data_dir
  end

  test "failed preparation keeps previous installation and rejects modified caches", %{
    tmp_dir: dir
  } do
    {first, bytes} = archive("one")
    {:ok, installed} = AgentPlugins.install_archive(first, bytes, root: dir)

    assert {:error, :invalid_release_or_digest} =
             AgentPlugins.install_archive(first, bytes <> "broken", root: dir)

    assert {:ok, %{release_id: release_id}} = AgentPlugins.status(first.plugin_id, root: dir)
    assert release_id == first.release_id

    File.write!(
      Path.join(installed.root, "skills/plugin-hello/references/marker.txt"),
      "tampered"
    )

    assert {:error, :cached_release_corrupt} =
             AgentPlugins.install_archive(first, bytes, root: dir)
  end

  test "installer rejects symlink ancestors and exports all content for native Codex", %{
    tmp_dir: dir
  } do
    {descriptor, bytes} = archive("one")
    real = Path.join(dir, "real")
    File.mkdir_p!(real)
    link = Path.join(dir, "link")
    File.ln_s!(real, link)

    assert {:error, :unsafe_install_directory} =
             AgentPlugins.install_archive(descriptor, bytes, root: link)

    {:ok, installed} = AgentPlugins.install_archive(descriptor, bytes, root: real)
    destination = Path.join(dir, "marketplace")

    {:ok, ^destination} =
      AgentPlugins.export_codex(destination, [descriptor.plugin_id], root: real)

    config = Jason.decode!(File.read!(Path.join(destination, ".agents/plugins/marketplace.json")))
    [%{"source" => %{"source" => "local", "path" => path}}] = config["plugins"]

    assert File.read!(Path.join([destination, path, "skills/plugin-hello/references/marker.txt"])) ==
             "one"

    assert File.read!(Path.join([destination, path, "scripts/server.py"])) ==
             File.read!(Path.join(installed.root, "scripts/server.py"))

    assert {:error, :destination_exists} =
             AgentPlugins.export_codex(destination, [descriptor.plugin_id], root: real)

    assert hd(config["plugins"])["name"] == "backplane-example"

    {:ok, _} =
      AgentPlugins.install_archive(%{descriptor | plugin_id: "different-publisher"}, bytes,
        root: real
      )

    assert {:error, :duplicate_codex_plugin_name} =
             AgentPlugins.export_codex(
               Path.join(dir, "duplicates"),
               [descriptor.plugin_id, "different-publisher"],
               root: real
             )

    File.write!(Path.join(installed.root, "scripts/server.py"), "changed")

    assert {:error, :installed_content_changed} =
             AgentPlugins.export_codex(Path.join(dir, "tampered"), [descriptor.plugin_id],
               root: real
             )
  end

  test "cached release ancestors and enable operations reject symlinks", %{tmp_dir: dir} do
    {descriptor, bytes} = archive("one")
    base = Path.join(dir, "base")
    {:ok, installed} = AgentPlugins.install_archive(descriptor, bytes, root: base)
    alias_path = Path.join(dir, "alias")
    File.ln_s!(base, alias_path)

    assert {:error, :unsafe_install_directory} =
             AgentPlugins.set_enabled(descriptor.plugin_id, true, root: alias_path)

    cached = Path.dirname(installed.root)
    moved = Path.join(dir, "moved-release")
    File.rename!(cached, moved)
    File.ln_s!(moved, cached)

    assert {:error, :unsafe_install_directory} =
             AgentPlugins.install_archive(descriptor, bytes, root: base)
  end
end
