defmodule Backplane.HostAgent.PluginInstallerTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Memory.Hooks.Cursor
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

    assert {:error, {:unsupported_runtime, "memory", "vscode"}} =
             PluginInstaller.install("memory", "vscode", %{
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
             %{"plugin" => "memory", "runtime" => "codex"},
             %{"plugin" => "memory", "runtime" => "cursor"},
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
      assert hooks =~ "'#{client}' claude_code SessionStart"
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

    test "remove keeps the hook client while another hook-client runtime is installed", %{
      tmp_dir: tmp_dir
    } do
      extra = %{
        "cursor_like" => %{
          uses_hook_client: true,
          required_files: [],
          target_parts: [".extra", "backplane-memory"]
        }
      }

      opts = claude_opts(tmp_dir, %{extra_runtimes: extra})
      data = Path.join([tmp_dir, "home", ".local", "share", "backplane"])
      client = Path.join([data, "bin", "backplane-memory-hook"])
      other = Path.join([tmp_dir, "home", ".extra", "backplane-memory"])
      {:ok, _} = PluginInstaller.install("memory", "claude_code", opts)
      File.mkdir_p!(other)
      # A stray staging dir must not pin the client.
      File.mkdir_p!(Path.join([data, "plugins", ".backplane-memory.install-1"]))

      assert {:ok, %{"installed" => false}} =
               PluginInstaller.remove("memory", "claude_code", opts)

      refute File.exists?(Path.join([data, "plugins", "claude"]))
      assert File.exists?(client)

      {:ok, _} = PluginInstaller.install("memory", "claude_code", opts)
      File.rm_rf!(other)
      assert {:ok, _} = PluginInstaller.remove("memory", "claude_code", opts)
      refute File.exists?(client)
    end

    test "renders safely for data dirs with spaces and quotes", %{tmp_dir: tmp_dir} do
      data = Path.join([tmp_dir, "home", "my data's \"dir\" \\x"])
      opts = claude_opts(tmp_dir, %{data_dir: data})

      assert {:ok, %{"target_path" => target}} =
               PluginInstaller.install("memory", "claude_code", opts)

      %{"hooks" => hooks} =
        target
        |> Path.join("backplane-memory/hooks/hooks.json")
        |> File.read!()
        |> Jason.decode!()

      command = hooks["SessionStart"] |> hd() |> get_in(["hooks", Access.at(0), "command"])
      # Run the command with `echo` standing in for argument display via the real client path.
      client = Path.join(data, "bin/backplane-memory-hook")
      File.write!(client, "#!/bin/sh\nprintf '%s|%s' \"$1\" \"$2\"\n")
      assert {"claude_code|SessionStart", 0} = System.cmd("sh", ["-c", command])
    end

    test "rejects hostile host agent URLs without writing anything", %{tmp_dir: tmp_dir} do
      data = Path.join([tmp_dir, "home", ".local", "share", "backplane"])

      for url <- [
            ~s|http://127.0.0.1:4222"$(touch pwned)"|,
            "http://host/`id`",
            "http://host/a b",
            "ftp://host",
            "http://",
            "http://h\\x"
          ] do
        assert {:error, :invalid_host_agent_url} =
                 PluginInstaller.install(
                   "memory",
                   "claude_code",
                   claude_opts(tmp_dir, %{host_agent_url: url})
                 )
      end

      refute File.exists?(data)
    end

    test "ignores target_path and refuses to replace unrelated directories", %{tmp_dir: tmp_dir} do
      home = Path.join(tmp_dir, "home")
      data = Path.join([home, ".local", "share", "backplane"])
      unrelated = Path.join(home, "src/claude")
      File.mkdir_p!(unrelated)
      File.write!(Path.join(unrelated, "keep.txt"), "keep")

      assert {:ok, %{"target_path" => target}} =
               PluginInstaller.install(
                 "memory",
                 "claude_code",
                 claude_opts(tmp_dir, %{target_path: unrelated})
               )

      assert target == Path.join([data, "plugins", "claude"])
      assert File.exists?(Path.join(unrelated, "keep.txt"))

      File.rm_rf!(target)
      File.mkdir_p!(target)
      File.write!(Path.join(target, "mine.txt"), "mine")
      opts = claude_opts(tmp_dir)

      assert {:error, :unexpected_target_contents} =
               PluginInstaller.install("memory", "claude_code", opts)

      assert {:error, :unexpected_target_contents} =
               PluginInstaller.remove("memory", "claude_code", opts)

      assert File.exists?(Path.join(target, "mine.txt"))
    end

    test "confines targets to the home directory", %{tmp_dir: tmp_dir} do
      assert {:error, {:target_outside_home, _}} =
               PluginInstaller.install(
                 "memory",
                 "claude_code",
                 claude_opts(tmp_dir, %{data_dir: Path.join(tmp_dir, "outside")})
               )
    end
  end

  describe "codex marketplace mode" do
    @describetag :tmp_dir

    test "installs a rendered marketplace sharing the hook client", %{tmp_dir: tmp_dir} do
      opts = claude_opts(tmp_dir)
      data = Path.join([tmp_dir, "home", ".local", "share", "backplane"])
      market = Path.join([data, "plugins", "codex"])
      client = Path.join([data, "bin", "backplane-memory-hook"])

      assert {:ok, result} = PluginInstaller.install("memory", "codex", opts)
      assert %{"installed" => true, "valid" => true, "target_path" => ^market} = result

      assert result["next_steps"] == [
               "codex plugin marketplace add #{market}",
               "codex plugin add backplane-memory@backplane-local"
             ]

      plugin = Path.join(market, "plugins/backplane-memory")
      assert File.regular?(Path.join(market, ".agents/plugins/marketplace.json"))

      assert %{"mcpServers" => %{"backplane-memory" => %{"url" => url}}} =
               plugin |> Path.join(".mcp.json") |> File.read!() |> Jason.decode!()

      assert url == "http://127.0.0.1:4232/memory/codex/mcp"
      hooks = File.read!(Path.join(plugin, "hooks.json"))
      assert hooks =~ "'#{client}' codex SessionStart"
      refute hooks =~ "__HOOK_CLIENT__"
      assert File.stat!(client).mode |> Bitwise.band(0o777) == 0o755
    end

    test "remove keeps the hook client while claude_code is installed", %{tmp_dir: tmp_dir} do
      opts = claude_opts(tmp_dir)
      data = Path.join([tmp_dir, "home", ".local", "share", "backplane"])
      client = Path.join([data, "bin", "backplane-memory-hook"])
      {:ok, _} = PluginInstaller.install("memory", "claude_code", opts)
      {:ok, _} = PluginInstaller.install("memory", "codex", opts)

      assert {:ok, %{"installed" => false}} = PluginInstaller.remove("memory", "codex", opts)
      refute File.exists?(Path.join([data, "plugins", "codex"]))
      assert File.exists?(client)

      {:ok, _} = PluginInstaller.install("memory", "codex", opts)
      {:ok, _} = PluginInstaller.remove("memory", "claude_code", opts)
      assert File.exists?(client)
      {:ok, _} = PluginInstaller.remove("memory", "codex", opts)
      refute File.exists?(client)
    end

    test "ignores target_path and refuses unrelated or foreign-marketplace dirs", %{
      tmp_dir: tmp_dir
    } do
      home = Path.join(tmp_dir, "home")
      target = Path.join([home, ".local/share/backplane/plugins/codex"])
      unrelated = Path.join(home, "src/codex")
      File.mkdir_p!(unrelated)

      assert {:ok, %{"target_path" => ^target}} =
               PluginInstaller.install(
                 "memory",
                 "codex",
                 claude_opts(tmp_dir, %{target_path: unrelated})
               )

      File.rm_rf!(target)
      File.mkdir_p!(target)
      File.write!(Path.join(target, "mine.txt"), "mine")
      opts = claude_opts(tmp_dir)

      assert {:error, :unexpected_target_contents} =
               PluginInstaller.install("memory", "codex", opts)

      assert {:error, :unexpected_target_contents} =
               PluginInstaller.remove("memory", "codex", opts)

      assert File.exists?(Path.join(target, "mine.txt"))
    end
  end

  describe "cursor config mode" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      home = Path.join(tmp_dir, "home")
      cursor = Path.join(home, ".cursor")
      File.mkdir_p!(cursor)

      %{
        opts: claude_opts(tmp_dir),
        home: home,
        hooks: Path.join(cursor, "hooks.json"),
        mcp: Path.join(cursor, "mcp.json"),
        client: Path.join([home, ".local/share/backplane/bin/backplane-memory-hook"])
      }
    end

    defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

    defp our_commands(hooks_json) do
      for {_event, entries} <- hooks_json["hooks"],
          %{"command" => command} <- entries,
          String.contains?(command, "backplane-memory-hook"),
          do: command
    end

    @user_hooks %{
      "version" => 1,
      "hooks" => %{
        "stop" => [%{"command" => "./mine.sh"}],
        "preToolUse" => [%{"command" => "./other.sh"}]
      }
    }
    @user_mcp %{
      "mcpServers" => %{
        "zeta" => %{"type" => "stdio", "command" => "x", "args" => ["a"]},
        "alpha" => %{"url" => "http://example.test/mcp"}
      },
      "other" => true
    }

    test "fresh install creates both files and the hook client", ctx do
      assert {:ok, result} = PluginInstaller.install("memory", "cursor", ctx.opts)

      assert %{"installed" => true, "valid" => true, "target_path" => target} = result
      assert target == ctx.hooks
      assert result["next_steps"] == ["Restart Cursor"]

      hooks = read_json!(ctx.hooks)
      assert hooks["version"] == 1
      assert Enum.sort(Map.keys(hooks["hooks"])) == Enum.sort(Cursor.supported_hooks())
      assert length(our_commands(hooks)) == 8
      assert hooks["hooks"]["stop"] == [%{"command" => "'#{ctx.client}' cursor stop"}]

      assert read_json!(ctx.mcp) == %{
               "mcpServers" => %{"backplane-memory" => %{"url" => "#{@url}/memory/cursor/mcp"}}
             }

      assert File.read!(ctx.hooks) |> String.ends_with?("}\n")
      assert File.regular?(ctx.client)
      refute File.exists?(ctx.hooks <> ".backplane-backup")
    end

    test "install over user entries keeps them and adds ours, order preserved", ctx do
      File.write!(ctx.hooks, Jason.encode!(@user_hooks))
      raw_mcp = ~s({"mcpServers":{"zeta":{"command":"x"},"alpha":{"url":"u"}},"other":true})
      File.write!(ctx.mcp, raw_mcp)

      assert {:ok, _} = PluginInstaller.install("memory", "cursor", ctx.opts)

      hooks = read_json!(ctx.hooks)
      assert hooks["hooks"]["preToolUse"] == [%{"command" => "./other.sh"}]
      assert [%{"command" => "./mine.sh"}, %{"command" => ours}] = hooks["hooks"]["stop"]
      assert ours =~ "backplane-memory-hook"

      mcp_raw = File.read!(ctx.mcp)
      {zeta, _} = :binary.match(mcp_raw, "zeta")
      {alpha, _} = :binary.match(mcp_raw, "alpha")
      {ours_pos, _} = :binary.match(mcp_raw, "backplane-memory")
      assert zeta < alpha and alpha < ours_pos
      mcp = Jason.decode!(mcp_raw)
      assert mcp["other"] == true
      assert Map.keys(mcp["mcpServers"]) |> Enum.sort() == ["alpha", "backplane-memory", "zeta"]

      assert File.read!(ctx.mcp <> ".backplane-backup") == raw_mcp
      assert read_json!(ctx.hooks <> ".backplane-backup") == @user_hooks
    end

    test "double install does not duplicate and keeps the first backup", ctx do
      File.write!(ctx.hooks, Jason.encode!(@user_hooks))
      File.write!(ctx.mcp, Jason.encode!(@user_mcp))

      assert {:ok, _} = PluginInstaller.install("memory", "cursor", ctx.opts)
      first = {File.read!(ctx.hooks), File.read!(ctx.mcp)}
      assert {:ok, _} = PluginInstaller.install("memory", "cursor", ctx.opts)

      assert {File.read!(ctx.hooks), File.read!(ctx.mcp)} == first
      assert length(our_commands(read_json!(ctx.hooks))) == 8
      assert read_json!(ctx.hooks <> ".backplane-backup") == @user_hooks
      assert read_json!(ctx.mcp <> ".backplane-backup") == @user_mcp
    end

    test "remove restores the user's original content", ctx do
      File.write!(ctx.hooks, Jason.encode!(@user_hooks))
      File.write!(ctx.mcp, Jason.encode!(@user_mcp))
      {:ok, _} = PluginInstaller.install("memory", "cursor", ctx.opts)

      assert {:ok, %{"installed" => false, "valid" => false}} =
               PluginInstaller.remove("memory", "cursor", ctx.opts)

      assert read_json!(ctx.hooks) == @user_hooks
      assert read_json!(ctx.mcp) == @user_mcp
      assert File.regular?(ctx.hooks <> ".backplane-backup")
      refute File.exists?(ctx.client)
    end

    test "remove drops emptied events but keeps version", ctx do
      {:ok, _} = PluginInstaller.install("memory", "cursor", ctx.opts)
      {:ok, _} = PluginInstaller.remove("memory", "cursor", ctx.opts)

      assert read_json!(ctx.hooks) == %{"version" => 1, "hooks" => %{}}
      assert read_json!(ctx.mcp) == %{"mcpServers" => %{}}
    end

    test "remove with no config files writes nothing", ctx do
      assert {:ok, %{"installed" => false}} = PluginInstaller.remove("memory", "cursor", ctx.opts)
      refute File.exists?(ctx.hooks)
      refute File.exists?(ctx.mcp)
    end

    test "invalid JSON errors and leaves every file unchanged", ctx do
      File.write!(ctx.hooks, Jason.encode!(@user_hooks))
      File.write!(ctx.mcp, "{ not json")

      assert {:error, {:invalid_json, path}} =
               PluginInstaller.install("memory", "cursor", ctx.opts)

      assert path == ctx.mcp
      assert read_json!(ctx.hooks) == @user_hooks
      assert File.read!(ctx.mcp) == "{ not json"
      refute File.exists?(ctx.hooks <> ".backplane-backup")
      refute File.exists?(ctx.client)

      assert {:error, {:invalid_json, ^path}} =
               PluginInstaller.remove("memory", "cursor", ctx.opts)

      assert File.read!(ctx.mcp) == "{ not json"
    end

    test "hook client survives cursor removal while claude_code is installed", ctx do
      {:ok, _} = PluginInstaller.install("memory", "claude_code", ctx.opts)
      {:ok, _} = PluginInstaller.install("memory", "cursor", ctx.opts)
      {:ok, _} = PluginInstaller.remove("memory", "cursor", ctx.opts)
      assert File.regular?(ctx.client)

      {:ok, _} = PluginInstaller.install("memory", "cursor", ctx.opts)
      {:ok, _} = PluginInstaller.remove("memory", "claude_code", ctx.opts)
      assert File.regular?(ctx.client)
      {:ok, _} = PluginInstaller.remove("memory", "cursor", ctx.opts)
      refute File.exists?(ctx.client)
    end

    test "hook client survives codex removal while cursor is installed", ctx do
      {:ok, _} = PluginInstaller.install("memory", "codex", ctx.opts)
      {:ok, _} = PluginInstaller.install("memory", "cursor", ctx.opts)
      {:ok, _} = PluginInstaller.remove("memory", "codex", ctx.opts)
      assert File.regular?(ctx.client)
    end

    test "target_path option is ignored and bad URLs write nothing", ctx do
      opts = Map.put(ctx.opts, :target_path, Path.join(ctx.home, "elsewhere/hooks.json"))
      assert {:ok, %{"target_path" => target}} = PluginInstaller.install("memory", "cursor", opts)
      assert target == ctx.hooks

      File.rm!(ctx.hooks)
      File.rm!(ctx.mcp)

      assert {:error, :invalid_host_agent_url} =
               PluginInstaller.install("memory", "cursor", %{ctx.opts | host_agent_url: "x'y"})

      refute File.exists?(ctx.hooks)
    end

    test "status reports an unrelated hooks.json as not installed", ctx do
      File.write!(ctx.hooks, Jason.encode!(@user_hooks))

      assert {:ok, %{"installed" => false, "valid" => false}} =
               PluginInstaller.status("memory", "cursor", ctx.opts)
    end
  end

  describe "extra_runtimes test hook" do
    @describetag :tmp_dir

    test "is read from the atom key only and must be a map", %{tmp_dir: tmp_dir} do
      data = Path.join([tmp_dir, "home", ".local", "share", "backplane"])
      client = Path.join([data, "bin", "backplane-memory-hook"])
      other = Path.join([tmp_dir, "home", ".extra", "backplane-memory"])

      fake = %{
        "cursor_like" => %{
          uses_hook_client: true,
          required_files: [],
          target_parts: [".extra", "backplane-memory"]
        }
      }

      for value <- ["nope", fake, %{"claude_code" => %{uses_hook_client: false}}] do
        opts = claude_opts(tmp_dir, %{"extra_runtimes" => value})
        {:ok, _} = PluginInstaller.install("memory", "claude_code", opts)
        File.mkdir_p!(other)
        assert {:ok, _} = PluginInstaller.remove("memory", "claude_code", opts)
        refute File.exists?(client)
        File.rm_rf!(other)
      end

      opts = claude_opts(tmp_dir, %{extra_runtimes: "nope"})
      {:ok, _} = PluginInstaller.install("memory", "claude_code", opts)
      assert {:ok, _} = PluginInstaller.remove("memory", "claude_code", opts)
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
    File.cp_r!(Path.join(@real_source, "codex"), Path.join(source_root, "codex"))
    File.cp_r!(Path.join(@real_source, "cursor"), Path.join(source_root, "cursor"))
    File.mkdir_p!(Path.join(source_root, "shared/bin"))
    File.write!(Path.join(source_root, "shared/bin/backplane-memory-hook"), "#!/bin/sh\n")

    source_root
  end
end
