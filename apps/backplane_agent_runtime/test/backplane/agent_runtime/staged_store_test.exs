defmodule Backplane.AgentRuntime.StagedStoreTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.EphemeralStore
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Store

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
