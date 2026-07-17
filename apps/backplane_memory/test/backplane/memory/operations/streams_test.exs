defmodule Backplane.Memory.Operations.StreamsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Events.{Store, Stream}
  alias Backplane.Memory.Operations

  defmodule StreamsFailingRepo do
    def all(_query), do: raise("forced streams read failure")
    def get(_schema, _id), do: raise("forced streams read failure")
  end

  describe "list_streams/1" do
    test "orders dated and undated streams with stable keyset traversal" do
      project = unique("stream-order")
      prefix = unique("stream-order-id")
      newest_time = ~U[2026-07-17 10:00:00.000000Z]
      tied_time = ~U[2026-07-17 09:00:00.000000Z]

      insert_stream!("#{prefix}:stream-a", project: project, last_event_at: tied_time)
      insert_stream!("#{prefix}:undated-a", project: project)
      insert_stream!("#{prefix}:stream-z", project: project, last_event_at: newest_time)
      insert_stream!("#{prefix}:undated-c", project: project)
      insert_stream!("#{prefix}:stream-b", project: project, last_event_at: tied_time)
      insert_stream!("#{prefix}:undated-b", project: project)

      expected = [
        {newest_time, "#{prefix}:stream-z"},
        {tied_time, "#{prefix}:stream-b"},
        {tied_time, "#{prefix}:stream-a"},
        {nil, "#{prefix}:undated-c"},
        {nil, "#{prefix}:undated-b"},
        {nil, "#{prefix}:undated-a"}
      ]

      assert {:ok, %{streams: streams, next_cursor: nil}} =
               Operations.list_streams(%{"project" => project, "limit" => "100"})

      assert Enum.map(streams, &{&1.last_event_at, &1.stream_id}) == expected

      assert {:ok, %{streams: traversed, filters: filters}} =
               traverse_streams(%{"project" => project, "limit" => "2"})

      assert Enum.map(traversed, &{&1.last_event_at, &1.stream_id}) == expected
      assert Enum.uniq_by(traversed, & &1.stream_id) == traversed
      assert Map.delete(filters, "cursor") == %{"project" => project, "limit" => "2"}
    end

    test "applies every inventory filter independently" do
      marker = unique("stream-filters")
      now = ~U[2026-07-17 10:00:00.000000Z]

      target =
        insert_stream!("#{marker}:target",
          project: "#{marker}:project",
          agent_id: "#{marker}:agent",
          host_id: "#{marker}:host",
          session_id: "#{marker}:session",
          run_id: "#{marker}:run",
          last_event_at: now
        )

      closed =
        insert_stream!("#{marker}:closed",
          project: "#{marker}:other-project",
          agent_id: "#{marker}:other-agent",
          host_id: "#{marker}:other-host",
          session_id: "#{marker}:other-session",
          run_id: "#{marker}:other-run",
          last_event_at: DateTime.add(now, -1, :second),
          closed_at: now
        )

      for {filter, value} <- [
            {"project", target.project},
            {"agent", target.agent_id},
            {"host", target.host_id},
            {"session", target.session_id},
            {"run", target.run_id}
          ] do
        assert {:ok, %{streams: [%Stream{stream_id: stream_id}]}} =
                 Operations.list_streams(%{filter => value})

        assert stream_id == target.stream_id
      end

      assert {:ok, %{streams: open_streams}} =
               Operations.list_streams(%{"state" => "open", "limit" => "100"})

      assert target.stream_id in Enum.map(open_streams, & &1.stream_id)
      refute closed.stream_id in Enum.map(open_streams, & &1.stream_id)

      assert {:ok, %{streams: closed_streams}} =
               Operations.list_streams(%{"state" => "closed"})

      assert closed.stream_id in Enum.map(closed_streams, & &1.stream_id)
      refute target.stream_id in Enum.map(closed_streams, & &1.stream_id)
    end

    test "caps inventory pages at 100 rows" do
      project = unique("stream-cap")
      occurred_at = ~U[2026-07-17 10:00:00.000000Z]

      for sequence <- 1..101 do
        insert_stream!("#{project}:#{sequence}",
          project: project,
          last_event_at: DateTime.add(occurred_at, sequence, :second)
        )
      end

      assert {:ok,
              %{
                streams: streams,
                next_cursor: cursor,
                filters: %{"project" => ^project, "limit" => "100"}
              }} =
               Operations.list_streams(%{
                 "project" => project,
                 "limit" => "999"
               })

      assert length(streams) == 100
      assert is_binary(cursor)
    end

    test "rejects malformed cursors with the remaining canonical query" do
      project = unique("stream-cursors")

      invalid_cursors = [
        "@@@",
        encode_cursor("not-json"),
        encode_cursor(%{"branch" => "other", "stream_id" => "stream"}),
        encode_cursor(%{"branch" => "dated", "stream_id" => "stream"}),
        encode_cursor(%{
          "branch" => "dated",
          "last_event_at" => "not-a-time",
          "stream_id" => "stream"
        }),
        encode_cursor(%{"branch" => "undated"}),
        encode_cursor(%{"branch" => "undated", "stream_id" => ""}),
        encode_cursor(%{
          "branch" => "undated",
          "stream_id" => "stream",
          "extra" => true
        }),
        123
      ]

      for cursor <- invalid_cursors do
        assert {:error, {:invalid_param, :cursor, %{"project" => ^project, "limit" => "2"}}} =
                 Operations.list_streams(%{
                   "project" => project,
                   "limit" => "2",
                   "cursor" => cursor
                 })
      end
    end

    test "removes a malformed cursor with another invalid inventory parameter" do
      project = unique("stream-compound-cursor")

      assert {:error, {:invalid_param, :state, canonical}} =
               Operations.list_streams(%{
                 "project" => project,
                 "state" => "all",
                 "cursor" => "@@@"
               })

      assert canonical == %{"project" => project}

      valid_cursor =
        encode_cursor(%{
          "branch" => "undated",
          "stream_id" => "valid-stream"
        })

      assert {:error, {:invalid_param, :state, valid_canonical}} =
               Operations.list_streams(%{
                 "project" => project,
                 "state" => "all",
                 "cursor" => valid_cursor
               })

      assert valid_canonical == %{
               "project" => project,
               "cursor" => valid_cursor
             }
    end
  end

  describe "stream detail and sequence windows" do
    test "moves between latest and older 100-event windows without gaps" do
      stream_id = unique("sequence")
      append_events!(stream_id, 250)

      assert {:ok, latest} = Operations.stream_events(stream_id, %{})
      assert Enum.map(latest.events, & &1.sequence) == Enum.to_list(151..250)
      assert latest.older_before == 151
      assert latest.newer_after == nil
      assert latest.window == :latest
      assert latest.params == %{}

      assert {:ok, older} =
               Operations.stream_events(stream_id, %{"before" => "151"})

      assert Enum.map(older.events, & &1.sequence) == Enum.to_list(51..150)
      assert older.older_before == 51
      assert older.newer_after == 150
      assert older.window == :before
      assert older.params == %{"before" => "151"}

      assert {:ok, round_trip} =
               Operations.stream_events(stream_id, %{"after" => "150"})

      assert Enum.map(round_trip.events, & &1.sequence) == Enum.to_list(151..250)
      assert round_trip.older_before == 151
      assert round_trip.newer_after == nil
      assert round_trip.window == :after
      assert round_trip.params == %{"after" => "150"}

      assert {:ok, oldest} =
               Operations.stream_events(stream_id, %{"before" => "51"})

      assert Enum.map(oldest.events, & &1.sequence) == Enum.to_list(1..50)
      assert oldest.older_before == nil
      assert oldest.newer_after == 50
    end

    test "handles short, empty, exhausted, and unknown streams" do
      short_stream = unique("short-sequence")
      append_events!(short_stream, 3)

      assert {:ok,
              %{
                events: events,
                older_before: nil,
                newer_after: nil,
                window: :latest
              }} = Operations.stream_events(short_stream, %{})

      assert Enum.map(events, & &1.sequence) == [1, 2, 3]

      empty_stream = unique("empty-sequence")
      insert_stream!(empty_stream)

      assert {:ok,
              %{
                events: [],
                older_before: nil,
                newer_after: nil,
                window: :latest
              }} = Operations.stream_events(empty_stream, %{})

      assert {:ok,
              %{
                events: [],
                older_before: nil,
                newer_after: nil,
                window: :before
              }} = Operations.stream_events(short_stream, %{"before" => "1"})

      assert {:ok,
              %{
                events: [],
                older_before: nil,
                newer_after: nil,
                window: :after
              }} = Operations.stream_events(short_stream, %{"after" => "3"})

      assert {:error, :not_found} =
               Operations.stream_events(unique("missing-sequence"), %{})
    end

    test "normalizes anchors and never loads more than 100 events" do
      stream_id = unique("bounded-sequence")
      append_events!(stream_id, 150)

      for {key, value} <- [{"before", "0"}, {"after", "-1"}, {"before", "bad"}] do
        expected_key = String.to_atom(key)

        assert {:error, {:invalid_param, ^expected_key, %{}}} =
                 Operations.stream_events(stream_id, %{key => value})
      end

      assert {:error, {:invalid_param, :after, %{"before" => "10"}}} =
               Operations.stream_events(stream_id, %{
                 "before" => "10",
                 "after" => "20"
               })

      assert {:ok,
              %{
                events: events,
                params: %{}
              }} = Operations.stream_events(stream_id, %{"limit" => "999"})

      assert length(events) == 100
      assert Enum.map(events, & &1.sequence) == Enum.to_list(51..150)
    end

    test "gets stream detail and rejects invalid identities" do
      stream = insert_stream!(unique("stream-detail"), project: "project-detail")

      assert {:ok, fetched} = Operations.get_stream(stream.stream_id)
      assert fetched.stream_id == stream.stream_id
      assert fetched.project == "project-detail"
      assert {:error, :not_found} = Operations.get_stream(unique("missing-stream"))
      assert {:error, :not_found} = Operations.get_stream("")
      assert {:error, :not_found} = Operations.get_stream("   ")
      assert {:error, :not_found} = Operations.get_stream(nil)
    end
  end

  test "repository failures return errors instead of raising" do
    previous_repo = Application.fetch_env(:backplane_memory, :repo)

    on_exit(fn ->
      case previous_repo do
        {:ok, repo} -> Application.put_env(:backplane_memory, :repo, repo)
        :error -> Application.delete_env(:backplane_memory, :repo)
      end
    end)

    Application.put_env(:backplane_memory, :repo, StreamsFailingRepo)

    assert {:error, %RuntimeError{message: "forced streams read failure"}} =
             Operations.list_streams(%{})

    assert {:error, %RuntimeError{message: "forced streams read failure"}} =
             Operations.get_stream("stream-id")

    assert {:error, %RuntimeError{message: "forced streams read failure"}} =
             Operations.stream_events("stream-id", %{})
  end

  defp traverse_streams(filters, acc \\ [], pages_left \\ 100)

  defp traverse_streams(_filters, _acc, 0) do
    flunk("stream cursor traversal did not terminate")
  end

  defp traverse_streams(filters, acc, pages_left) do
    assert {:ok, page} = Operations.list_streams(filters)
    acc = acc ++ page.streams

    if page.next_cursor do
      filters
      |> Map.put("cursor", page.next_cursor)
      |> traverse_streams(acc, pages_left - 1)
    else
      {:ok, %{streams: acc, filters: page.filters}}
    end
  end

  defp insert_stream!(stream_id, attrs \\ []) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:stream_id, stream_id)

    %Stream{}
    |> struct(attrs)
    |> repo().insert!()
  end

  defp append_events!(stream_id, count) do
    attrs =
      for sequence <- 1..count do
        %{
          stream_id: stream_id,
          event_type: "task.updated",
          content: Integer.to_string(sequence)
        }
      end

    assert {:ok, events} = Store.append_batch(attrs, telemetry: false)
    events
  end

  defp encode_cursor(value) when is_binary(value) do
    Base.url_encode64(value, padding: false)
  end

  defp encode_cursor(value) do
    value
    |> Jason.encode!()
    |> encode_cursor()
  end

  defp unique(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
