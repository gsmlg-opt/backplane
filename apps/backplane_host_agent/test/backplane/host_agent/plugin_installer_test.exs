defmodule Backplane.HostAgent.PluginInstallerTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.PluginInstaller

  @tag :tmp_dir
  test "installs packaged memory plugin for Hermes into the default home target", %{
    tmp_dir: tmp_dir
  } do
    source_root = source_root!(tmp_dir)
    home_dir = Path.join(tmp_dir, "home")

    assert {:ok, result} =
             PluginInstaller.install("memory", "hermes", %{
               source_root: source_root,
               home_dir: home_dir
             })

    target = Path.join([home_dir, ".hermes", "plugins", "backplane-memory"])
    assert result["plugin"] == "memory"
    assert result["runtime"] == "hermes"
    assert result["target_path"] == target
    assert result["installed"] == true
    assert result["valid"] == true
    assert File.read!(Path.join(target, "plugin.yaml")) =~ "hermes"
    assert File.read!(Path.join(target, "__init__.py")) =~ "hermes"
  end

  @tag :tmp_dir
  test "installs packaged memory plugin for OpenClaw into the default home target", %{
    tmp_dir: tmp_dir
  } do
    source_root = source_root!(tmp_dir)
    home_dir = Path.join(tmp_dir, "home")

    assert {:ok, %{"target_path" => target, "valid" => true}} =
             PluginInstaller.install("memory", "openclaw", %{
               source_root: source_root,
               home_dir: home_dir
             })

    assert target == Path.join([home_dir, ".openclaw", "extensions", "backplane-memory"])
    assert File.exists?(Path.join(target, "package.json"))
    assert File.exists?(Path.join(target, "openclaw.plugin.json"))
    assert File.exists?(Path.join(target, "plugin.mjs"))
  end

  @tag :tmp_dir
  test "replaces an existing plugin install by default", %{tmp_dir: tmp_dir} do
    source_root = source_root!(tmp_dir)
    home_dir = Path.join(tmp_dir, "home")
    target = Path.join([home_dir, ".hermes", "plugins", "backplane-memory"])
    File.mkdir_p!(target)
    File.write!(Path.join(target, "stale.txt"), "stale")

    assert {:ok, %{"valid" => true}} =
             PluginInstaller.install("memory", "hermes", %{
               source_root: source_root,
               home_dir: home_dir
             })

    refute File.exists?(Path.join(target, "stale.txt"))
    assert File.exists?(Path.join(target, "plugin.yaml"))
  end

  @tag :tmp_dir
  test "can refuse to replace an existing plugin install", %{tmp_dir: tmp_dir} do
    source_root = source_root!(tmp_dir)
    home_dir = Path.join(tmp_dir, "home")
    target = Path.join([home_dir, ".hermes", "plugins", "backplane-memory"])
    File.mkdir_p!(target)

    assert {:error, {:already_installed, ^target}} =
             PluginInstaller.install("memory", "hermes", %{
               source_root: source_root,
               home_dir: home_dir,
               force: false
             })
  end

  @tag :tmp_dir
  test "removes an installed plugin", %{tmp_dir: tmp_dir} do
    source_root = source_root!(tmp_dir)
    home_dir = Path.join(tmp_dir, "home")
    target = Path.join([home_dir, ".hermes", "plugins", "backplane-memory"])

    assert {:ok, %{"installed" => true}} =
             PluginInstaller.install("memory", "hermes", %{
               source_root: source_root,
               home_dir: home_dir
             })

    assert File.dir?(target)

    assert {:ok, %{"installed" => false, "valid" => false, "target_path" => ^target}} =
             PluginInstaller.remove("memory", "hermes", %{
               source_root: source_root,
               home_dir: home_dir
             })

    refute File.exists?(target)
  end

  @tag :tmp_dir
  test "rejects unsupported plugins, runtimes, and unsafe targets", %{tmp_dir: tmp_dir} do
    source_root = source_root!(tmp_dir)
    home_dir = Path.join(tmp_dir, "home")

    assert {:error, {:unsupported_plugin, "unknown"}} =
             PluginInstaller.install("unknown", "hermes", %{
               source_root: source_root,
               home_dir: home_dir
             })

    assert {:error, {:unsupported_runtime, "memory", "codex"}} =
             PluginInstaller.install("memory", "codex", %{
               source_root: source_root,
               home_dir: home_dir
             })

    assert {:error, {:invalid_target, _path}} =
             PluginInstaller.install("memory", "hermes", %{
               source_root: source_root,
               home_dir: home_dir,
               target_path: Path.join(home_dir, ".hermes/plugins/not-backplane")
             })

    assert {:error, {:target_outside_home, _path}} =
             PluginInstaller.install("memory", "hermes", %{
               source_root: source_root,
               home_dir: home_dir,
               target_path: Path.join(tmp_dir, "outside/backplane-memory")
             })
  end

  @tag :tmp_dir
  test "lists plugin install status", %{tmp_dir: tmp_dir} do
    source_root = source_root!(tmp_dir)
    home_dir = Path.join(tmp_dir, "home")

    assert [
             %{"plugin" => "memory", "runtime" => "hermes"},
             %{"plugin" => "memory", "runtime" => "openclaw"}
           ] = PluginInstaller.list(%{source_root: source_root, home_dir: home_dir})

    assert {:ok, %{"installed" => false, "valid" => false}} =
             PluginInstaller.status("memory", "hermes", %{
               source_root: source_root,
               home_dir: home_dir
             })
  end

  defp source_root!(tmp_dir) do
    source_root = Path.join(tmp_dir, "source")

    hermes = Path.join(source_root, "hermes")
    File.mkdir_p!(hermes)
    File.write!(Path.join(hermes, "plugin.yaml"), "name: hermes\n")
    File.write!(Path.join(hermes, "__init__.py"), "# hermes\n")

    openclaw = Path.join(source_root, "openclaw")
    File.mkdir_p!(openclaw)
    File.write!(Path.join(openclaw, "package.json"), ~s({"name":"backplane-memory"}))
    File.write!(Path.join(openclaw, "openclaw.plugin.json"), ~s({"id":"backplane-memory"}))
    File.write!(Path.join(openclaw, "plugin.mjs"), "export default {};\n")

    source_root
  end
end
