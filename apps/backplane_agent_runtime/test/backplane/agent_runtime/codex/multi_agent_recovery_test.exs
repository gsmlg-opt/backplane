Code.require_file("../../../fixtures/multi_agent_recovery_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.Codex.MultiAgentRecoveryTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{EphemeralStore, Error, MultiAgentRecoveryHostFixture}
  alias Backplane.AgentRuntime.Codex.{MultiAgent, Reconciliation, Session}
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias MultiAgentRecoveryHostFixture, as: Host

  defp manager(context, label, options \\ []) do
    root = Keyword.get(options, :parent_run_id, "root-#{label}")

    opts = [
      parent_run_id: root,
      parent_name: "/root",
      parent_authority: %{caller: "host", run_id: root, grants: []},
      root_agent_id: "stable-root",
      recovery_scope_id: "scope",
      recovery: Host.config(context),
      subscriber: self(),
      min_wait_timeout_ms: 0,
      child_options: &Host.child_options(context, label, &1, &2, &3)
    ]

    start_supervised!(
      Supervisor.child_spec({MultiAgent, Keyword.merge(opts, options)},
        id: make_ref(),
        restart: :temporary
      )
    )
  end

  defp call(manager, root, tool, arguments, profile \\ :v2) do
    MultiAgent.call(%{
      backend_context: %{runtime: manager, profile: profile},
      run_id: root,
      tool_name: tool,
      arguments: arguments
    })
  end

  defp spawn_child(manager, label, name, root \\ nil) do
    assert {:ok, _} =
             call(manager, root || "root-#{label}", "spawn_agent", %{
               "task_name" => name,
               "message" => name
             })

    assert_receive {:prepared, ^label, _, _, _}, 1_000
    assert_receive {:provider, ^label, request, provider}, 1_000
    {request, provider}
  end

  defp complete(manager, request, provider) do
    send(
      provider,
      {:events,
       [%{type: :response_completed, message: %{role: :assistant, content: "retained answer"}}]}
    )

    assert eventually(fn ->
             {:ok, snapshot} = MultiAgent.snapshot(manager)

             Enum.any?(
               snapshot.agents,
               &(&1.run_id == request.run_id and &1.status == :completed)
             )
           end)
  end

  defp retired(context, manager, label, name \\ "child") do
    {request, provider} = spawn_child(manager, label, name)
    complete(manager, request, provider)
    retire_existing(context, manager, label, "/root/#{name}")
  end

  defp retire_existing(context, manager, label, name) do
    assert {:ok, _} =
             call(
               manager,
               "root-#{label}",
               "multi_agent_v1::close_agent",
               %{"target" => name},
               :v1
             )

    {:ok, snapshot} = MultiAgent.snapshot(manager)
    agent = Enum.find(snapshot.agents, &(&1.name == name))
    Host.seal_inventory(context, agent)
    assert {:ok, manifest} = MultiAgent.recovery_manifest(manager, agent.name)
    receipt = receipt(context, manifest, "retired:" <> agent.attempt_id)
    assert {:ok, acknowledgement} = MultiAgent.reconcile_child(manager, receipt["receipt_id"])
    assert acknowledgement.status == :confirmed
    assert {:ok, archive} = MultiAgent.export_child(manager, agent.name, receipt["receipt_id"])
    {agent, archive, receipt, manifest}
  end

  defp receipt(context, manifest, id, observations \\ nil) do
    ref = "evidence:" <> id
    Host.put(context, {:evidence, ref}, Host.bundle(manifest, observations))

    request = %{
      "schema_version" => 1,
      "receipt_id" => id,
      "expected_revision" => 0,
      "subject" => manifest["subject"],
      "evidence_ref" => ref
    }

    assert {:ok, receipt} = Reconciliation.reconcile(Host.config(context), request)
    receipt
  end

  test "public export cold roster import and explicit sequence-one followup preserve history and reject old events" do
    context = Host.new(self(), managed: true)
    source = manager(context, :source)
    {old, archive, _receipt, _manifest} = retired(context, source, :source)
    assert_receive {:bound, :source, old_binding}
    assert Session.status(old_binding.session).phase == :closed
    assert_receive {:cleaned, :source, _}
    assert {:ok, manager_manifest} = MultiAgent.recovery_manifest(source, :manager)
    manager_receipt = receipt(context, manager_manifest, "source-closed")

    assert {:ok, %{status: :confirmed}} =
             MultiAgent.reconcile_close(source, manager_receipt["receipt_id"])

    GenServer.stop(source)
    destination = manager(context, :destination)
    assert {:ok, restored} = MultiAgent.restore_child(destination, archive)
    assert {:ok, ^restored} = MultiAgent.restore_child(destination, archive)
    assert {:ok, snapshot} = MultiAgent.snapshot(destination)
    assert snapshot.admissions == []

    assert [
             %{
               agent_id: id,
               archived: true,
               status: :closed,
               resident: false,
               source_manager_id: source_id,
               historical_outcome: "completed"
             }
           ] = snapshot.agents

    assert id == old.agent_id
    assert source_id == archive["child_identity"]["source_manager_id"]
    assert snapshot.root.agent_id == "stable-root"
    assert {:ok, %{agents: []}} = call(destination, "root-destination", "list_agents", %{})
    refute_received {:prepared, :destination, _, _, _}
    refute_received {:provider, :destination, _, _}
    refute_received {:bound, :destination, _}
    refute_received {:cleaned, :destination, _}
    assert_receive {:codex_collaboration, %{type: :restored}}, 1_000
    refute_received {:codex_collaboration, %{type: :restored}}

    assert {:ok, _} =
             call(destination, "root-destination", "followup_task", %{
               "target" => old.name,
               "message" => "continue"
             })

    assert_receive {:prepared, :destination, _, run_id, parent}, 1_000
    assert parent.child.agent_id == old.agent_id
    assert parent.child.incarnation > old.incarnation
    assert_receive {:bound, :destination, next_binding}
    refute next_binding.session == old_binding.session
    refute next_binding.token == old_binding.token
    assert next_binding.run_incarnation == parent.child.incarnation
    assert run_id == old.name <> ":" <> snapshot.manager_id <> ":1"
    refute run_id == old.run_id
    assert_receive {:provider, :destination, request, provider}, 1_000
    assert Enum.any?(request.messages, &(&1[:content] == "retained answer"))
    assert Enum.any?(request.messages, &(&1[:content] == "continue"))

    send(
      destination,
      {:agent_runtime, old.run_id,
       %{type: :run_failed, incarnation: old.incarnation, outcome: "old"}}
    )

    send(
      destination,
      {:managed_child_runtime, %{}, old.run_id,
       %{type: :run_completed, incarnation: old.incarnation}}
    )

    assert {:ok, current} = MultiAgent.snapshot(destination)
    assert hd(current.agents).status == :running
    assert hd(current.agents).run_id == run_id

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.restore_child(destination, archive)

    complete(destination, request, provider)
    assert Session.status(next_binding.session).phase == :idle
  end

  test "scope identity history configuration artifact and unsupported archive conflicts fail before preparation" do
    context = Host.new(self())
    source = manager(context, :source)
    {_old, archive, _receipt, _manifest} = retired(context, source, :source)
    destination = manager(context, :destination)

    for change <- [
          &Map.put(&1, "schema_version", 2),
          &Map.put(&1, "unexpected", true),
          &put_in(&1, ["child_identity", "scope_id"], "other"),
          &put_in(&1, ["child_identity", "parent_id"], "other"),
          &Map.put(&1, "messages", [%{"role" => "assistant", "content" => "forged"}]),
          &Map.put(&1, "remaining_work", 1000),
          &Map.put(&1, "configuration_ref", "missing"),
          &Map.put(&1, "artifact_refs", ["missing"])
        ] do
      changed = archive |> change.() |> seal_archive()
      assert {:error, %Error{}} = MultiAgent.restore_child(destination, changed)
    end

    assert {:error, %Error{class: :validation}} =
             MultiAgent.restore_child(destination, Map.put(archive, "runtime", self()))

    refute_received {:prepared, :destination, _, _, _}
    assert {:ok, _} = MultiAgent.restore_child(destination, archive)
    changed = archive |> Map.put("host_metadata", %{"changed" => true}) |> seal_archive()

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.restore_child(destination, changed)
  end

  test "imports close after any reserved fresh admission and capacity refusal leaves archive intact" do
    context = Host.new(self())
    source = manager(context, :source)
    {_old, archive, _, _} = retired(context, source, :source)
    destination = manager(context, :destination, max_concurrent_threads_per_session: 1)
    assert {:ok, restored} = MultiAgent.restore_child(destination, archive)

    assert {:error, %Error{class: :resource_conflict}} =
             call(destination, "root-destination", "followup_task", %{
               "target" => "/root/child",
               "message" => "continue"
             })

    refute_received {:prepared, :destination, _, _, _}
    assert {:ok, ^restored} = MultiAgent.restore_child(destination, archive)
    executing = manager(context, :executing)
    {request, provider} = spawn_child(executing, :executing, "new")

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.restore_child(executing, archive)

    complete(executing, request, provider)
  end

  test "archive validation reads run outside manager mailbox and stale pin cannot change current child" do
    context = Host.new(self())
    source = manager(context, :source)
    {_old, archive, _, _} = retired(context, source, :source)
    destination = manager(context, :destination)
    Host.put(context, :read_barrier, {archive["admission_ref"], self()})
    worker = Task.async(fn -> MultiAgent.restore_child(destination, archive) end)
    assert_receive {:recovery_barrier, reader}, 1_000
    assert {:ok, %{agents: []}} = MultiAgent.snapshot(destination)
    :ets.delete(context.table, :read_barrier)
    {request, provider} = spawn_child(destination, :destination, "fresh")
    send(reader, :continue)
    assert {:error, %Error{class: :resource_conflict}} = Task.await(worker, 5_000)
    complete(destination, request, provider)
  end

  test "archived V1 resume rechecks destination capacity before preparation" do
    context = Host.new(self())
    source = manager(context, :source)
    {_old, archive, _, _} = retired(context, source, :source)
    destination = manager(context, :destination, max_agents: 1)
    assert {:ok, _} = MultiAgent.restore_child(destination, archive)
    assert {:ok, %{agents: [archived]}} = MultiAgent.snapshot(destination)

    assert {:ok, _} =
             call(
               destination,
               "root-destination",
               "multi_agent_v1::spawn_agent",
               %{"task_name" => "busy", "message" => "stay active"},
               :v1
             )

    assert_receive {:prepared, :destination, _, _, _}, 1_000
    assert_receive {:provider, :destination, _, _}, 1_000

    assert {:error, %Error{class: :resource_conflict}} =
             call(
               destination,
               "root-destination",
               "multi_agent_v1::resume_agent",
               %{"id" => "/root/child"},
               :v1
             )

    refute_receive {:prepared, :destination, _, _, _}
    assert {:ok, snapshot} = MultiAgent.snapshot(destination)
    assert Enum.find(snapshot.agents, &(&1.name == "/root/child")) == archived
    assert :ok = MultiAgent.close_session(destination)
  end

  test "archived V1 resume rechecks capacity after asynchronous validation" do
    context = Host.new(self())
    source = manager(context, :source)
    {_old, archive, _, _} = retired(context, source, :source)
    destination = manager(context, :destination, max_agents: 1)
    assert {:ok, _} = MultiAgent.restore_child(destination, archive)
    Host.put(context, :read_barrier, {archive["admission_ref"], self()})

    resuming =
      Task.async(fn ->
        call(
          destination,
          "root-destination",
          "multi_agent_v1::resume_agent",
          %{"id" => "/root/child"},
          :v1
        )
      end)

    assert_receive {:recovery_barrier, reader}, 1_000

    assert {:ok, _} =
             call(
               destination,
               "root-destination",
               "multi_agent_v1::spawn_agent",
               %{"task_name" => "busy", "message" => "stay active"},
               :v1
             )

    assert_receive {:prepared, :destination, _, _, _}, 1_000
    assert_receive {:provider, :destination, _, _}, 1_000
    send(reader, :continue)
    assert {:error, %Error{class: :resource_conflict}} = Task.await(resuming)
    refute_receive {:prepared, :destination, _, _, _}
    assert :ok = MultiAgent.close_session(destination)
  end

  test "partial child receipts preserve sibling progress and exact receipt application emits no duplicates" do
    context = Host.new(self())
    source = manager(context, :source)
    {a, _archive, receipt, manifest} = retired(context, source, :source, "a")
    revision = elem(MultiAgent.snapshot(source), 1).revision
    assert {:ok, _} = MultiAgent.reconcile_child(source, receipt["receipt_id"])
    assert elem(MultiAgent.snapshot(source), 1).revision == revision
    assert {:ok, record} = EphemeralStore.load(context.store, a.run_id)
    assert record.run.state == :completed
    {request, provider} = spawn_child(source, :source, "b")
    complete(source, request, provider)

    assert {:ok, _} =
             call(
               source,
               "root-source",
               "multi_agent_v1::close_agent",
               %{"target" => "/root/b"},
               :v1
             )

    {:ok, snapshot} = MultiAgent.snapshot(source)
    b = Enum.find(snapshot.agents, &(&1.name == "/root/b"))
    Host.seal_inventory(context, b)
    assert {:ok, b_manifest} = MultiAgent.recovery_manifest(source, b.name)
    Host.put(context, {:evidence, "b-pending"}, Host.bundle(b_manifest, []))

    pending_request = %{
      "schema_version" => 1,
      "receipt_id" => "b-retired",
      "expected_revision" => 0,
      "subject" => b_manifest["subject"],
      "evidence_ref" => "b-pending"
    }

    assert {:error, %Error{class: :unknown_outcome}} =
             Reconciliation.reconcile(Host.config(context), pending_request)

    assert {:error, %Error{class: :unknown_outcome}} =
             MultiAgent.reconcile_child(source, "b-retired")

    assert {:ok, still_partial} = MultiAgent.snapshot(source)
    assert Enum.find(still_partial.agents, &(&1.agent_id == a.agent_id)).cleanup == :confirmed
    Host.put(context, {:evidence, "b-confirmed"}, Host.bundle(b_manifest))
    next_request = %{pending_request | "expected_revision" => 1, "evidence_ref" => "b-confirmed"}

    assert {:ok, %{"revision" => 2}} =
             Reconciliation.reconcile(Host.config(context), next_request)

    assert {:ok, %{revision: 2}} = MultiAgent.reconcile_child(source, "b-retired")
    assert {:ok, _} = MultiAgent.recovery_manifest(source, :manager)
    assert {:error, %Error{}} = MultiAgent.reconcile_close(source, receipt["receipt_id"])
    assert {:ok, current} = MultiAgent.snapshot(source)
    assert hd(current.agents).cleanup == :confirmed
    assert manifest["subject"]["identity"]["agent_id"] == a.agent_id
  end

  test "descendant import requires its parent and continuation requires fresh parent admission" do
    context = Host.new(self())
    source = manager(context, :source)
    {parent_request, parent_provider} = spawn_child(source, :source, "parent")

    assert {:ok, _} =
             call(
               source,
               parent_request.run_id,
               "multi_agent_v1::spawn_agent",
               %{"task_name" => "nested", "message" => "nested"},
               :v1
             )

    assert_receive {:prepared, :source, _, _, _}
    assert_receive {:provider, :source, nested_request, nested_provider}
    complete(source, nested_request, nested_provider)
    complete(source, parent_request, parent_provider)

    {nested, nested_archive, _, _} =
      retire_existing(context, source, :source, "/root/parent/nested")

    {parent, parent_archive, _, _} = retire_existing(context, source, :source, "/root/parent")
    destination = manager(context, :destination)

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.restore_child(destination, nested_archive)

    assert {:ok, _} = MultiAgent.restore_child(destination, parent_archive)
    assert {:ok, _} = MultiAgent.restore_child(destination, nested_archive)

    assert {:error, %Error{class: :resource_conflict}} =
             call(destination, "root-destination", "followup_task", %{
               "target" => nested.name,
               "message" => "continue nested"
             })

    refute_received {:prepared, :destination, _, _, _}

    assert {:ok, _} =
             call(destination, "root-destination", "followup_task", %{
               "target" => parent.name,
               "message" => "continue parent"
             })

    assert_receive {:prepared, :destination, _, _, _}
    assert_receive {:provider, :destination, fresh_parent, fresh_parent_provider}
    complete(destination, fresh_parent, fresh_parent_provider)

    assert {:ok, _} =
             call(destination, "root-destination", "followup_task", %{
               "target" => nested.name,
               "message" => "continue nested"
             })

    assert_receive {:prepared, :destination, _, _, %{run_id: current_parent}}
    assert current_parent == fresh_parent.run_id
    assert_receive {:provider, :destination, fresh_nested, fresh_nested_provider}
    complete(destination, fresh_nested, fresh_nested_provider)
  end

  test "failed archived admission consumes its identity and retains history for the next attempt" do
    context = Host.new(self())
    source = manager(context, :source)
    {old, archive, _, _} = retired(context, source, :source)
    attempts = :atomics.new(1, [])

    destination =
      manager(context, :destination,
        child_options: fn request, run, parent ->
          if :atomics.add_get(attempts, 1, 1) == 1 do
            send(context.test, {:refused_admission, parent.child})
            {:error, Error.new(:validation, "fixture refuses first continuation")}
          else
            Host.child_options(context, :destination, request, run, parent)
          end
        end
      )

    assert {:ok, _} = MultiAgent.restore_child(destination, archive)

    assert {:error, %Error{class: :validation}} =
             call(destination, "root-destination", "followup_task", %{
               "target" => old.name,
               "message" => "first"
             })

    assert_receive {:refused_admission, rejected}
    assert {:ok, snapshot} = MultiAgent.snapshot(destination)
    assert [%{archived: true, agent_id: id}] = snapshot.agents
    assert id == old.agent_id
    assert [%{status: :rejected, run_id: rejected_run}] = snapshot.admissions
    assert rejected_run == rejected.run_id

    assert {:ok, _} =
             call(destination, "root-destination", "followup_task", %{
               "target" => old.name,
               "message" => "second"
             })

    assert_receive {:prepared, :destination, _, run, _}
    refute run == rejected.run_id
    assert String.ends_with?(run, ":2")
    assert_receive {:provider, :destination, request, provider}
    assert Enum.any?(request.messages, &(&1[:content] == "retained answer"))
    complete(destination, request, provider)
  end

  defp seal_archive(archive) do
    archive
    |> Map.put("history_digest", Evidence.digest(Map.take(archive, ~w(messages host_feedback))))
    |> Map.put(
      "archive_id",
      "archive_" <> Evidence.digest(Map.drop(archive, ~w(archive_id archive_digest)))
    )
    |> Evidence.seal("archive_digest")
  end

  test "missing authoritative artifacts and changed historical configuration refuse import" do
    context = Host.new(self())
    Host.put(context, :artifact_refs, ["artifact:retained"])
    Host.put(context, {:evidence, "artifact:retained"}, %{"available" => true})
    source = manager(context, :source)
    {_old, archive, _, _} = retired(context, source, :source)
    destination = manager(context, :destination)
    :ets.delete(context.table, {:evidence, "artifact:retained"})
    assert {:error, %Error{class: :not_found}} = MultiAgent.restore_child(destination, archive)
    Host.put(context, {:evidence, "artifact:retained"}, %{"available" => true})
    Host.put(context, {:evidence, archive["configuration_ref"]}, %{"changed" => true})

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.restore_child(destination, archive)

    refute_received {:prepared, :destination, _, _, _}
    refute_received {:provider, :destination, _, _}
  end

  test "retired history with accepted pending mailbox work cannot be exported" do
    context = Host.new(self())
    source = manager(context, :source)
    {request, provider} = spawn_child(source, :source, "child")

    assert {:ok, %{accepted: true}} =
             call(source, "root-source", "send_message", %{
               "target" => "/root/child",
               "message" => "pending accepted work"
             })

    complete(source, request, provider)

    assert {:ok, _} =
             call(
               source,
               "root-source",
               "multi_agent_v1::close_agent",
               %{"target" => "/root/child"},
               :v1
             )

    {:ok, snapshot} = MultiAgent.snapshot(source)
    agent = hd(snapshot.agents)
    Host.seal_inventory(context, agent)
    assert {:ok, manifest} = MultiAgent.recovery_manifest(source, agent.name)
    receipt = receipt(context, manifest, "pending-work-retired")
    assert {:ok, _} = MultiAgent.reconcile_child(source, receipt["receipt_id"])

    assert {:error,
            %Error{
              class: :resource_conflict,
              message: "archive has unsettled accepted input or delivery obligations"
            }} =
             MultiAgent.export_child(source, agent.name, receipt["receipt_id"])
  end

  test "child reconciliation retains the first failed controller cleanup diagnosis" do
    context = Host.new(self(), managed: true)
    Host.put(context, :cleanup_result, {:uncertain, :fixture_lost_cleanup_ack})
    source = manager(context, :source)
    {request, provider} = spawn_child(source, :source, "child")
    complete(source, request, provider)

    assert {:error, %Error{class: :unknown_outcome}} =
             call(
               source,
               "root-source",
               "multi_agent_v1::close_agent",
               %{"target" => "/root/child"},
               :v1
             )

    assert_receive {:cleaned, :source, _}
    {:ok, before} = MultiAgent.snapshot(source)
    assert [%{cleanup: :uncertain, status: :unknown_outcome} = old] = before.agents
    Host.seal_inventory(context, old)
    {:ok, original_record} = EphemeralStore.load(context.store, old.run_id)
    assert {:ok, manifest} = MultiAgent.recovery_manifest(source, old.name)
    receipt = receipt(context, manifest, "initial-failure-retired")
    assert {:ok, _} = MultiAgent.reconcile_child(source, receipt["receipt_id"])
    assert {:ok, after_projection} = MultiAgent.snapshot(source)

    assert [
             %{
               cleanup: :confirmed,
               initial_closure: %{status: :uncertain, error_class: :unknown_outcome},
               initial_settlement_evidence: %{
                 session_close_result: %{status: :error, error_class: :unknown_outcome}
               }
             } = restored
           ] = after_projection.agents

    assert {:ok, _} = MultiAgent.reconcile_child(source, receipt["receipt_id"])
    assert {:ok, retried} = MultiAgent.snapshot(source)
    assert retried.agents == [restored]
    assert {:ok, ^original_record} = EphemeralStore.load(context.store, old.run_id)
    assert {:ok, _} = Evidence.public(restored)
    refute_received {:cleaned, :source, _}
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, remaining) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, remaining - 1)
    end
  end
end
