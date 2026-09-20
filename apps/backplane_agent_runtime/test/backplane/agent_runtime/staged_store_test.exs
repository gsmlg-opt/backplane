defmodule Backplane.AgentRuntime.StagedStoreTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.EphemeralStore
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Store

  defmodule ScriptedAcknowledgementStore do
    @behaviour Store

    @impl Store
    def mode, do: :ephemeral

    @impl Store
    def capabilities do
      %{expected_revision: true, transition_events: true, outbox_intents: true}
    end

    @impl Store
    def new(_incarnation), do: {:ok, nil}

    @impl Store
    def load(_context, _run_id, _opts), do: {:error, Error.new(:not_found, "not stored")}

    @impl Store
    def store(_context, _record, _meta), do: {:ok, %{revision: 1, outbox: []}}

    @impl Store
    def acknowledge_commit(_context, stage, %{acknowledgement: :wrong_revision}) do
      {:ok, %{revision: stage.revision + 1}}
    end

    def acknowledge_commit(_context, _stage, %{acknowledgement: :bare_map}) do
      %{revision: 1}
    end
  end

  describe "staged asynchronous commits" do
    test "stage records intent without durable acceptance" do
      {:ok, store} = EphemeralStore.new(System.unique_integer([:positive]))
      run = base_run()

      assert {:ok, staged} =
               Store.stage(
                 EphemeralStore,
                 store,
                 run,
                 %{command: {:admit, 10, %{state: :running}}}
               )

      assert staged.revision == 1
      assert staged.stage.transition.state == :running
      assert {:error, %Error{class: :not_found}} = EphemeralStore.load(store, run.run_id)
    end

    test "stage inherits the authoritative run incarnation when metadata omits it" do
      {:ok, store} = EphemeralStore.new(System.unique_integer([:positive]))
      run = Map.put(base_run(), :incarnation, 7)

      assert {:ok, %{stage: %{incarnation: 7, run: %{incarnation: 7}}}} =
               Store.stage(EphemeralStore, store, run, %{
                 command: {:admit, 10, %{state: :running}}
               })
    end

    test "acknowledged stage makes the transition durable in ephemeral mode" do
      {:ok, store} = EphemeralStore.new(System.unique_integer([:positive]))
      run = base_run()

      {:ok, staged} =
        Store.stage(EphemeralStore, store, run, %{command: {:admit, 10, %{state: :running}}})

      assert {:ok, committed} =
               Store.acknowledge_commit(EphemeralStore, store, staged.stage, %{})

      assert committed.revision == 1
      assert {:ok, loaded} = EphemeralStore.load(store, run.run_id)
      assert loaded.run.state == :running
      assert loaded.revision == 1
    end

    test "rejects invalid stage records" do
      {:ok, store} = EphemeralStore.new(System.unique_integer([:positive]))

      assert {:error, %Error{class: :validation}} =
               Store.acknowledge_commit(EphemeralStore, store, %{}, %{})
    end

    test "does not dispatch or acknowledge on failed staged commits" do
      {:ok, store} = EphemeralStore.new(System.unique_integer([:positive]))
      run = base_run()

      assert {:ok, staged} =
               Store.stage(
                 EphemeralStore,
                 store,
                 run,
                 %{command: {:admit, 10, %{state: :running}}}
               )

      assert {:error, %Error{class: :validation}} =
               Store.acknowledge_commit(
                 EphemeralStore,
                 store,
                 %{staged.stage | run: nil},
                 %{}
               )

      assert {:error, %Error{class: :not_found}} = EphemeralStore.load(store, run.run_id)
    end

    test "a stale staged acknowledgement cannot replace a newer commit" do
      {:ok, store} = EphemeralStore.new(System.unique_integer([:positive]))
      run = base_run()

      {:ok, _} =
        EphemeralStore.store(store, run, %{command: {:admit, 10, %{state: :running}}})

      {:ok, loaded} = EphemeralStore.load(store, run.run_id)

      {:ok, staged} =
        Store.stage(EphemeralStore, store, loaded.run, %{command: {:cancel, 11}})

      stale_stage = %{staged.stage | run: Map.put(staged.stage.run, :stale_marker, true)}

      assert {:ok, %{revision: 2}} =
               EphemeralStore.store(store, loaded.run, %{command: {:cancel, 12}})

      assert {:error, %Error{class: :resource_conflict}} =
               Store.acknowledge_commit(EphemeralStore, store, stale_stage, %{})

      assert {:ok, current} = EphemeralStore.load(store, run.run_id)
      assert current.revision == 2
      assert current.run.state == :cancelling
      refute Map.has_key?(current.run, :stale_marker)
    end

    test "rejects invalid acknowledgement shapes and revisions" do
      {:ok, store} = EphemeralStore.new(System.unique_integer([:positive]))
      run = base_run()

      {:ok, staged} =
        Store.stage(EphemeralStore, store, run, %{command: {:admit, 10, %{state: :running}}})

      assert {:error, %Error{class: :resource_conflict}} =
               Store.acknowledge_commit(
                 ScriptedAcknowledgementStore,
                 nil,
                 staged.stage,
                 %{acknowledgement: :wrong_revision}
               )

      assert {:error, %Error{class: :execution_failure}} =
               Store.acknowledge_commit(
                 ScriptedAcknowledgementStore,
                 nil,
                 staged.stage,
                 %{acknowledgement: :bare_map}
               )

      assert {:error, %Error{class: :not_found}} = EphemeralStore.load(store, run.run_id)
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
