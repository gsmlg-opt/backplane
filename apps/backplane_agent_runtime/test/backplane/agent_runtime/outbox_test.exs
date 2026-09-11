defmodule Backplane.AgentRuntime.OutboxTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Outbox

  describe "sender intent outbox" do
    test "replays identical submission IDs and conflicts changed payloads" do
      {:ok, outbox} = Outbox.new(2)

      assert {:ok, outbox, %{status: :submitted, submission_id: "submission_1"}} =
               Outbox.submit(outbox, "submission_1", %{"work" => "same"})

      assert {:ok, _outbox, %{status: :submitted}} =
               Outbox.submit(outbox, "submission_1", %{"work" => "same"})

      assert {:error, %Error{class: :resource_conflict}} =
               Outbox.submit(outbox, "submission_1", %{"work" => "changed"})
    end

    test "explicitly overflows rather than dropping live idempotency state" do
      {:ok, outbox} = Outbox.new(1)

      assert {:ok, outbox, %{status: :submitted}} =
               Outbox.submit(outbox, "submission_1", %{"work" => "one"})

      assert {:error, %Error{class: :overloaded}} =
               Outbox.submit(outbox, "submission_2", %{"work" => "two"})

      assert {:ok, _outbox, %{status: :submitted}} =
               Outbox.submit(outbox, "submission_1", %{"work" => "one"})
    end

    test "replays bounded submission IDs and exposes cursor expiry" do
      {:ok, outbox} = Outbox.new(2)
      {:ok, outbox, _} = Outbox.submit(outbox, "submission_1", %{"work" => "one"})
      {:ok, outbox, _} = Outbox.submit(outbox, "submission_2", %{"work" => "two"})

      assert {:ok, ["submission_1", "submission_2"]} = Outbox.replay(outbox, 1)

      assert {:ok, ["submission_1", "submission_2"]} = Outbox.replay(outbox, 0)
    end
  end
end
