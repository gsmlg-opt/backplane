defmodule Backplane.AgentRuntime.ToolEffectsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.ToolEffects

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
