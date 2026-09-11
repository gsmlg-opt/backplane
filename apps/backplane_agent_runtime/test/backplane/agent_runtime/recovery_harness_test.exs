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
        atomic_transition_outbox: true
      }

    @impl Backplane.AgentRuntime.Store
    def new(_incarnation), do: {:ok, :valid_durable}

    @impl Backplane.AgentRuntime.Store
    def load(_context, run_id, _opts \\ []), do: {:ok, %{run_id: run_id}}

    @impl Backplane.AgentRuntime.Store
    def store(_context, _record, _meta), do: {:ok, %{revision: 1, outbox: []}}

    @impl Backplane.AgentRuntime.Store
    def acknowledge_commit(_context, stage, _meta), do: {:ok, %{revision: stage.revision}}
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
        atomic_transition_outbox: true
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
