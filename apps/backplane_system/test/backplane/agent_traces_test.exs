defmodule Backplane.AgentTracesTest do
  use BackplaneSystem.DataCase, async: true

  alias Backplane.AgentTraces
  alias Backplane.AgentTraces.Event

  describe "ingest/2" do
    test "persists a valid trace item" do
      host_id = create_host!("trace-host")
      item = valid_item(1)

      assert [{1, :ok}] = AgentTraces.ingest(host_id, [item])

      event = Repo.get_by!(Event, host_id: host_id, agent_seq: 1)
      assert event.trace_id == item["trace_id"]
      assert event.span_id == item["span_id"]
      assert event.parent_id == item["parent_id"]
      assert event.event == item["event"]
      assert event.measurements == item["measurements"]
      assert event.metadata == item["metadata"]
      assert event.occurred_at == ~U[2026-07-06 10:15:30.123456Z]
    end

    test "duplicate host seq is ok and idempotent" do
      host_id = create_host!("trace-duplicate")
      item = valid_item(10)

      assert [{10, :ok}] = AgentTraces.ingest(host_id, [item])
      assert [{10, :ok}] = AgentTraces.ingest(host_id, [Map.put(item, "event", "agent.changed")])

      assert [event] = Repo.all(Event)
      assert event.host_id == host_id
      assert event.agent_seq == 10
      assert event.event == "agent.started"
    end

    test "bad item returns an error without aborting the rest of the batch" do
      host_id = create_host!("trace-mixed")

      assert [
               {1, :ok},
               {2, {:error, reason}},
               {3, :ok}
             ] =
               AgentTraces.ingest(host_id, [
                 valid_item(1),
                 valid_item(2, %{"trace_id" => "not-hex"}),
                 valid_item(3)
               ])

      assert reason =~ "trace_id"
      assert Repo.aggregate(Event, :count) == 2
      assert Repo.get_by!(Event, host_id: host_id, agent_seq: 3)
    end
  end

  describe "query helpers" do
    test "list_by_trace/1 and recent/2 return ordered events" do
      host_id = create_host!("trace-query")
      trace_id = "0123456789abcdef0123456789abcdef"

      assert [{1, :ok}, {2, :ok}] =
               AgentTraces.ingest(host_id, [
                 valid_item(1, %{
                   "trace_id" => trace_id,
                   "span_id" => "1111111111111111",
                   "occurred_at" => "2026-07-06T10:00:00Z"
                 }),
                 valid_item(2, %{
                   "trace_id" => trace_id,
                   "span_id" => "2222222222222222",
                   "occurred_at" => "2026-07-06T10:05:00Z"
                 })
               ])

      assert [first, second] = AgentTraces.list_by_trace(trace_id)
      assert first.agent_seq == 1
      assert second.agent_seq == 2

      assert [recent] = AgentTraces.recent(host_id, 1)
      assert recent.agent_seq == 2
    end
  end

  defp create_host!(name) do
    now = DateTime.utc_now()
    host_id = Ecto.UUID.generate()

    {1, _rows} =
      Repo.insert_all("skill_hosts", [
        %{id: Ecto.UUID.dump!(host_id), name: name, inserted_at: now, updated_at: now}
      ])

    host_id
  end

  defp valid_item(seq, overrides \\ %{}) do
    Map.merge(
      %{
        "seq" => seq,
        "trace_id" => "0123456789abcdef0123456789abcdef",
        "span_id" => "0123456789abcdef",
        "parent_id" => "fedcba9876543210",
        "event" => "agent.started",
        "measurements" => %{"duration_ms" => 12.5},
        "metadata" => %{"tool" => "test"},
        "occurred_at" => "2026-07-06T10:15:30.123456Z"
      },
      overrides
    )
  end
end
