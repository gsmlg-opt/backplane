Code.require_file("../../../fixtures/reconciliation_file_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.Codex.ReconciliationDurableTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Error, Store}
  alias Backplane.AgentRuntime.ReconciliationFileHostFixture, as: Host

  setup do
    dir =
      Path.join(System.tmp_dir!(), "reconciliation-durable-#{System.unique_integer([:positive])}")

    {:ok, context} = Host.open(dir)

    on_exit(fn ->
      Host.cleanup(context)
      File.rm_rf!(dir)
    end)

    %{context: context, dir: dir}
  end

  test "restart preserves atomic journal/outbox, immutable evidence and incarnation CAS", ctx do
    run = %{run_id: "r", incarnation: 1, expected_revision: 0, state: :queued}

    assert {:ok, %{revision: 1}} =
             Store.store(Host, ctx.context, run, %{
               command: {:admit, 1, %{state: :running}},
               outbox: [%{intent: "one"}]
             })

    assert {:ok, first} = Host.load(ctx.context, "r")
    assert length(first.journal) == 1
    assert first.outbox == [%{intent: "one"}]
    assert :ok = Host.put(ctx.context, {:evidence, "immutable"}, %{"v" => 1})

    assert {:error, %Error{class: :resource_conflict}} =
             Host.put(ctx.context, {:evidence, "immutable"}, %{"v" => 2})

    assert {:ok, %{revision: 2, run: %{incarnation: 2}}} =
             Store.fence(Host, ctx.context, "r", 1, 1, 2)

    assert {:error, %Error{class: :resource_conflict}} =
             Store.store(Host, ctx.context, first.run, %{command: {:cancel, 2}})

    assert {:error, %Error{class: :resource_conflict}} =
             Store.fence(Host, ctx.context, "r", 1, 1, 3)

    :ok = Host.cleanup(ctx.context)
    assert {:ok, fresh} = Host.open(ctx.dir)
    assert fresh != ctx.context
    assert {:ok, %{revision: 2, run: %{incarnation: 2}, journal: [_, _]}} = Host.load(fresh, "r")
    assert {:ok, %{"v" => 1}} = Host.get(fresh, {:evidence, "immutable"})
    Host.cleanup(fresh)
  end

  test "definite refusal and committed lost ACK are distinguishable on reload", ctx do
    for {phase, fault} <- [{:usage, :refuse}, {:finish, :lose_ack}] do
      id = Atom.to_string(phase)
      run = %{run_id: id, incarnation: 1, expected_revision: 0, state: :queued}

      assert {:ok, _} =
               Store.store(Host, ctx.context, run, %{command: {:admit, 1, %{state: :running}}})

      {:ok, %{run: current}} = Host.load(ctx.context, id)

      command =
        if phase == :usage,
          do:
            {:conversation_updated, 2,
             %{run_id: id, incarnation: 1, conversation: %{usage: [%{input_tokens: 1}]}}},
          else: {:finish, 2, %{run_id: id, incarnation: 1, status: :completed, outcome: "done"}}

      assert :ok = Host.fault_next(ctx.context, phase, fault)

      assert {:error, %Error{class: :unknown_outcome}} =
               Store.store(Host, ctx.context, current, %{command: command})

      assert {:ok, persisted} = Host.load(ctx.context, id)
      assert persisted.revision == if(fault == :refuse, do: 1, else: 2)
      assert length(persisted.journal) == persisted.revision
    end
  end

  test "receipt creation and progress use a separate exact latest-request CAS", ctx do
    first = %{
      "receipt_id" => "x",
      "revision" => 1,
      "subject" => %{"owner" => "one"},
      "manifest_digest" => "m",
      "accepted_request_digest" => "a"
    }

    assert :ok = Host.fault_next(ctx.context, :receipt, :refuse)

    assert {:error, %Error{class: :unknown_outcome}} =
             Host.compare_and_swap_receipt(ctx.context, "x", 0, first)

    assert {:error, %Error{class: :not_found}} = Host.load_receipt(ctx.context, "x")
    assert :ok = Host.fault_next(ctx.context, :receipt, :lose_ack)

    assert {:error, %Error{class: :unknown_outcome}} =
             Host.compare_and_swap_receipt(ctx.context, "x", 0, first)

    assert {:ok, ^first} = Host.load_receipt(ctx.context, "x")
    assert {:ok, ^first} = Host.compare_and_swap_receipt(ctx.context, "x", 0, first)
    second = %{first | "revision" => 2, "accepted_request_digest" => "b"}
    assert {:ok, ^second} = Host.compare_and_swap_receipt(ctx.context, "x", 1, second)

    assert {:error, %Error{class: :resource_conflict}} =
             Host.compare_and_swap_receipt(ctx.context, "x", 0, first)

    assert {:error, %Error{class: :resource_conflict}} =
             Host.compare_and_swap_receipt(ctx.context, "x", 2, %{
               second
               | "revision" => 3,
                 "subject" => %{}
             })
  end
end
