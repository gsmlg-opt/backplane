defmodule Backplane.AgentRuntime.ToolEffectsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.ToolEffects
  alias Backplane.AgentRuntime.Error

  defmodule RejectedAdapter do
    @behaviour Backplane.AgentRuntime.ToolEffects

    def execute(operation), do: ToolEffects.reject(operation, Error.new(:forbidden, "denied"))
    def cancel(_operation), do: :ok
  end

  describe "trusted pre-dispatch rejection" do
    test "settles an explicit rejection as a structured tool error" do
      operation = operation()
      error = Error.new(:forbidden, "approval denied")
      assert {:rejected, rejection} = ToolEffects.reject(operation, error)

      assert {:ok, %{is_error: true, error: ^error}} =
               ToolEffects.validate_rejection(rejection, operation)

      assert {:ok, %{result: %{is_error: true, error: %Error{class: :forbidden}}}} =
               ToolEffects.execute(RejectedAdapter, operation, %{})
    end

    test "cannot reclassify an unknown outcome or generic forged error details" do
      error = Error.new(:unknown_outcome, "possibly dispatched")
      assert {:error, %Error{class: :unknown_outcome}} = ToolEffects.reject(operation(), error)

      assert {:rejected, rejection} =
               ToolEffects.reject(operation(), Error.new(:forbidden, "denied"))

      assert {:error, %Error{class: :unknown_outcome}} =
               ToolEffects.validate_rejection(%{rejection | error: error}, operation())

      assert :uncertain =
               ToolEffects.settlement(
                 {:error, Error.new(:forbidden, "forged", details: %{dispatched: false})},
                 %{read_only: false}
               )
    end

    test "all operation identity and arguments fields must match exactly" do
      operation = operation()

      assert {:rejected, rejection} =
               ToolEffects.reject(operation, Error.new(:forbidden, "denied"))

      for {field, replacement} <- [
            run_id: "other",
            incarnation: 2,
            step_id: "other",
            attempt_id: "other",
            invocation_id: "other",
            tool_name: "other",
            tool_revision: 2,
            catalog_revision: 2,
            tool_call_id: "other",
            turn_id: "other",
            arguments: %{"path" => "other"}
          ] do
        assert {:error, %Error{class: :unknown_outcome}} =
                 ToolEffects.validate_rejection(rejection, Map.put(operation, field, replacement))
      end

      for field <- [
            :run_id,
            :incarnation,
            :step_id,
            :attempt_id,
            :invocation_id,
            :tool_name,
            :tool_revision,
            :arguments
          ] do
        assert {:error, %Error{class: :unknown_outcome}} =
                 ToolEffects.reject(Map.delete(operation, field), rejection.error)

        assert {:error, %Error{class: :unknown_outcome}} =
                 ToolEffects.validate_rejection(
                   %{rejection | identity: Map.delete(rejection.identity, field)},
                   Map.delete(operation, field)
                 )
      end
    end

    test "malformed rejection evidence never confirms settlement" do
      operation = operation()

      assert {:rejected, rejection} =
               ToolEffects.reject(operation, Error.new(:forbidden, "denied"))

      for forged <- [
            nil,
            %{},
            %{identity: operation, error: rejection.error},
            %{rejection | identity: nil},
            %{rejection | error: nil}
          ] do
        assert {:error, %Error{class: :unknown_outcome}} =
                 ToolEffects.validate_rejection(forged, operation)
      end
    end
  end

  defp operation do
    %{
      run_id: "run",
      incarnation: 1,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: "invocation",
      tool_name: "write",
      tool_revision: 1,
      catalog_revision: 1,
      tool_call_id: "call",
      turn_id: "turn",
      arguments: %{"path" => "x"}
    }
  end

  defmodule MockAdapter do
    @behaviour Backplane.AgentRuntime.ToolEffects

    @impl Backplane.AgentRuntime.ToolEffects
    def execute(invocation) do
      {:ok, Map.put(invocation, :completed, true)}
    end

    @impl Backplane.AgentRuntime.ToolEffects
    def cancel(_invocation), do: :ok
  end

  describe "tool effects" do
    test "executes an admitted invocation" do
      {:ok, result} =
        ToolEffects.execute(
          MockAdapter,
          %{invocation_id: "tool_1"},
          %{run_id: "run_1"}
        )

      assert result.result.completed == true
    end

    test "rejects invocations without identity" do
      assert {:error, %Backplane.AgentRuntime.Error{}} =
               ToolEffects.execute(MockAdapter, %{}, %{})
    end

    test "validates bounded output" do
      assert {:ok, %{payload: %{}}} =
               ToolEffects.validate_output(%{payload: %{}}, limit: 10)

      assert {:error, %Backplane.AgentRuntime.Error{class: :resource_conflict}} =
               ToolEffects.validate_output(%{payload: String.duplicate("x", 10)}, limit: 1)
    end
  end
end
