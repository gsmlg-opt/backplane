defmodule Backplane.AgentRuntime.MessageTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Inbox
  alias Backplane.AgentRuntime.Message

  describe "typed messages" do
    test "builds task requests and marks other kinds as non-task" do
      base = %{
        kind: :notification,
        sender: "agent_a",
        recipient: "agent_b",
        correlation_id: "correlation_1",
        payload: %{"work" => "unit"},
        expires_at: 100
      }

      assert {:ok, task} = Message.build(%{base | kind: :task_request})
      assert Message.task_request?(task)

      assert {:ok, notification} = Message.build(%{base | kind: :notification})
      refute Message.task_request?(notification)
    end

    test "rejects invalid kinds and oversized payloads" do
      base = %{
        kind: :notification,
        sender: "a",
        recipient: "b",
        correlation_id: "c",
        payload: %{"work" => "valid"},
        expires_at: 10
      }

      assert {:error, %Error{}} = Message.build(%{base | kind: :unknown})
      assert {:error, %Error{}} = Message.build(%{base | kind: :notification, payload: "invalid"})

      assert {:error, %Error{}} =
               Message.build(%{base | kind: :notification, payload: String.duplicate("x", 100)},
                 payload_limit: 1
               )
    end
  end

  defp message(correlation_id, work) do
    case Message.build(%{
           sender: "agent_a",
           recipient: "agent_b",
           kind: :notification,
           correlation_id: correlation_id,
           payload: %{"work" => work},
           expires_at: 100
         }) do
      {:ok, message} -> message
      {:error, error} -> raise error
    end
  end

  describe "bounded inbox" do
    test "deduplicates identical payloads and conflicts changed payloads" do
      {:ok, inbox} = Inbox.new(2)
      message = message("correlation_1", "same")

      assert {:ok, inbox, %{status: :accepted}} = Inbox.deliver(inbox, message)

      changed = %{message | payload: %{"work" => "changed"}}

      assert {:error, %Error{}} = Inbox.deliver(inbox, changed)
    end

    test "explicitly overflows rather than dropping or growing unbounded" do
      {:ok, inbox} = Inbox.new(1)

      assert {:ok, inbox, %{status: :accepted}} =
               Inbox.deliver(inbox, message("correlation_1", "one"))

      assert {:error, %Error{class: :overloaded}} =
               Inbox.deliver(inbox, message("correlation_2", "two"))
    end
  end
end
