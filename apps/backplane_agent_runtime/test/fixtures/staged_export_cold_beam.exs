Code.require_file("staged_export_scenario.exs", __DIR__)

defmodule Backplane.AgentRuntime.StagedExportColdBeamFixture do
  import ExUnit.Assertions
  alias Backplane.AgentRuntime.{Error, Goal, Store}
  alias Backplane.AgentRuntime.StagedExportScenario, as: Scenario
  alias Backplane.AgentRuntime.StagedExportHostFixture, as: Host
  alias Backplane.AgentRuntime.StagedExportFileHostFixture, as: FileHost
  alias Backplane.AgentRuntime.Codex.MultiAgent

  def run("producer", root) do
    for fault <- [:before_commit, :after_commit] do
      dir = Path.join(root, to_string(fault))
      File.mkdir_p!(dir)
      ctx = Scenario.source(dir, fault)
      assert {:ok, stage} = MultiAgent.stage_child_export(ctx.manager, ctx.agent.name)
      assert :ok = Host.put(ctx.host, {:evidence, "stage"}, stage)
      ref = Scenario.receipt(ctx)

      assert {:error, %Error{class: :resource_conflict}} =
               MultiAgent.export_child(ctx.manager, ctx.agent.name, ref)

      assert {:error, %Error{class: :resource_conflict}} =
               MultiAgent.complete_child_export(Host.config(ctx.host), "stage", ref)

      assert :ok =
               Host.put(ctx.host, :source, %{
                 agent: ctx.agent,
                 manifest: ctx.manifest,
                 source_chain: ctx.source_chain,
                 producer_os_pid: System.pid()
               })

      assert {:error, %Error{class: :not_found}} = Host.get(ctx.host, :archive)
      GenServer.stop(ctx.manager)
      FileHost.cleanup(ctx.host.store)
      GenServer.stop(ctx.goal)
      GenServer.stop(ctx.goal_store)
    end

    IO.puts(JSON.encode!(%{producer_os_pid: System.pid(), archives_created: 0, stages: 2}))
  end

  def run("consumer", root) do
    for fault <- [:before_commit, :after_commit] do
      dir = Path.join(root, to_string(fault))
      host = Host.new(self(), dir: Path.join(dir, "runtime"))
      {:ok, original} = Host.get(host, :source)
      refute original.producer_os_pid == System.pid()
      assert {:error, %Error{class: :not_found}} = Host.get(host, :archive)
      {goal_store, goal} = Scenario.goal(dir)

      ctx = %{
        host: host,
        agent: original.agent,
        manifest: original.manifest,
        source_chain: original.source_chain,
        goal: goal
      }

      {:ok, record} = FileHost.load(host.store, ctx.agent.run_id)

      assert {:ok, _} =
               Store.fence(
                 FileHost,
                 host.store,
                 ctx.agent.run_id,
                 record.revision,
                 record.run.incarnation,
                 record.run.incarnation + 1
               )

      Scenario.acknowledge(ctx)

      assert {:error, %Error{class: :resource_conflict}} =
               MultiAgent.complete_child_export(Host.config(host), "stage", "retired")

      chain = [
        %{
          "run_id" => ctx.agent.run_id,
          "from_revision" => record.revision,
          "to_revision" => record.revision + 1,
          "from_incarnation" => record.run.incarnation,
          "to_incarnation" => record.run.incarnation + 1,
          "source_ref" => "durable-recovery-journal"
        }
      ]

      assert "retired" == Scenario.receipt(ctx, 1, chain)

      assert {:ok, archive} =
               MultiAgent.complete_child_export(Host.config(host), "stage", "retired")

      FileHost.fault_next(host.store, :evidence, :refuse)
      assert {:error, %Error{class: :unknown_outcome}} = Host.put(host, :archive, archive)

      assert {:ok, ^archive} =
               MultiAgent.complete_child_export(Host.config(host), "stage", "retired")

      assert :ok = Host.put(host, :archive, archive)

      assert {:ok, ^archive} =
               MultiAgent.complete_child_export(Host.config(host), "stage", "retired")

      assert File.read!(Path.join(dir, "effects")) == "source\n"
      destination = Scenario.manager(host, dir, "destination")
      assert {:ok, _} = MultiAgent.restore_child(destination, archive)
      assert File.read!(Path.join(dir, "effects")) == "source\n"

      assert {:ok, _} =
               Scenario.call(destination, "destination", "followup_task", %{
                 "target" => ctx.agent.name,
                 "message" => "fresh explicit work"
               })

      assert_receive {:provider, "destination", request, provider}, 1_000
      refute request.run_id == ctx.agent.run_id

      send(
        provider,
        {:events,
         [
           %{
             type: :response_completed,
             message: %{
               role: :assistant,
               content: [%{type: :tool_call, id: "effect", name: "effect", arguments: %{}}]
             }
           }
         ]}
      )

      assert_receive {:provider, "destination", next, final_provider}, 1_000
      assert Enum.any?(next.messages, &(&1[:content] == "done"))

      send(
        final_provider,
        {:events,
         [%{type: :response_completed, message: %{role: :assistant, content: "fresh done"}}]}
      )

      assert eventually(fn ->
               {:ok, snapshot} = MultiAgent.snapshot(destination)
               hd(snapshot.agents).status == :completed
             end)

      assert File.read!(Path.join(dir, "effects")) == "source\ndestination\n"
      assert {:ok, goal_snapshot} = Goal.snapshot(goal)
      assert map_size(goal_snapshot.receipts) > 0
      GenServer.stop(destination)
      FileHost.cleanup(host.store)
      GenServer.stop(goal)
      GenServer.stop(goal_store)
    end

    IO.puts(
      JSON.encode!(%{
        consumer_os_pid: System.pid(),
        original_effects: 2,
        fresh_effects: 2,
        archives: 2
      })
    )
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, remaining) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(5)
          eventually(fun, remaining - 1)
        )
  end
end

[mode, root] = System.argv()
Backplane.AgentRuntime.StagedExportColdBeamFixture.run(mode, root)
