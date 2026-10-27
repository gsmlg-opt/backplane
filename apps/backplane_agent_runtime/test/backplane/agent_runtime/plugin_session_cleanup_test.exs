defmodule Backplane.AgentRuntime.PluginSessionCleanupTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Error, Plugins.Session}
  alias Backplane.AgentRuntime.Codex.ResourceRegistry

  defmodule Adapter do
    def start(config, opts) do
      {:ok, agent} =
        Agent.start_link(fn -> %{config: config, owner: opts[:env]["TEST_OWNER"]} end)

      send(
        opts[:env]["TEST_OWNER"],
        {:started, opts[:server], agent, opts[:session], opts[:activation_id]}
      )

      if config["command"] == "blocked-start", do: receive(do: (:finish -> :ok))
      {:ok, %{supervisor: agent, config: config, owner: opts[:env]["TEST_OWNER"]}}
    end

    def tools(%{config: %{"command" => "bad-catalog"}}, _),
      do: {:error, Error.new(:validation, "bad catalog")}

    def tools(%{config: %{"command" => "blocked-catalog"}} = connection, _) do
      send(connection.owner, {:catalog, self()})
      receive do: (:finish -> {:ok, []})
    end

    def tools(_, _), do: {:ok, [%{"name" => "read", "inputSchema" => %{"type" => "object"}}]}

    def call(connection, _name, _arguments, _timeout) do
      send(connection.owner, {:call, self()})
      receive do: (:finish -> {:ok, %{text: "done"}})
    end

    def stop(connection) do
      send(connection.owner, {:stop, connection.config["command"], self()})

      case connection.config["command"] do
        command when command in ["failed", "bad-catalog"] ->
          {:error,
           Error.new(:execution_failure, "stop failed",
             details: %{reason: "retained", token: "private-key"}
           )}

        "blocked-stop" ->
          receive do: (:finish ->
                         Agent.stop(connection.supervisor)
                         :ok)

        "lost-stop" ->
          Process.exit(self(), :kill)

        "unexpected-stop" ->
          {:ok, %{outcome: :confirmed}}

        "done-stop" ->
          Agent.stop(connection.supervisor)
          :done

        "tuple-stop" ->
          Agent.stop(connection.supervisor)
          {:ok, :released}

        _ ->
          Agent.stop(connection.supervisor)
          :ok
      end
    end
  end

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    {:ok, _} = Application.ensure_all_started(:backplane_agent_runtime)
    root = Path.join(dir, "plugin")
    File.cp_r!(Path.expand("../../../examples/plugin", __DIR__), root)

    installation = %{
      plugin_id: "cleanup-plugin",
      release_id: "one",
      artifact_digest: "fixture",
      root: root,
      data_dir: Path.join(dir, "data")
    }

    %{installation: installation}
  end

  defp start(installation, servers, options \\ []) do
    File.write!(
      Path.join(installation.root, "mcp.json"),
      JSON.encode!(%{
        "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
        "mcpServers" =>
          Map.new(servers, fn {name, command} ->
            {name, %{"type" => "stdio", "command" => command}}
          end)
      })
    )

    {:ok, session} =
      Session.start_link(
        Keyword.merge(
          [
            installation: installation,
            run_id: "cleanup",
            mcp_adapter: Adapter,
            env: %{"TEST_OWNER" => self(), "TOKEN" => "private-key"}
          ],
          options
        )
      )

    on_exit(fn ->
      if Process.alive?(session), do: Process.exit(session, :kill)
    end)

    session
  end

  test "registry retains failed cleanup across two real Agent connections and repeated observation",
       %{installation: installation} do
    session = start(installation, [{"failed", "failed"}, {"healthy", "healthy"}])
    assert_receive {:started, "failed", failed, ^session, _}
    assert_receive {:started, "healthy", healthy, ^session, _}
    registry = start_supervised!(ResourceRegistry)

    {:ok, handle} =
      ResourceRegistry.register(registry, "owner", :component, session,
        cleanup: fn -> Session.stop(session) end
      )

    assert {:error, %Error{class: :unknown_outcome}} =
             ResourceRegistry.release(registry, handle, "owner")

    assert Process.alive?(failed)
    refute Process.alive?(healthy)
    assert Process.alive?(session)
    assert {:ok, report} = Session.cleanup_status(session)
    assert report.phase == :closed
    assert report.outcome == :unconfirmed
    assert report.components["healthy"].outcome == :confirmed
    assert report.components["failed"].outcome == :failed

    assert report.components["failed"].cleanup ==
             {:error,
              %{
                class: :execution_failure,
                message: "stop failed",
                details: %{reason: "retained", token: "[redacted]"}
              }}

    assert {:ok, ^report} = Session.close(session)
    assert {:ok, ^report} = Session.cleanup_status(session)
    assert {:error, %Error{class: :unknown_outcome}} = Session.stop(session)
    assert_receive {:stop, "failed", _}
    assert_receive {:stop, "healthy", _}
    refute_receive {:stop, _, _}, 10
    monitor = Process.monitor(failed)
    Process.exit(failed, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^failed, :killed}
    Process.sleep(10)
    assert {:ok, ^report} = Session.cleanup_status(session)
  end

  test "failed catalog retains failed cleanup without repeating stop", %{
    installation: installation
  } do
    session = start(installation, [{"broken", "bad-catalog"}, {"healthy", "healthy"}])
    assert_receive {:started, "broken", broken, ^session, activation}
    assert_receive {:started, "healthy", _, ^session, _}
    assert_receive {:stop, "bad-catalog", _}
    assert is_binary(activation)
    assert Process.alive?(broken)
    assert {:ok, before} = Session.cleanup_status(session)
    assert before.components["broken"].outcome == :failed
    assert before.components["broken"].activation_error != nil
    assert Session.snapshot(session).components["healthy"].status == :ready
    assert {:ok, %{accepted: [_]}} = Session.catalog(session, "cleanup")
    assert {:ok, report} = Session.close(session)
    assert report.components["broken"] == before.components["broken"]
    assert report.outcome == :unconfirmed
    refute_receive {:stop, "bad-catalog", _}, 10
    Agent.stop(broken)
  end

  test "blocked calls cannot block close or rewrite their unknown execution outcome", %{
    installation: installation
  } do
    session = start(installation, [{"healthy", "healthy"}])
    {:ok, %{accepted: [name]}} = Session.catalog(session, "cleanup")
    caller = Task.async(fn -> Session.call_tool(session, "cleanup", name, %{}) end)
    assert_receive {:call, worker}
    ref = Process.monitor(worker)
    assert {:ok, %{phase: :active}} = Session.cleanup_status(session)
    assert {:ok, %{phase: :closed, outcome: :confirmed}} = Session.close(session)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    assert {:error, %Error{class: :unknown_outcome}} = Task.await(caller)
    assert [call] = Map.values(Session.snapshot(session).calls)
    assert call.outcome == :uncertain

    assert {:error, %Error{class: :resource_conflict}} =
             Session.call_tool(session, "cleanup", name, %{})

    assert {:error, %Error{class: :resource_conflict}} = Session.catalog(session, "cleanup")

    assert {:ok, _} =
             Session.resource(session, "cleanup", "skills/plugin-hello/references/marker.txt")

    assert :ok = Session.stop(session)
    refute Process.alive?(session)
  end

  test "caller timeout observes one shared cleanup budget and does not cancel close", %{
    installation: installation
  } do
    session = start(installation, [{"one", "blocked-stop"}, {"two", "blocked-stop"}])

    assert {:error, %Error{class: :timeout, details: details}} =
             Session.close(session, timeout: 5, cleanup_timeout: 180)

    assert {:ok, pending} = Session.cleanup_status(session)
    assert pending.phase == :closing and pending.outcome == :pending
    assert pending.close_id == details.close_id
    assert_receive {:stop, "blocked-stop", one}
    assert_receive {:stop, "blocked-stop", two}
    assert one != two
    send(one, :finish)
    send(two, :finish)
    assert {:ok, done} = Session.close(session, cleanup_timeout: 1_000)
    assert done.close_id == pending.close_id
    assert done.outcome == :confirmed
    assert {:ok, ^done} = Session.cleanup_status(session)
    refute_receive {:stop, _, _}, 10
    assert :ok = Session.stop(session)
  end

  test "cleanup deadline and worker loss remain retained uncertainty", %{
    installation: installation
  } do
    session =
      start(installation, [{"blocked", "blocked-stop"}, {"lost", "lost-stop"}],
        cleanup_timeout: 80
      )

    assert {:ok, report} = Session.close(session)
    assert report.outcome == :unconfirmed
    assert report.components["blocked"].outcome == :uncertain
    assert report.components["lost"].outcome == :uncertain
    assert {:ok, ^report} = Session.close(session, cleanup_timeout: 1_000)
    assert_receive {:stop, "blocked-stop", worker}
    refute Process.alive?(worker)
    assert_receive {:stop, "lost-stop", _}
    refute_receive {:stop, _, _}, 10
  end

  test "legacy confirmations are exact and arbitrary success maps remain uncertain", %{
    installation: installation
  } do
    session =
      start(installation, [
        {"done", "done-stop"},
        {"tuple", "tuple-stop"},
        {"bad", "unexpected-stop"}
      ])

    assert {:ok, report} = Session.close(session)
    assert report.components["done"].outcome == :confirmed
    assert report.components["tuple"].outcome == :confirmed
    assert report.components["bad"].outcome == :uncertain
    assert report.outcome == :unconfirmed
  end

  test "activation is registered before allocation and close remains responsive before its ACK",
       %{installation: installation} do
    File.write!(
      Path.join(installation.root, "mcp.json"),
      JSON.encode!(%{
        "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
        "mcpServers" => %{"blocked" => %{"type" => "stdio", "command" => "blocked-start"}}
      })
    )

    owner = self()

    starter =
      Task.async(fn ->
        {:ok, session} =
          Session.start_link(
            installation: installation,
            run_id: "cleanup",
            mcp_adapter: Adapter,
            env: %{"TEST_OWNER" => owner},
            timeout: 300
          )

        Process.unlink(session)
        {:ok, session}
      end)

    assert_receive {:started, "blocked", agent, session, activation}, 1_000
    assert {:ok, status} = Session.cleanup_status(session)
    assert status.components["blocked"].activation_id == activation
    assert status.components["blocked"].outcome == :pending
    assert {:ok, report} = Session.close(session, cleanup_timeout: 100)
    assert report.outcome == :unconfirmed
    assert report.components["blocked"].outcome == :uncertain
    assert Task.await(starter) == {:ok, session}
    refute Process.alive?(agent)
    Process.exit(session, :kill)
    refute_receive {:stop, _, _}, 10
  end

  test "lost call receipt is bounded while connection cleanup remains independent", %{
    installation: installation
  } do
    session = start(installation, [{"healthy", "healthy"}], timeout: 80)
    {:ok, %{accepted: [name]}} = Session.catalog(session, "cleanup")
    caller = Task.async(fn -> Session.call_tool(session, "cleanup", name, %{}) end)
    assert_receive {:call, worker}
    assert {:error, %Error{class: :unknown_outcome}} = Task.await(caller)
    refute Process.alive?(worker)
    assert :ok = Session.stop(session)
  end

  test "cleanup timeout range is validated before close admission", %{installation: installation} do
    session = start(installation, [{"healthy", "healthy"}])

    for invalid <- [0, -1, :infinity, 3_600_001] do
      assert {:error, %Error{class: :validation}} =
               Session.close(session, cleanup_timeout: invalid)
    end

    assert {:ok, %{phase: :active, close_id: nil}} = Session.cleanup_status(session)
    assert :ok = Session.stop(session)
  end

  test "missing verified guardian leaves default Session unavailable without target execution", %{
    installation: installation
  } do
    marker = Path.join(installation.root, "target-started")

    File.write!(
      Path.join(installation.root, "mcp.json"),
      JSON.encode!(%{
        "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
        "mcpServers" => %{
          "missing" => %{
            "type" => "stdio",
            "command" => "python3",
            "args" => ["-c", "open(" <> inspect(marker) <> ", 'w').write('started')"]
          }
        }
      })
    )

    {:ok, session} =
      Session.start_link(
        installation: installation,
        run_id: "missing",
        guardian_path: Path.join(installation.root, "absent-guardian")
      )

    assert Session.snapshot(session).components["missing"].status == :unavailable
    assert length(Session.snapshot(session).skills) == 1
    refute File.exists?(marker)
    assert {:ok, report} = Session.cleanup_status(session)

    assert report.components["missing"].activation_error.details.reason ==
             :guardian_missing_or_unsupported

    assert {:ok, %{outcome: :confirmed}} = Session.close(session)
    assert :ok = Session.stop(session)
    refute File.exists?(marker)
  end

  test "default rich report requires complete matching transport worker and supervisor confirmations" do
    alias Backplane.AgentRuntime.Plugins.MCP

    resource = %{
      id: "activation:one",
      scope: :owned_beam_worker,
      outcome: :confirmed,
      evidence: %{down: true},
      error: nil
    }

    transport = %{
      version: 1,
      close_id: "close",
      activation_id: "activation",
      transport: :stdio,
      phase: :closed,
      outcome: :confirmed,
      resources: [resource],
      remote: %{outcome: :unknown, session_delete: nil}
    }

    report = %{
      version: 1,
      close_id: "close",
      activation_id: "activation",
      outcome: :confirmed,
      transport: {:ok, transport},
      client_workers: {:ok, %{outcome: :confirmed, resources: [resource]}},
      supervisor: %{outcome: :confirmed, evidence: %{down: true}, error: nil}
    }

    assert MCP.confirmed_close?({:ok, report}, "activation")
    refute MCP.confirmed_close?({:ok, %{outcome: :confirmed}}, "activation")
    refute MCP.confirmed_close?({:ok, report}, "other")

    for modified <- [
          %{report | transport: {:ok, %{transport | phase: :closing}}},
          %{report | transport: {:ok, %{transport | activation_id: "other"}}},
          %{
            report
            | transport: {:ok, %{transport | resources: [%{resource | outcome: :failed}]}}
          },
          %{
            report
            | client_workers:
                {:ok, %{outcome: :confirmed, resources: [%{resource | outcome: :uncertain}]}}
          },
          %{report | supervisor: %{report.supervisor | evidence: %{down: false}}}
        ],
        do: refute(MCP.confirmed_close?({:ok, modified}, "activation"))
  end

  test "bounded startup handles acknowledged connection catalog work without blocking status", %{
    installation: installation
  } do
    File.write!(
      Path.join(installation.root, "mcp.json"),
      JSON.encode!(%{
        "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
        "mcpServers" => %{"blocked" => %{"type" => "stdio", "command" => "blocked-catalog"}}
      })
    )

    owner = self()

    starter =
      Task.async(fn ->
        {:ok, session} =
          Session.start_link(
            installation: installation,
            run_id: "cleanup",
            mcp_adapter: Adapter,
            env: %{"TEST_OWNER" => owner},
            timeout: 200
          )

        Process.unlink(session)
        {:ok, session}
      end)

    assert_receive {:started, "blocked", agent, session, activation}, 1_000
    assert_receive {:catalog, catalog_worker}, 1_000
    assert {:ok, pending} = Session.cleanup_status(session)
    assert pending.components["blocked"].activation_id == activation
    assert Process.alive?(agent)
    assert {:ok, report} = Session.close(session, cleanup_timeout: 100)
    assert report.outcome == :confirmed
    assert report.components["blocked"].activation_error != nil
    assert {:ok, ^session} = Task.await(starter)
    refute Process.alive?(catalog_worker)
    refute Process.alive?(agent)
    assert :ok = Session.stop(session)
  end

  test "late catalog cannot revive a lost connection", %{installation: installation} do
    File.write!(
      Path.join(installation.root, "mcp.json"),
      JSON.encode!(%{
        "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
        "mcpServers" => %{"blocked" => %{"type" => "stdio", "command" => "blocked-catalog"}}
      })
    )

    owner = self()

    starter =
      Task.async(fn ->
        {:ok, session} =
          Session.start_link(
            installation: installation,
            run_id: "cleanup",
            mcp_adapter: Adapter,
            env: %{"TEST_OWNER" => owner},
            timeout: 1_000
          )

        Process.unlink(session)
        {:ok, session}
      end)

    assert_receive {:started, "blocked", agent, session, _}, 1_000
    assert_receive {:catalog, catalog_worker}, 1_000
    Process.exit(agent, :kill)
    assert {:ok, ^session} = Task.await(starter)
    assert Session.snapshot(session).components["blocked"].status == :unavailable
    send(catalog_worker, :finish)
    assert_receive {:stop, "blocked-catalog", _}, 1_000
    assert Session.snapshot(session).components["blocked"].status == :unavailable
    assert {:ok, %{accepted: []}} = Session.catalog(session, "cleanup")
    assert {:ok, %{outcome: :unconfirmed}} = Session.close(session)
    Process.exit(session, :kill)
  end
end
