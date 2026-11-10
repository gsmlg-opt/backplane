defmodule Backplane.HostAgent.PluginInstallerTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.PluginInstaller

  @url "http://127.0.0.1:4232"
  @real_source Path.expand("../../../../../integrations/memory", __DIR__)

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

    for helper <- ~w(contract journal client context service rollout) do
      assert File.read!(Path.join(target, helper <> ".mjs")) ==
               "// packaged #{helper} helper\n"
    end
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
             %{"plugin" => "memory", "runtime" => "claude_code"},
             %{"plugin" => "memory", "runtime" => "hermes"},
             %{"plugin" => "memory", "runtime" => "openclaw"}
           ] =
             PluginInstaller.list(%{
               source_root: source_root,
               home_dir: home_dir,
               host_agent_url: @url
             })

    assert {:ok, %{"installed" => false, "valid" => false}} =
             PluginInstaller.status("memory", "hermes", %{
               source_root: source_root,
               home_dir: home_dir
             })
  end

  @tag :tmp_dir
  test "installs and validates the actual packaged integration sources", %{tmp_dir: tmp_dir} do
    home_dir = Path.join(tmp_dir, "home")

    for runtime <- ~w(hermes openclaw) do
      assert {:ok, %{"valid" => true, "source_path" => source, "target_path" => target}} =
               PluginInstaller.install("memory", runtime, %{home_dir: home_dir})

      assert source =~ Path.join(["integrations", "memory", runtime])
      assert File.read!(Path.join(target, "README.md")) =~ "Backplane"
    end
  end

  describe "claude_code marketplace mode" do
    @describetag :tmp_dir

    defp claude_opts(tmp_dir, extra \\ %{}) do
      Map.merge(
        %{
          source_root: @real_source,
          home_dir: Path.join(tmp_dir, "home"),
          host_agent_url: @url
        },
        extra
      )
    end

    test "installs a rendered marketplace and the hook client", %{tmp_dir: tmp_dir} do
      opts = claude_opts(tmp_dir)
      data = Path.join([tmp_dir, "home", ".local", "share", "backplane"])
      market = Path.join([data, "plugins", "claude"])
      client = Path.join([data, "bin", "backplane-memory-hook"])

      assert {:ok, result} = PluginInstaller.install("memory", "claude_code", opts)
      assert %{"installed" => true, "valid" => true, "target_path" => ^market} = result

      assert result["next_steps"] == [
               "claude plugin marketplace add #{market}",
               "claude plugin install backplane-memory@backplane-local"
             ]

      assert File.regular?(Path.join(market, ".claude-plugin/marketplace.json"))
      plugin = Path.join(market, "backplane-memory")

      assert %{"mcpServers" => %{"backplane-memory" => %{"url" => url}}} =
               plugin |> Path.join(".mcp.json") |> File.read!() |> Jason.decode!()

      assert url == "http://127.0.0.1:4232/memory/claude-code/mcp"

      hooks = File.read!(Path.join(plugin, "hooks/hooks.json"))
      assert hooks =~ "#{client} claude_code SessionStart"
      refute hooks =~ "__HOOK_CLIENT__"
      refute hooks =~ "__HOST_AGENT_URL__"

      assert File.stat!(client).mode |> Bitwise.band(0o777) == 0o755
      script = File.read!(client)
      assert script =~ ~s(baked_url="http://127.0.0.1:4232")
      refute script =~ "__HOST_AGENT_URL__"

      assert File.exists?(Path.join(plugin, "skills/backplane-memory/SKILL.md"))
    end

    test "honours data_dir and is idempotent", %{tmp_dir: tmp_dir} do
      data = Path.join([tmp_dir, "home", "bp-data"])
      opts = claude_opts(tmp_dir, %{data_dir: data})

      assert {:ok, first} = PluginInstaller.install("memory", "claude_code", opts)
      assert first["target_path"] == Path.join([data, "plugins", "claude"])
      assert {:ok, second} = PluginInstaller.install("memory", "claude_code", opts)
      assert second == first
      assert {:ok, %{"valid" => true}} = PluginInstaller.status("memory", "claude_code", opts)

      assert File.read!(Path.join(data, "plugins/claude/backplane-memory/hooks/hooks.json")) =~
               Path.join(data, "bin/backplane-memory-hook")
    end

    test "remove deletes the marketplace and keeps a still-needed hook client", %{
      tmp_dir: tmp_dir
    } do
      opts = claude_opts(tmp_dir)
      data = Path.join([tmp_dir, "home", ".local", "share", "backplane"])
      client = Path.join([data, "bin", "backplane-memory-hook"])
      {:ok, _} = PluginInstaller.install("memory", "claude_code", opts)

      File.mkdir_p!(Path.join([data, "plugins", "codex"]))

      assert {:ok, %{"installed" => false}} =
               PluginInstaller.remove("memory", "claude_code", opts)

      refute File.exists?(Path.join([data, "plugins", "claude"]))
      assert File.exists?(client)

      {:ok, _} = PluginInstaller.install("memory", "claude_code", opts)
      File.rm_rf!(Path.join([data, "plugins", "codex"]))
      assert {:ok, _} = PluginInstaller.remove("memory", "claude_code", opts)
      refute File.exists?(client)
    end

    test "confines targets to the home directory", %{tmp_dir: tmp_dir} do
      assert {:error, {:target_outside_home, _}} =
               PluginInstaller.install(
                 "memory",
                 "claude_code",
                 claude_opts(tmp_dir, %{data_dir: Path.join(tmp_dir, "outside")})
               )

      assert {:error, {:invalid_target, _}} =
               PluginInstaller.install(
                 "memory",
                 "claude_code",
                 claude_opts(tmp_dir, %{
                   target_path: Path.join(tmp_dir, "home/plugins/other")
                 })
               )
    end
  end

  defp source_root!(tmp_dir) do
    source_root = Path.join(tmp_dir, "source")

    hermes = Path.join(source_root, "hermes")
    File.mkdir_p!(hermes)
    File.write!(Path.join(hermes, "README.md"), "Backplane Hermes\n")
    File.write!(Path.join(hermes, "plugin.yaml"), "name: hermes\n")
    File.write!(Path.join(hermes, "__init__.py"), "# hermes\n")

    openclaw = Path.join(source_root, "openclaw")
    File.mkdir_p!(openclaw)
    File.write!(Path.join(openclaw, "README.md"), "Backplane OpenClaw\n")
    File.write!(Path.join(openclaw, "package.json"), ~s({"name":"backplane-memory"}))
    File.write!(Path.join(openclaw, "openclaw.plugin.json"), ~s({"id":"backplane-memory"}))
    File.write!(Path.join(openclaw, "plugin.mjs"), "export default {};\n")

    for helper <- ~w(contract journal client context service rollout) do
      File.write!(Path.join(openclaw, helper <> ".mjs"), "// packaged #{helper} helper\n")
    end

    File.write!(Path.join(openclaw, "plugin.yaml"), "name: openclaw\n")

    claude = Path.join(source_root, "claude_code")
    File.mkdir_p!(Path.join(claude, ".claude-plugin"))
    File.cp_r!(Path.join(@real_source, "claude_code"), claude)
    File.mkdir_p!(Path.join(source_root, "shared/bin"))
    File.write!(Path.join(source_root, "shared/bin/backplane-memory-hook"), "#!/bin/sh\n")

    source_root
  end
end
