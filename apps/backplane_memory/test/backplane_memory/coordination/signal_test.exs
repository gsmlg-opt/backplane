defmodule BackplaneMemory.Coordination.SignalTest do
  use BackplaneMemory.DataCase, async: false

  alias BackplaneMemory.Coordination.Signal

  describe "send_signal/4" do
    test "inserts a signal row" do
      assert {:ok, sig} =
               Signal.send_signal("agent-a", "agent-b", "task.assigned", %{
                 "task" => "write tests"
               })

      assert sig.id != nil
      assert sig.sender_agent_id == "agent-a"
      assert sig.recipient_agent_id == "agent-b"
      assert sig.topic == "task.assigned"
      assert sig.payload == %{"task" => "write tests"}
      assert sig.read_at == nil
    end

    test "defaults payload to empty map" do
      assert {:ok, sig} = Signal.send_signal("agent-a", "agent-b", "ping")
      assert sig.payload == %{}
    end
  end

  describe "read_signals/3" do
    test "returns unread signals and marks them read atomically" do
      Signal.send_signal("agent-a", "agent-b", "hello")
      Signal.send_signal("agent-a", "agent-b", "world")

      assert {:ok, signals} = Signal.read_signals("agent-b")
      assert length(signals) == 2

      # Re-read returns empty — all marked read
      assert {:ok, []} = Signal.read_signals("agent-b")
    end

    test "does not return signals addressed to other agents" do
      Signal.send_signal("agent-a", "agent-c", "not-for-b")
      assert {:ok, []} = Signal.read_signals("agent-b")
    end

    test "topic filter returns only matching signals" do
      Signal.send_signal("agent-a", "agent-b", "task.assigned")
      Signal.send_signal("agent-a", "agent-b", "task.done")

      assert {:ok, signals} = Signal.read_signals("agent-b", "task.assigned")
      assert length(signals) == 1
      assert hd(signals).topic == "task.assigned"

      # The unread "task.done" signal remains
      assert {:ok, [remaining]} = Signal.read_signals("agent-b")
      assert remaining.topic == "task.done"
    end

    test "returns signals ordered by sent_at ascending" do
      Signal.send_signal("agent-a", "agent-b", "first")
      Signal.send_signal("agent-a", "agent-b", "second")

      assert {:ok, [s1, s2]} = Signal.read_signals("agent-b")
      assert DateTime.compare(s1.sent_at, s2.sent_at) in [:lt, :eq]
    end
  end
end
