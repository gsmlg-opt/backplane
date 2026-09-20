defmodule Backplane.AgentRuntime.DurableConformanceTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Store

  defmodule ValidDurableStore do
    @behaviour Backplane.AgentRuntime.Store

    @impl Backplane.AgentRuntime.Store
    def mode, do: :durable

    @impl Backplane.AgentRuntime.Store
    def capabilities do
      %{
        expected_revision: true,
        transition_events: true,
        outbox_intents: true,
        recovery_records: true,
        artifact_references: true,
        atomic_transition_outbox: true,
        incarnation_fencing: true
      }
    end

    @impl Backplane.AgentRuntime.Store
    def new(_incarnation), do: {:ok, :valid_durable}

    @impl Backplane.AgentRuntime.Store
    def load(_context, run_id, _opts \\ []), do: {:ok, %{run_id: run_id}}

    @impl Backplane.AgentRuntime.Store
    def store(_context, record, _meta) do
      {:ok, %{revision: record.expected_revision + 1, outbox: []}}
    end

    @impl Backplane.AgentRuntime.Store
    def acknowledge_commit(_context, stage, _meta) do
      {:ok, %{revision: stage.revision}}
    end

    @impl Backplane.AgentRuntime.Store
    def fence(_context, run_id, revision, _current, next) do
      {:ok,
       %{
         revision: revision + 1,
         run: %{run_id: run_id, expected_revision: revision + 1, incarnation: next}
       }}
    end
  end

  defmodule InvalidDurableStore do
    @behaviour Backplane.AgentRuntime.Store

    @impl Backplane.AgentRuntime.Store
    def mode, do: :durable

    @impl Backplane.AgentRuntime.Store
    def capabilities, do: %{expected_revision: true, transition_events: true}

    @impl Backplane.AgentRuntime.Store
    def new(_incarnation), do: {:ok, :invalid}

    @impl Backplane.AgentRuntime.Store
    def load(_context, run_id, _opts \\ []), do: {:ok, %{run_id: run_id}}

    @impl Backplane.AgentRuntime.Store
    def store(_context, _record, _meta), do: {:ok, %{revision: 1, outbox: []}}

    @impl Backplane.AgentRuntime.Store
    def acknowledge_commit(_context, _stage, _meta), do: {:ok, %{revision: 1}}
  end

  describe "durable conformance" do
    test "accepts a conforming durable adapter contract" do
      run = %{
        run_id: "run_1",
        expected_revision: 0,
        state: :queued,
        deadline: nil,
        outcome: nil,
        children: []
      }

      {:ok, context} = ValidDurableStore.new(1)

      assert {:ok, %{revision: 1, mode: :durable}} =
               Store.store(
                 ValidDurableStore,
                 context,
                 run,
                 %{command: {:admit, 10, %{state: :running}}}
               )
    end

    test "rejects a durable adapter missing required capabilities" do
      {:ok, context} = InvalidDurableStore.new(1)
      run = %{expected_revision: 0}

      assert {:error, %Error{class: :unsupported_capability}} =
               Store.store(
                 InvalidDurableStore,
                 context,
                 run,
                 %{command: {:admit, 10, %{}}}
               )
    end

    test "does not acknowledge acceptance or dispatch effects on failed/stalled commits" do
      run = %{
        run_id: "run_failure",
        expected_revision: 0,
        state: :queued,
        deadline: nil,
        outcome: nil,
        children: []
      }

      {:ok, context} = ValidDurableStore.new(1)
      command = {:admit, 10, %{state: :running}}

      assert {:error, %Error{class: :resource_conflict}} =
               Store.store(__MODULE__.FailedStore, context, run, %{command: command})

      assert {:error, %Error{class: :timeout}} =
               Store.store(__MODULE__.StalledStore, context, run, %{command: command})

      assert {:error, :load_not_found} =
               __MODULE__.FailedStore.load(context, run.run_id)
    end
  end

  defmodule FailedStore do
    @behaviour Backplane.AgentRuntime.Store

    @impl Backplane.AgentRuntime.Store
    def mode, do: :durable

    @impl Backplane.AgentRuntime.Store
    def capabilities, do: ValidDurableStore.capabilities()

    @impl Backplane.AgentRuntime.Store
    def new(_incarnation), do: {:ok, :failed_store}

    @impl Backplane.AgentRuntime.Store
    def load(_context, _run_id, _opts \\ []), do: {:error, :load_not_found}

    @impl Backplane.AgentRuntime.Store
    def store(_context, _record, _meta),
      do: {:error, Error.new(:resource_conflict, "simulated commit failure")}

    @impl Backplane.AgentRuntime.Store
    def acknowledge_commit(_context, _stage, _meta), do: {:ok, %{revision: 1}}
  end

  defmodule StalledStore do
    @behaviour Backplane.AgentRuntime.Store

    @impl Backplane.AgentRuntime.Store
    def mode, do: :durable

    @impl Backplane.AgentRuntime.Store
    def capabilities, do: ValidDurableStore.capabilities()

    @impl Backplane.AgentRuntime.Store
    def new(_incarnation), do: {:ok, :stalled_store}

    @impl Backplane.AgentRuntime.Store
    def load(_context, _run_id, _opts \\ []), do: {:error, :load_not_found}

    @impl Backplane.AgentRuntime.Store
    def store(_context, _record, _meta),
      do: {:error, Error.new(:timeout, "simulated stalled acknowledgement")}

    @impl Backplane.AgentRuntime.Store
    def acknowledge_commit(_context, _stage, _meta), do: {:ok, %{revision: 1}}
  end
end
