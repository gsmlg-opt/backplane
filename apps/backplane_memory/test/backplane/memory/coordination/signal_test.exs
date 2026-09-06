defmodule Backplane.Memory.Coordination.SignalTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Audit, Coordination.Signal}

  @partition %{
    memory_space_id: "febb4342-0651-19bb-3dc3-b1d4f6246261",
    host_id: "signal-host",
    client_id: "host:signal-host",
    source_client_id: "host:signal-host",
    scope: "signal-scope",
    namespace: "private"
  }

  setup do
    assert Backplane.Memory.IngestFixtures.ensure_memory_space!(@partition.host_id) ==
             @partition.memory_space_id

    :ok
  end

  describe "send_signal/4" do
    test "inserts a signal row" do
      assert {:ok, sig} =
               send_signal("agent-a", "agent-b", "task.assigned", %{"task" => "write tests"})

      assert sig.id != nil
      assert sig.sender_agent_id == "agent-a"
      assert sig.recipient_agent_id == "agent-b"
      assert sig.topic == "task.assigned"
      assert sig.payload == %{"task" => "write tests"}
      assert sig.read_at == nil

      assert [%{operation: "coordination.signal.send", target_ids: [signal_id]}] =
               Audit.list(operation: "coordination.signal.send")

      assert signal_id == sig.id
    end

    test "defaults payload to empty map" do
      assert {:ok, sig} = send_signal("agent-a", "agent-b", "ping")
      assert sig.payload == %{}
    end
  end

  describe "read_signals/3" do
    test "returns unread signals and marks them read atomically" do
      send_signal("agent-a", "agent-b", "hello")
      send_signal("agent-a", "agent-b", "world")

      assert {:ok, signals} = read_signals("agent-b")
      assert length(signals) == 2

      assert [%{operation: "coordination.signal.read", target_ids: target_ids}] =
               Audit.list(operation: "coordination.signal.read")

      assert MapSet.new(target_ids) == MapSet.new(signals, & &1.id)

      # Re-read returns empty — all marked read
      assert {:ok, []} = read_signals("agent-b")
    end

    test "does not return signals addressed to other agents" do
      send_signal("agent-a", "agent-c", "not-for-b")
      assert {:ok, []} = read_signals("agent-b")
    end

    test "topic filter returns only matching signals" do
      send_signal("agent-a", "agent-b", "task.assigned")
      send_signal("agent-a", "agent-b", "task.done")

      assert {:ok, signals} = read_signals("agent-b", "task.assigned")
      assert length(signals) == 1
      assert hd(signals).topic == "task.assigned"

      # The unread "task.done" signal remains
      assert {:ok, [remaining]} = read_signals("agent-b")
      assert remaining.topic == "task.done"
    end

    test "returns signals ordered by sent_at ascending" do
      send_signal("agent-a", "agent-b", "first")
      send_signal("agent-a", "agent-b", "second")

      assert {:ok, [s1, s2]} = read_signals("agent-b")
      assert DateTime.compare(s1.sent_at, s2.sent_at) in [:lt, :eq]
    end

    test "concurrent pollers consume and audit each signal once" do
      for index <- 1..20, do: send_signal("agent-a", "agent-b", "signal-#{index}")

      results =
        1..2
        |> Task.async_stream(fn _ -> read_signals("agent-b", nil, 20) end,
          max_concurrency: 2,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, {:ok, signals}} -> signals end)

      assert results |> List.flatten() |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 20

      read_audits = Audit.list(operation: "coordination.signal.read")
      audited_ids = read_audits |> Enum.flat_map(& &1.target_ids)
      assert length(audited_ids) == 20
      assert length(Enum.uniq(audited_ids)) == 20
    end
  end

  defp send_signal(sender, recipient, topic, payload \\ %{}),
    do: Signal.send_signal(sender, recipient, topic, payload, @partition)

  defp read_signals(agent, topic \\ nil, limit \\ 20),
    do: Signal.read_signals(agent, topic, limit, @partition)
end
