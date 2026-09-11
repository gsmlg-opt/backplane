defmodule Backplane.AgentRuntime.AttemptTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Attempt
  alias Backplane.AgentRuntime.Error

  describe "retry accounting" do
    test "creates a stable step and task identity" do
      {:ok, attempt} = Attempt.new("step_1", "task_1", 2)

      assert attempt.number == 0
      assert attempt.max_retries == 2
      assert attempt.status == :started
    end

    test "increments the same logical attempt and does not bypass limits" do
      {:ok, attempt} = Attempt.new("step_1", "task_1", 1)

      assert {:ok, retried, %{scheduled_for: 11}} =
               Attempt.retry(attempt, Error.new(:transient_transport, "temporary"), 10)

      assert retried.number == 1
      assert retried.step_id == attempt.step_id
      assert retried.task_id == attempt.task_id

      assert {:error, %Error{class: :timeout}} =
               Attempt.retry(retried, Error.new(:transient_transport, "again"), 12)
    end

    test "rejects missing identities and invalid retry limits" do
      assert {:error, %Error{}} = Attempt.new("", "task_1", 1)
      assert {:error, %Error{}} = Attempt.new("step_1", "task_1", -1)
    end
  end
end
