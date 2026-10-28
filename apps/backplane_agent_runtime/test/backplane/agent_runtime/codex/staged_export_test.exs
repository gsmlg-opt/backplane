Code.require_file("../../../fixtures/staged_export_scenario.exs", __DIR__)

defmodule Backplane.AgentRuntime.Codex.StagedExportTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Error, StagedExportHostFixture}
  alias Backplane.AgentRuntime.Codex.{MultiAgent, Reconciliation}
  alias StagedExportHostFixture, as: Host
  alias Backplane.AgentRuntime.StagedExportFileHostFixture, as: Store
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Shapes
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

  defmodule LegacyAdapter do
    defdelegate mode(), to: Host
    defdelegate load_evidence(ctx, ref), to: Host
    defdelegate runtime_store(ctx, ref), to: Host
    defdelegate load_receipt(ctx, ref), to: Host
    defdelegate compare_and_swap_receipt(ctx, id, revision, next), to: Host
  end

  defmodule ChangedJournal do
    defdelegate mode(), to: Host
    defdelegate load_evidence(ctx, ref), to: Host
    defdelegate runtime_store(ctx, ref), to: Host
    defdelegate load_receipt(ctx, ref), to: Host
    defdelegate compare_and_swap_receipt(ctx, id, revision, next), to: Host

    def load_recovery_journal(ctx, ref) do
      {:ok, entries} = Host.load_recovery_journal(ctx, ref)
      {:ok, List.update_at(entries, 0, &Map.put(&1, "input", %{"changed" => true}))}
    end
  end

  defmodule JournalMutation do
    defdelegate mode(), to: Host
    defdelegate load_evidence(ctx, ref), to: Host
    defdelegate runtime_store(ctx, ref), to: Host
    defdelegate load_receipt(ctx, ref), to: Host
    defdelegate compare_and_swap_receipt(ctx, id, revision, next), to: Host

    def load_recovery_journal(ctx, ref) do
      {:ok, entries} = Host.load_recovery_journal(ctx, ref)

      changed =
        case ctx.journal_change do
          :gap ->
            List.update_at(entries, -1, &Map.update!(&1, "prior_revision", fn n -> n + 1 end))

          :incarnation ->
            List.update_at(entries, -1, &Map.update!(&1, "prior_incarnation", fn n -> n + 1 end))

          :forbidden_suffix ->
            List.update_at(entries, -1, &Map.put(&1, "kind", "provider_started"))

          :wrong_ack ->
            List.update_at(entries, -1, fn entry ->
              update_in(entry, ["input", "receipts"], fn [receipt | rest] ->
                [Map.put(receipt, "payload", %{"changed" => true}) | rest]
              end)
            end)

          :oversized ->
            List.update_at(
              entries,
              0,
              &Map.put(&1, "input", %{"padding" => String.duplicate("x", 16_777_217)})
            )
        end

      {:ok, changed}
    end
  end

  @moduletag :tmp_dir

  test "a persisted stage completes after manager exit and retries deterministically", ctx do
    {host, manager, agent, manifest} = source(ctx.tmp_dir)
    assert {:ok, stage} = MultiAgent.stage_child_export(manager, agent.name)
    assert stage["record_type"] == "child_export_stage"
    assert stage["source_checkpoint"]["revision"] == length(stage["source_journal"])
    assert :ok = Host.put(host, {:evidence, "stage"}, stage)
    ref = receipt(host, manifest, "retired")
    GenServer.stop(manager)
    assert {:ok, archive} = MultiAgent.complete_child_export(Host.config(host), "stage", ref)
    assert {:ok, ^archive} = MultiAgent.complete_child_export(Host.config(host), "stage", ref)
    {:ok, record} = Store.load(host.store, agent.run_id)

    {:ok, messages} =
      Backplane.AgentRuntime.Codex.Reconciliation.Evidence.public(
        record.run.context.conversation.messages
      )

    assert archive["messages"] == messages
  end

  test "missing journal capability and incomplete chains are explicit failures", ctx do
    {host, manager, agent, _manifest} = source(ctx.tmp_dir)
    assert {:ok, stage} = MultiAgent.stage_child_export(manager, agent.name)
    changed = Map.put(stage, "source_journal", tl(stage["source_journal"]))
    assert :ok = Host.put(host, {:evidence, "stage"}, stage)

    assert {:error, %Error{class: :unsupported_capability}} =
             MultiAgent.complete_child_export({LegacyAdapter, host}, "stage", "absent")

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.complete_child_export({ChangedJournal, host}, "stage", "absent")

    assert :ok = Host.put(host, {:evidence, "changed-stage"}, changed)

    assert {:error, %Error{}} =
             MultiAgent.complete_child_export(Host.config(host), "changed-stage", "absent")
  end

  test "re-sealed changes to source history outcome budget and deadline are refused", ctx do
    {host, manager, agent, manifest} = source(ctx.tmp_dir)
    assert {:ok, stage} = MultiAgent.stage_child_export(manager, agent.name)
    ref = receipt(host, manifest, "retired")
    changed_digest = Evidence.digest(%{"changed" => true})

    for {field, value} <- [
          {"state", "failed"},
          {"outcome_digest", changed_digest},
          {"messages_digest", changed_digest},
          {"host_feedback_digest", changed_digest},
          {"run_digest", changed_digest},
          {"remaining_work", stage["source_checkpoint"]["remaining_work"] + 1},
          {"deadline", System.system_time(:millisecond) + 60_000}
        ] do
      changed = stage |> put_in(["source_checkpoint", field], value) |> seal_stage()
      evidence_ref = "changed:" <> field
      assert :ok = Host.put(host, {:evidence, evidence_ref}, changed)

      assert {:error,
              %Error{class: :resource_conflict, message: "staged source checkpoint changed"}} =
               MultiAgent.complete_child_export(Host.config(host), evidence_ref, ref)
    end

    GenServer.stop(manager)
  end

  test "journal gaps incarnation breaks and exceeded portable bounds fail explicitly", ctx do
    {host, manager, agent, _manifest} = source(ctx.tmp_dir)
    assert {:ok, stage} = MultiAgent.stage_child_export(manager, agent.name)
    assert :ok = Host.put(host, {:evidence, "stage"}, stage)

    for {mutation, message} <- [
          {:gap, "recovery journal prior revision differs"},
          {:incarnation, "recovery journal prior incarnation differs"}
        ] do
      config = {JournalMutation, Map.put(host, :journal_change, mutation)}

      assert {:error, %Error{class: :resource_conflict, message: ^message}} =
               MultiAgent.complete_child_export(config, "stage", "absent")
    end

    config = {JournalMutation, Map.put(host, :journal_change, :oversized)}

    assert {:error, %Error{class: :validation}} =
             MultiAgent.complete_child_export(config, "stage", "absent")

    assert {:error, %Error{class: :validation}} =
             MultiAgent.stage_child_export(manager, agent.name,
               host_metadata: %{"padding" => String.duplicate("x", 16_777_217)}
             )

    GenServer.stop(manager)
  end

  for fault <- [:before_commit, :after_commit] do
    test "exact Goal delivery recovery #{fault} preserves the original effects", ctx do
      scenario = Backplane.AgentRuntime.StagedExportScenario
      ctx = scenario.source(ctx.tmp_dir, unquote(fault))
      on_exit(fn -> Store.cleanup(ctx.host.store) end)
      assert {:ok, stage} = MultiAgent.stage_child_export(ctx.manager, ctx.agent.name)
      assert :ok = Host.put(ctx.host, {:evidence, "stage"}, stage)
      ref = scenario.receipt(ctx)

      assert {:error, %Error{class: :resource_conflict}} =
               MultiAgent.export_child(ctx.manager, ctx.agent.name, ref)

      assert {:error, %Error{class: :resource_conflict}} =
               MultiAgent.complete_child_export(Host.config(ctx.host), "stage", ref)

      GenServer.stop(ctx.manager)
      scenario.acknowledge(ctx)

      assert {:error,
              %Error{class: :resource_conflict, message: "receipt Store revision is stale"}} =
               MultiAgent.complete_child_export(Host.config(ctx.host), "stage", ref)

      assert ref == scenario.receipt(ctx, 1)

      for {mutation, message} <- [
            {:forbidden_suffix, "staged export permits only exact Goal ACK and recovery fencing"},
            {:wrong_ack, "Goal ACK does not match staged receipt identities"}
          ] do
        config = {JournalMutation, Map.put(ctx.host, :journal_change, mutation)}

        assert {:error, %Error{class: :resource_conflict, message: ^message}} =
                 MultiAgent.complete_child_export(config, "stage", ref)
      end

      assert {:ok, archive} =
               MultiAgent.complete_child_export(Host.config(ctx.host), "stage", ref)

      assert {:ok, ^archive} =
               MultiAgent.complete_child_export(Host.config(ctx.host), "stage", ref)

      assert File.read!(Path.join(ctx.dir, "effects")) == "source\n"
    end
  end

  defp seal_stage(stage) do
    stage
    |> Map.put(
      "stage_id",
      "stage_" <> Evidence.digest(Map.drop(stage, ~w(stage_id stage_digest)))
    )
    |> Evidence.seal("stage_digest")
  end

  def source(dir) do
    host = Host.new(self(), dir: dir)
    on_exit(fn -> Store.cleanup(host.store) end)

    {:ok, manager} =
      MultiAgent.start_link(
        parent_run_id: "root-source",
        parent_name: "/root",
        parent_authority: %{caller: "host", run_id: "root-source", grants: []},
        root_agent_id: "stable-root",
        recovery_scope_id: "scope",
        recovery: Host.config(host),
        min_wait_timeout_ms: 0,
        child_options: &Host.child_options(host, :source, &1, &2, &3)
      )

    assert {:ok, _} = call(manager, "spawn_agent", %{"task_name" => "child", "message" => "work"})
    assert_receive {:provider, :source, request, provider}, 1_000

    send(
      provider,
      {:events, [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]}
    )

    assert eventually(fn ->
             {:ok, snapshot} = MultiAgent.snapshot(manager)
             hd(snapshot.agents).status == :completed
           end)

    assert {:ok, _} =
             call(manager, "multi_agent_v1::close_agent", %{"target" => "/root/child"}, :v1)

    {:ok, snapshot} = MultiAgent.snapshot(manager)
    agent = hd(snapshot.agents)
    Host.seal_inventory(host, agent)
    assert {:ok, manifest} = MultiAgent.recovery_manifest(manager, agent.name)
    assert request.run_id == agent.run_id
    {host, manager, agent, manifest}
  end

  def receipt(host, manifest, ref, revision \\ 0, bundle \\ nil) do
    evidence_ref = "bundle:#{ref}:#{revision}"
    assert :ok = Host.put(host, {:evidence, evidence_ref}, bundle || Host.bundle(manifest))

    request =
      Shapes.request(manifest, ref, evidence_ref) |> Map.put("expected_revision", revision)

    assert {:ok, _} = Reconciliation.reconcile(Host.config(host), request)
    ref
  end

  def call(manager, tool, arguments, profile \\ :v2),
    do:
      MultiAgent.call(%{
        backend_context: %{runtime: manager, profile: profile},
        run_id: "root-source",
        tool_name: tool,
        arguments: arguments
      })

  def eventually(fun, remaining \\ 100)
  def eventually(_, 0), do: false

  def eventually(fun, remaining) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(5)
          eventually(fun, remaining - 1)
        )
  end
end
