defmodule Backplane.AgentRuntime.RecoveryHarnessTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.RecoveryHarness

  defmodule ValidDurableStore do
    @behaviour Backplane.AgentRuntime.Store

    @impl Backplane.AgentRuntime.Store
    def mode, do: :durable

    @impl Backplane.AgentRuntime.Store
    def capabilities,
      do: %{
        expected_revision: true,
        transition_events: true,
        outbox_intents: true,
        recovery_records: true,
        artifact_references: true,
        atomic_transition_outbox: true,
        incarnation_fencing: true
      }

    @impl Backplane.AgentRuntime.Store
    def new(_incarnation), do: {:ok, :valid_durable}

    @impl Backplane.AgentRuntime.Store
    def load(_context, run_id, _opts \\ []), do: {:ok, %{run_id: run_id}}

    @impl Backplane.AgentRuntime.Store
    def store(_context, _record, _meta), do: {:ok, %{revision: 1, outbox: []}}

    @impl Backplane.AgentRuntime.Store
    def acknowledge_commit(_context, stage, _meta), do: {:ok, %{revision: stage.revision}}

    @impl Backplane.AgentRuntime.Store
    def fence(_context, run_id, revision, _current, next) do
      {:ok,
       %{
         revision: revision + 1,
         run: %{run_id: run_id, expected_revision: revision + 1, incarnation: next}
       }}
    end
  end

  defmodule FailedDurableStore do
    @behaviour Backplane.AgentRuntime.Store

    @impl Backplane.AgentRuntime.Store
    def mode, do: :durable

    @impl Backplane.AgentRuntime.Store
    def capabilities,
      do: %{
        expected_revision: true,
        transition_events: true,
        outbox_intents: true,
        recovery_records: true,
        artifact_references: true,
        atomic_transition_outbox: true,
        incarnation_fencing: true
      }

    @impl Backplane.AgentRuntime.Store
    def new(_incarnation), do: {:ok, :failed_store}

    @impl Backplane.AgentRuntime.Store
    def load(_context, _run_id, _opts \\ []), do: {:error, :not_found}

    @impl Backplane.AgentRuntime.Store
    def store(_context, _record, _meta),
      do: {:error, Error.new(:resource_conflict, "simulated commit failure")}

    @impl Backplane.AgentRuntime.Store
    def acknowledge_commit(_context, _stage, _meta),
      do: {:error, Error.new(:resource_conflict, "simulated acknowledgement failure")}

    @impl Backplane.AgentRuntime.Store
    def fence(_context, _run_id, _revision, _current, _next),
      do: {:error, Error.new(:resource_conflict, "simulated fence failure")}
  end

  describe "generic durable recovery and storage conformance" do
    test "stages, acknowledges, and classifies recovery deterministically" do
      {:ok, context} = ValidDurableStore.new(1)

      assert {:ok, result} =
               RecoveryHarness.run(ValidDurableStore, context, base_record(), %{
                 command: {:admit, 10, %{state: :running}}
               })

      assert result.mode == :durable
      assert result.committed.revision == 1
      assert result.fence.revision == 2
      assert result.fence.run.incarnation == 1
      assert result.recovery.fenced_incarnation == 0
    end

    test "does not accept failed staged commits" do
      {:ok, context} = FailedDurableStore.new(1)

      assert {:ok, result} =
               RecoveryHarness.run_failed(
                 FailedDurableStore,
                 context,
                 base_record(),
                 %{command: {:admit, 10, %{state: :running}}}
               )

      assert result.accepted? == false
    end

    test "classifies deterministic crash windows conservatively" do
      {:ok, context} = ValidDurableStore.new(1)
      record = base_record()
      meta = %{command: {:admit, 10, %{state: :running}}}

      assert {:ok, %{accepted?: false, safe_to_resume?: true}} =
               RecoveryHarness.crash(ValidDurableStore, context, record, meta, :before_dispatch)

      assert {:ok, %{accepted?: false, safe_to_resume?: false}} =
               RecoveryHarness.crash(ValidDurableStore, context, record, meta, :after_mutation)

      assert {:ok, %{accepted?: false, safe_to_resume?: false}} =
               RecoveryHarness.crash(ValidDurableStore, context, record, meta, :before_result)

      assert {:ok, %{accepted?: true, safe_to_resume?: false}} =
               RecoveryHarness.crash(ValidDurableStore, context, record, meta, :after_terminal)

      assert {:error, %Error{class: :validation}} =
               RecoveryHarness.crash_window(:unsupported)
    end
  end

  defp base_record do
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
