defmodule Backplane.AgentRuntime.ProviderTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Provider

  defmodule MockAdapter do
    @behaviour Backplane.AgentRuntime.Provider

    @impl Backplane.AgentRuntime.Provider
    def start(request) do
      {:ok, Map.put(request, :text, "done")}
    end

    @impl Backplane.AgentRuntime.Provider
    def chunks(chunks) do
      if Enum.any?(chunks, &(&1.type == :tool_call and Map.get(&1, :tool_name) == nil)) do
        {:error, Backplane.AgentRuntime.Error.new(:malformed_result, "incomplete tool call")}
      else
        {:ok, %{type: :completed, tool_calls: []}}
      end
    end
  end

  describe "provider" do
    test "completes a model request" do
      {:ok, response} =
        Provider.start(
          MockAdapter,
          %{step_id: "step_1", attempt_id: "attempt_1"},
          %{}
        )

      assert response.response.text == "done"
    end

    test "rejects requests without step and attempt identities" do
      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Provider.start(MockAdapter, %{}, %{})
    end

    test "rejects incomplete provider streams before execution" do
      assert {:error, %Backplane.AgentRuntime.Error{class: :malformed_result}} =
               Provider.complete_stream(MockAdapter, [%{type: :tool_call, tool_name: nil}])

      assert {:ok, %{type: :completed}} =
               Provider.complete_stream(MockAdapter, [%{type: :text}])
    end
  end
end
