defmodule Backplane.AgentRuntime.UsageTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Usage

  describe "usage accounting" do
    test "aggregates attempt reports without double counting duplicates" do
      {:ok, usage} = Usage.new()

      assert {:ok, usage, %{status: :recorded}} =
               Usage.report(usage, %{identity: "attempt_1", input_tokens: 10, output_tokens: 5})

      assert {:ok, usage, %{status: :recorded}} =
               Usage.report(usage, %{
                 identity: "attempt_2",
                 input_tokens: 2,
                 output_tokens: :unknown
               })

      assert {:ok, _usage, %{status: :duplicate}} =
               Usage.report(usage, %{identity: "attempt_1", input_tokens: 10, output_tokens: 5})

      assert Usage.totals(usage) == %{
               input_tokens: 12,
               output_tokens: 5,
               cached_tokens: 0,
               reasoning_tokens: 0
             }
    end

    test "keeps missing values unknown instead of zero" do
      {:ok, usage} = Usage.new()

      assert {:ok, usage, %{status: :recorded}} =
               Usage.report(usage, %{identity: "attempt_1", output_tokens: nil})

      assert Usage.totals(usage).output_tokens == 0
    end

    test "tracks context occupancy separately from lifetime totals" do
      {:ok, usage} = Usage.new()

      assert {:ok, usage, %{status: :recorded}} =
               Usage.report(usage, %{
                 identity: "attempt_1",
                 context_id: "context_1",
                 occupancy_tokens: 120
               })

      assert usage.occupancy["context_1"] == 120
    end
  end
end
