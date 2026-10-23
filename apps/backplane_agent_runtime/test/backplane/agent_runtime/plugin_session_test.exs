defmodule Backplane.AgentRuntime.PluginSessionTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.Plugins.{Backend, Session}
  alias Backplane.PluginProtocol.Archive

  defmodule Adapter do
    def start(config, opts) do
      owner = opts[:env]["TEST_OWNER"]

      supervisor =
        spawn_link(fn ->
          receive do
            :stop -> :ok
          end
        end)

      send(owner, {:plugin_started, opts[:server], supervisor, config})
      {:ok, %{supervisor: supervisor, config: config}}
    end

    def tools(%{config: %{"command" => "malformed"}}, _timeout),
      do: {:ok, [%{"name" => "bad", "annotations" => false}]}

    def tools(%{config: %{"command" => "bad-schema"}}, _timeout),
      do: {:ok, [%{"name" => "bad", "inputSchema" => %{"type" => "object", "properties" => []}}]}

    def tools(_connection, _timeout),
      do: {:ok, [%{"name" => "valid", "inputSchema" => %{"type" => "object"}}]}

    def stop(connection), do: send(connection.supervisor, :stop)
  end

  @moduletag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    {:ok, _} = Application.ensure_all_started(:backplane_agent_runtime)
    root = Path.join(tmp_dir, "plugin")
    File.cp_r!(Path.expand("../../../examples/plugin", __DIR__), root)
    {:ok, files} = Archive.read_directory(root)
    {:ok, bytes} = Archive.pack(files)

    installed = %{
      plugin_id: "test-plugin",
      release_id: "release-one",
      artifact_digest: Archive.digest(bytes),
      root: root,
      data_dir: Path.join(tmp_dir, "data")
    }

    %{installed: installed}
  end

  test "real MCP execution, skill resources, run isolation and resource cleanup", %{
    installed: installed
  } do
    {:ok, session} = Session.start_link(installation: installed, run_id: "run-one")
    snapshot = Session.snapshot(session)
    assert snapshot.release_id == "release-one"
    assert snapshot.components["echo"].status == :ready
    assert [%{plugin_id: "test-plugin", release_id: "release-one"}] = snapshot.skills
    {:ok, admission} = Session.catalog(session, "run-one")
    assert [name] = admission.accepted
    {:ok, descriptor} = Backplane.AgentRuntime.ToolRegistry.lookup(admission.registry, name)

    {:ok, result} =
      Backend.execute(%{
        backend_context: descriptor.backend_context,
        run_id: "run-one",
        tool_name: name,
        arguments: %{"text" => "hello"}
      })

    assert [%{"text" => "BACKPLANE_PLUGIN_V1: hello"}] = result["content"]
    assert {:error, %{class: :forbidden}} = Session.call_tool(session, "other-run", name, %{})
    {:ok, skill} = Session.load_skill(session, "run-one", "skills/plugin-hello/SKILL.md")
    assert skill.plugin_root == installed.root

    {output, 0} =
      System.cmd("python3", [Path.join(installed.root, "skills/plugin-hello/scripts/hello.py")])

    assert String.trim(output) == "BACKPLANE_PLUGIN_V1"

    {:ok, resource} =
      Session.resource(session, "run-one", "skills/plugin-hello/references/marker.txt")

    assert resource == "BACKPLANE_PLUGIN_V1\n"

    [{transport, _value}] =
      Registry.lookup(Backplane.AgentRuntime.PluginRegistry, {{session, "echo"}, :transport})

    ref = Process.monitor(transport)
    Session.stop(session)
    assert_receive {:DOWN, ^ref, :process, ^transport, _reason}, 1_000
  end

  test "one unavailable MCP preserves skills and the other MCP", %{installed: installed} do
    path = Path.join(installed.root, "mcp.json")
    config = JSON.decode!(File.read!(path))

    config =
      put_in(config, ["mcpServers", "unavailable"], %{
        "type" => "stdio",
        "command" => "backplane-missing-command"
      })

    File.write!(path, JSON.encode!(config))
    {:ok, session} = Session.start_link(installation: installed, run_id: "run", timeout: 200)
    snapshot = Session.snapshot(session)
    assert snapshot.components["echo"].status == :ready
    assert snapshot.components["unavailable"].status == :unavailable
    assert length(snapshot.skills) == 1
    assert Enum.any?(snapshot.diagnostics, &(&1.code == :mcp_unavailable))
    assert {:ok, %{accepted: [_]}} = Session.catalog(session, "run")
    Session.stop(session)
  end

  test "new sessions pin their own release and never change an existing session", %{
    installed: installed,
    tmp_dir: tmp_dir
  } do
    {:ok, first} = Session.start_link(installation: installed, run_id: "first")
    root = Path.join(tmp_dir, "second")
    File.cp_r!(installed.root, root)

    File.write!(
      Path.join(root, "skills/plugin-hello/references/marker.txt"),
      "BACKPLANE_PLUGIN_V2\n"
    )

    next = %{installed | root: root, release_id: "release-two"}
    {:ok, second} = Session.start_link(installation: next, run_id: "second")
    {:ok, %{accepted: [one]}} = Session.catalog(first, "first")
    {:ok, %{accepted: [two]}} = Session.catalog(second, "second")

    assert {:ok, %{"content" => [%{"text" => "BACKPLANE_PLUGIN_V1: x"}]}} =
             Session.call_tool(first, "first", one, %{"text" => "x"})

    assert {:ok, %{"content" => [%{"text" => "BACKPLANE_PLUGIN_V2: x"}]}} =
             Session.call_tool(second, "second", two, %{"text" => "x"})

    Session.stop(first)
    Session.stop(second)
  end

  test "malformed MCP catalogs stop their connection and preserve healthy components", %{
    installed: installed
  } do
    File.write!(
      Path.join(installed.root, "mcp.json"),
      JSON.encode!(%{
        "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
        "mcpServers" =>
          Map.new(
            [{"broken", "malformed"}, {"schema", "bad-schema"}, {"healthy", "healthy"}],
            fn {name, command} ->
              {name, %{"type" => "stdio", "command" => command}}
            end
          )
      })
    )

    {:ok, session} =
      Session.start_link(
        installation: installed,
        run_id: "catalog-run",
        env: %{"TEST_OWNER" => self()},
        mcp_adapter: Adapter
      )

    assert_receive {:plugin_started, "broken", broken, _}
    assert_receive {:plugin_started, "schema", schema, _}
    assert_receive {:plugin_started, "healthy", healthy, _}
    assert Session.snapshot(session).components["broken"].status == :unavailable
    assert Session.snapshot(session).components["schema"].status == :unavailable
    assert length(Session.snapshot(session).skills) == 1
    assert {:ok, %{accepted: [_]}} = Session.catalog(session, "catalog-run")

    for pid <- [broken, schema] do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
    end

    ref = Process.monitor(healthy)
    Session.stop(session)
    assert_receive {:DOWN, ^ref, :process, ^healthy, _}
  end

  test "only stdio reserved values expand once and host bindings stay outside the package", %{
    installed: installed
  } do
    File.write!(
      Path.join(installed.root, "mcp.json"),
      JSON.encode!(%{
        "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
        "mcpServers" => %{
          "local" => %{
            "type" => "stdio",
            "command" => "./literal-command",
            "args" => ["${PLUGIN_ROOT}", "${PLUGIN_DATA}", "${OTHER}"],
            "env" => %{
              "VALUE" => "${PLUGIN_ROOT}",
              "${PLUGIN_ROOT}" => "literal-key",
              "TOKEN" => "public"
            },
            "cwd" => "${PLUGIN_DATA}"
          },
          "remote" => %{
            "type" => "streamable-http",
            "url" => "https://example.test/%24%7BPLUGIN_ROOT%7D",
            "headers" => %{"X-Literal" => "${PLUGIN_DATA}", "AUTHORIZATION" => "public"}
          }
        }
      })
    )

    {:ok, session} =
      Session.start_link(
        installation: installed,
        run_id: "expansion-run",
        mcp_adapter: Adapter,
        env: %{"TEST_OWNER" => self()},
        bindings: %{
          "local" => %{"env" => %{"TOKEN" => "bound-secret"}},
          "remote" => %{"headers" => %{"Authorization" => "bound-secret"}}
        }
      )

    assert_receive {:plugin_started, "local", _, local}
    assert local["command"] == "./literal-command"
    assert local["args"] == [installed.root, installed.data_dir, "${OTHER}"]
    assert local["env"]["${PLUGIN_ROOT}"] == "literal-key"
    assert local["env"]["TOKEN"] == "bound-secret"
    assert local["cwd"] == installed.data_dir
    assert_receive {:plugin_started, "remote", _, remote}
    assert remote["url"] == "https://example.test/%24%7BPLUGIN_ROOT%7D"
    assert remote["headers"]["x-literal"] == "${PLUGIN_DATA}"
    assert remote["headers"]["authorization"] == "bound-secret"
    refute inspect(:sys.get_status(session)) =~ "bound-secret"
    {:ok, raw} = Session.resource(session, "expansion-run", "mcp.json")
    refute raw =~ "bound-secret"
    Session.stop(session)
  end

  test "native MCP discovery follows paginated tool catalogs", %{installed: installed} do
    script = Path.join(installed.root, "scripts/server.py")

    File.write!(
      script,
      String.replace(
        File.read!(script),
        ~s(    elif method == "tools/list":),
        """
            elif method == "tools/list":
                if not request.get("params", {}).get("cursor"):
                    response["result"] = {"tools": [], "nextCursor": "second"}
                    print(json.dumps(response), flush=True)
                    continue
        """
        |> String.trim_trailing()
      )
    )

    {:ok, session} = Session.start_link(installation: installed, run_id: "pages")
    assert Session.snapshot(session).components["echo"].status == :ready
    assert {:ok, %{accepted: [tool]}} = Session.catalog(session, "pages")

    assert {:ok, %{"content" => [%{"text" => "BACKPLANE_PLUGIN_V1: pages"}]}} =
             Session.call_tool(session, "pages", tool, %{"text" => "pages"})

    Session.stop(session)
  end
end
