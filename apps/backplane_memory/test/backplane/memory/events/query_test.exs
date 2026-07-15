defmodule Backplane.Memory.Events.QueryTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Events
  alias Backplane.Memory.Events.{Event, Store, Stream}

  describe "range/2" do
    test "returns an inclusive stream-local range in sequence order" do
      stream_id = unique("range")

      for content <- ["one", "two", "three", "four"] do
        append!(%{stream_id: stream_id, event_type: "task.updated", content: content})
      end

      assert {:ok, events} = Events.range(stream_id, 2..3)
      assert Enum.map(events, &{&1.sequence, &1.content}) == [{2, "two"}, {3, "three"}]
      assert {:ok, []} = Events.range(unique("missing"), 1..10)
      assert {:ok, []} = Events.range(stream_id, 20..30)
    end

    test "rejects invalid stream IDs and non-positive, descending, or stepped ranges" do
      max_bigint = 9_223_372_036_854_775_807

      assert {:error, :invalid_stream_id} = Events.range("", 1..2)
      assert {:error, :invalid_stream_id} = Events.range(nil, 1..2)
      assert {:error, :invalid_range} = Events.range("stream", 0..2)
      assert {:error, :invalid_range} = Events.range("stream", 3..1//-1)
      assert {:error, :invalid_range} = Events.range("stream", 1..5//2)
      assert {:error, :invalid_range} = Events.range("stream", :not_a_range)
      assert {:ok, []} = Events.range(unique("bigint-boundary"), max_bigint..max_bigint)
      assert {:error, :invalid_range} = Events.range("stream", 1..(max_bigint + 1))
    end
  end

  describe "timeline/1" do
    test "orders globally by occurred_at DESC and id DESC" do
      project = unique("ordering")
      occurred_at = ~U[2026-07-16 00:00:00.000000Z]

      lower =
        append!(%{
          id: "00000000-0000-4000-8000-000000000001",
          stream_id: unique("lower"),
          event_type: "task.created",
          project: project,
          occurred_at: occurred_at
        })

      higher =
        append!(%{
          id: "00000000-0000-4000-8000-000000000002",
          stream_id: unique("higher"),
          event_type: "task.updated",
          project: project,
          occurred_at: occurred_at
        })

      newest =
        append!(%{
          id: "00000000-0000-4000-8000-000000000003",
          stream_id: unique("newest"),
          event_type: "task.completed",
          project: project,
          occurred_at: DateTime.add(occurred_at, 1, :second)
        })

      assert {:ok, %{events: events, next_cursor: nil}} =
               Events.timeline(project: project)

      assert Enum.map(events, & &1.id) == [newest.id, higher.id, lower.id]
    end

    test "supports every identity/type/tool filter with atom and string keys" do
      marker = unique("filters")
      occurred_at = ~U[2026-07-16 01:00:00.000000Z]

      target =
        append!(%{
          stream_id: marker <> ":stream",
          event_type: "tool.call.completed",
          project: marker <> ":project",
          agent_id: marker <> ":agent",
          session_id: marker <> ":session",
          run_id: marker <> ":run",
          tool_name: marker <> ":tool",
          occurred_at: occurred_at
        })

      append!(%{
        stream_id: marker <> ":other-stream",
        event_type: "tool.call.failed",
        project: marker <> ":other-project",
        agent_id: marker <> ":other-agent",
        session_id: marker <> ":other-session",
        run_id: marker <> ":other-run",
        tool_name: marker <> ":other-tool",
        occurred_at: occurred_at
      })

      for {filter, value} <- [
            stream: target.stream_id,
            project: target.project,
            agent: target.agent_id,
            session: target.session_id,
            run: target.run_id,
            type: target.event_type,
            tool: target.tool_name
          ] do
        assert {:ok, %{events: [%Event{id: id}]}} = Events.timeline([{filter, value}])
        assert id == target.id

        assert {:ok, %{events: [%Event{id: string_id}]}} =
                 Events.timeline(%{Atom.to_string(filter) => value})

        assert string_id == target.id
      end
    end

    test "rejects non-string equality filters instead of raising query cast errors" do
      for filter <- [:stream, :project, :agent, :session, :run, :type, :tool],
          invalid <- [%{}, ["value"], 123, <<255>>] do
        assert {:error, :invalid_filters} = Events.timeline([{filter, invalid}])
      end

      assert {:error, :invalid_filters} = Events.timeline(unknown: "value")
    end

    test "applies inclusive from/to bounds from DateTime and ISO-8601 values" do
      project = unique("bounds")
      lower = ~U[2026-07-16 02:00:00.000000Z]
      middle = DateTime.add(lower, 1, :second)
      upper = DateTime.add(lower, 2, :second)

      for {time, content} <- [{lower, "lower"}, {middle, "middle"}, {upper, "upper"}] do
        append!(%{
          stream_id: unique("bounds-stream"),
          event_type: "task.updated",
          project: project,
          content: content,
          occurred_at: time
        })
      end

      assert {:ok, %{events: events}} =
               Events.timeline(%{
                 "project" => project,
                 "from" => DateTime.to_iso8601(lower),
                 "to" => upper
               })

      assert Enum.map(events, & &1.content) == ["upper", "middle", "lower"]
      assert {:error, :invalid_time} = Events.timeline(project: project, from: "not-a-time")
    end

    test "defaults to 100, caps at 500, and rejects invalid limits" do
      project = unique("limits")

      attrs =
        for n <- 1..501 do
          %{
            stream_id: project <> ":stream",
            event_type: "task.updated",
            project: project,
            content: Integer.to_string(n)
          }
        end

      assert {:ok, _events} = Store.append_batch(attrs, telemetry: false)

      assert {:ok, %{events: default_page, next_cursor: default_cursor}} =
               Events.timeline(project: project)

      assert length(default_page) == 100
      assert is_binary(default_cursor)

      assert {:ok, %{events: capped_page, next_cursor: capped_cursor}} =
               Events.timeline(project: project, limit: 999)

      assert length(capped_page) == 500
      assert is_binary(capped_cursor)

      for limit <- [0, -1, 1.5, "10"] do
        assert {:error, :invalid_limit} = Events.timeline(project: project, limit: limit)
      end
    end

    test "paginates tied timestamps without gaps or duplicates" do
      project = unique("pages")
      occurred_at = ~U[2026-07-16 03:00:00.000000Z]

      ids =
        for suffix <- 1..5 do
          id = "00000000-0000-4000-8000-#{String.pad_leading(Integer.to_string(suffix), 12, "0")}"

          append!(%{
            id: id,
            stream_id: unique("page-stream"),
            event_type: "task.updated",
            project: project,
            occurred_at: occurred_at
          })

          id
        end

      assert {:ok, %{events: first, next_cursor: cursor_1}} =
               Events.timeline(project: project, limit: 2)

      assert is_binary(cursor_1)

      assert {:ok, %{events: second, next_cursor: cursor_2}} =
               Events.timeline(project: project, limit: 2, cursor: cursor_1)

      assert is_binary(cursor_2)

      assert {:ok, %{events: third, next_cursor: nil}} =
               Events.timeline(project: project, limit: 2, cursor: cursor_2)

      paged_ids = Enum.map(first ++ second ++ third, & &1.id)
      assert paged_ids == Enum.sort(ids, :desc)
      assert length(Enum.uniq(paged_ids)) == 5
    end

    test "rejects malformed cursors at every decoding layer" do
      malformed = [
        "!!!",
        encode_cursor("not-json"),
        encode_cursor(Jason.encode!(%{})),
        encode_cursor(Jason.encode!(%{"occurred_at" => "bad", "id" => Ecto.UUID.generate()})),
        encode_cursor(
          Jason.encode!(%{
            "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
            "id" => "not-a-uuid"
          })
        )
      ]

      for cursor <- malformed do
        assert {:error, :invalid_cursor} = Events.timeline(cursor: cursor)
      end
    end
  end

  describe "close_stream/1" do
    test "does not create unknown streams and preserves the first close timestamp" do
      missing = unique("missing-close")
      assert {:error, :not_found} = Events.close_stream(missing)
      refute repo().get(Stream, missing)

      stream_id = unique("close")
      append!(%{stream_id: stream_id, event_type: "session.started"})

      assert {:ok, first} = Events.close_stream(stream_id)
      assert %DateTime{} = first.closed_at
      assert {:ok, second} = Events.close_stream(stream_id)
      assert second.closed_at == first.closed_at
    end

    test "a later outer Multi failure rolls back stream closure" do
      stream_id = unique("close-rollback")
      append!(%{stream_id: stream_id, event_type: "session.started"})

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:close, fn repo, _changes ->
          Store.close_stream(stream_id, repo: repo)
        end)
        |> Ecto.Multi.run(:later, fn _repo, _changes -> {:error, :deliberate_failure} end)

      assert {:error, :later, :deliberate_failure, %{close: %Stream{}}} =
               repo().transaction(multi)

      assert repo().get!(Stream, stream_id).closed_at == nil
    end
  end

  defp append!(attrs) do
    assert {:ok, event} = Store.append(attrs, telemetry: false)
    event
  end

  defp encode_cursor(value), do: Base.url_encode64(value, padding: false)

  defp unique(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
