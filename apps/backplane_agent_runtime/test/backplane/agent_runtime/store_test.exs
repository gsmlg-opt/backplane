defmodule Backplane.AgentRuntime.StoreTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.EphemeralStore
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Kernel
  alias Backplane.AgentRuntime.Store

  defmodule ScriptedStore do
    @behaviour Store

    @impl Store
    def mode, do: :ephemeral

    @impl Store
    def capabilities,
      do: %{expected_revision: true, transition_events: true, outbox_intents: true}

    @impl Store
    def new(_incarnation), do: {:ok, nil}

    @impl Store
    def load(_context, _run_id, _opts), do: {:error, Error.new(:not_found, "not stored")}

    @impl Store
    def store(_context, _record, %{acknowledgement: :wrong_revision}),
      do: {:ok, %{revision: 2, outbox: []}}

    def store(_context, _record, %{acknowledgement: :missing_outbox}),
      do: {:ok, %{revision: 1}}

    @impl Store
    def acknowledge_commit(_context, _stage, _meta), do: {:ok, %{revision: 1}}
  end

  describe "contract" do
    test "executes a kernel transition and exposes async discipline" do
      {:ok, store} = EphemeralStore.new(System.unique_integer([:positive]))
      run = base_run()
      command = {:admit, 10, %{state: :running, input: %{"message" => "hi"}}}
      {:ok, _run, _transition, []} = Kernel.execute(run, command)

      assert {:ok, %{revision: 1, outbox: [], mode: :ephemeral}} =
               Backplane.AgentRuntime.Store.store(
                 EphemeralStore,
                 store,
                 %{run | expected_revision: 0},
                 %{command: command}
               )

      assert {:ok, loaded} = EphemeralStore.load(store, run.run_id)
      assert loaded.run.state == :running
      assert loaded.revision == 1
      assert loaded.ephemeral == true
    end

    test "rejects stale and duplicate compare-and-set commits" do
      {:ok, store} = EphemeralStore.new(System.unique_integer([:positive]))
      run = base_run()
      command = {:admit, 10, %{state: :running}}
      {:ok, _run, _transition, []} = Kernel.execute(run, command)

      {:ok, _} = EphemeralStore.store(store, %{run | expected_revision: 0}, %{command: command})

      assert {:error, %Error{class: :resource_conflict}} =
               EphemeralStore.store(store, %{run | expected_revision: 0}, %{command: command})

      assert {:error, %Error{class: :resource_conflict}} =
               EphemeralStore.store(store, %{run | expected_revision: 2}, %{command: command})
    end

    test "stores multiple successive transitions for one run" do
      {:ok, store} = EphemeralStore.new(System.unique_integer([:positive]))
      run = base_run()

      assert {:ok, %{revision: 1}} =
               EphemeralStore.store(store, run, %{
                 command: {:admit, 10, %{state: :running, input: %{"step" => 1}}}
               })

      assert {:ok, first} = EphemeralStore.load(store, run.run_id)

      assert {:ok, %{revision: 2}} =
               EphemeralStore.store(store, first.run, %{command: {:cancel, 11}})

      assert {:ok, second} = EphemeralStore.load(store, run.run_id)
      assert second.revision == 2
      assert second.run.expected_revision == 2
      assert second.run.state == :cancelling
      assert second.run.input == %{"step" => 1}
    end

    test "only one competing commit at the same revision is stored" do
      {:ok, store} = EphemeralStore.new(System.unique_integer([:positive]))
      run = base_run()
      parent = self()

      tasks =
        for contender <- ["first", "second"] do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :commit ->
                {contender,
                 EphemeralStore.store(store, run, %{
                   command: {:admit, 10, %{state: :running, input: %{"contender" => contender}}}
                 })}
            end
          end)
        end

      pids =
        for _ <- tasks do
          assert_receive {:ready, pid}
          pid
        end

      Enum.each(pids, &send(&1, :commit))
      results = Enum.map(tasks, &Task.await/1)

      assert [{winner, {:ok, %{revision: 1}}}] =
               Enum.filter(results, fn {_contender, result} -> match?({:ok, _}, result) end)

      assert [{_loser, {:error, %Error{class: :resource_conflict}}}] =
               Enum.filter(results, fn {_contender, result} -> match?({:error, _}, result) end)

      assert {:ok, loaded} = EphemeralStore.load(store, run.run_id)
      assert loaded.revision == 1
      assert loaded.run.input == %{"contender" => winner}
    end

    test "kernel rejection is not a durable acknowledgement" do
      {:ok, store} = EphemeralStore.new(System.unique_integer([:positive]))
      run = base_run()

      assert {:error, %Error{class: :validation}} =
               EphemeralStore.store(
                 store,
                 %{run | expected_revision: 0, state: :completed},
                 %{command: {:admit, 10, %{}}}
               )

      assert {:error, %Error{class: :not_found}} = EphemeralStore.load(store, run.run_id)
    end

    test "rejects invalid synchronous store acknowledgement shapes and revisions" do
      run = base_run()

      assert {:error, %Error{class: :resource_conflict}} =
               Store.store(ScriptedStore, nil, run, %{acknowledgement: :wrong_revision})

      assert {:error, %Error{class: :execution_failure}} =
               Store.store(ScriptedStore, nil, run, %{acknowledgement: :missing_outbox})
    end
  end

  describe "mode disclosure" do
    test "declares ephemeral restart loss and missing durable features" do
      assert EphemeralStore.mode() == :ephemeral

      capabilities = EphemeralStore.capabilities()

      assert capabilities.restart_loss == true
      assert capabilities.recovery_records == false
      assert capabilities.artifact_references == false
    end
  end

  defp base_run do
    %{
      run_id: "run_#{System.unique_integer([:positive])}",
      expected_revision: 0,
      state: :queued,
      deadline: nil,
      outcome: nil,
      children: []
    }
  end
end
