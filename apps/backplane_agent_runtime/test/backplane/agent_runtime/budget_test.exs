defmodule Backplane.AgentRuntime.BudgetTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Budget

  describe "reservations" do
    test "reserves within quota and rejects excess work" do
      {:ok, budget} = Budget.new(%{root_run_id: "run_root", work: 2})

      assert {:ok, budget, %{status: :reserved, amount: 1}} =
               Budget.reserve(budget, "reservation_1")

      assert {:error, %Backplane.AgentRuntime.Error{class: :budget_exceeded}} =
               Budget.reserve(budget, "reservation_2", 2)

      assert {:ok, budget, %{status: :reserved, amount: 1}} =
               Budget.reserve(budget, "reservation_2")

      assert budget.used == 2
    end

    test "replays reservations idempotently and rejects changed amounts" do
      {:ok, budget} = Budget.new(%{work: 3})
      {:ok, reserved, receipt} = Budget.reserve(budget, "same", 2)

      assert {:ok, ^reserved, ^receipt} = Budget.reserve(reserved, "same", 2)

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Budget.reserve(reserved, "reservation_1", 2)
    end

    test "releases capacity once after reconciliation" do
      {:ok, budget} = Budget.new(%{work: 2})
      {:ok, reserved, _} = Budget.reserve(budget, "reservation_1", 2)

      assert {:ok, released} = Budget.release(reserved, "reservation_1")
      assert released.used == 0

      assert {:error, %Backplane.AgentRuntime.Error{class: :not_found}} =
               Budget.release(released, "reservation_1")
    end

    test "rejects missing or invalid quota" do
      assert {:error, %Backplane.AgentRuntime.Error{}} = Budget.new(%{})
      assert {:error, %Backplane.AgentRuntime.Error{}} = Budget.new("invalid")
    end
  end
end
