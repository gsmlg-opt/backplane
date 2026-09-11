defmodule Backplane.AgentRuntime.SubscriberTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Subscriber

  describe "bounded subscriptions" do
    test "appends events and replays retained events by cursor" do
      {:ok, subscriber} = Subscriber.new(2)

      assert {:ok, subscriber} =
               Subscriber.append(subscriber, %{
                 event_id: "event_1",
                 aggregate_id: "run_1",
                 sequence: 0,
                 type: "run.started",
                 occurred_at: 10
               })

      assert {:ok, subscriber} =
               Subscriber.append(subscriber, %{
                 event_id: "event_2",
                 aggregate_id: "run_1",
                 sequence: 1,
                 type: "run.running",
                 occurred_at: 11
               })

      assert {:ok, [%{event_id: "event_2"}], _cursor} = Subscriber.replay(subscriber, 1)
    end

    test "reports gap markers for expired cursors" do
      {:ok, subscriber} = Subscriber.new(1)

      assert {:ok, subscriber} =
               Subscriber.append(subscriber, %{
                 event_id: "event_1",
                 aggregate_id: "run_1",
                 sequence: 5,
                 type: "run.started",
                 occurred_at: 10
               })

      assert {:ok, %{gap: false, from: 6}} = Subscriber.gap(subscriber, 6)

      assert {:ok, %{gap: true, from: 6}} = Subscriber.gap(subscriber, 5)
    end

    test "rejects invalid event envelopes" do
      {:ok, subscriber} = Subscriber.new(1)

      assert {:error, %Error{}} =
               Subscriber.append(subscriber, %{
                 event_id: "event_1",
                 aggregate_id: "run_1",
                 sequence: 0,
                 type: "run.started",
                 occurred_at: -1
               })
    end
  end
end
