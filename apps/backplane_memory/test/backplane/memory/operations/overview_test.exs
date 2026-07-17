defmodule Backplane.Memory.Operations.OverviewTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Events.{Event, Store, Stream}
  alias Backplane.Memory.Operations
  alias Backplane.Memory.Operations.Query

  test "persisted counts distinguish open streams and use insertion time" do
    reset_memory_tables()
    now = ~U[2030-07-17 12:34:56.000000Z]
    cutoff = DateTime.add(now, -24, :hour)

    delayed =
      append!(%{
        stream_id: "overview-counts-delayed",
        event_type: "task.created",
        occurred_at: DateTime.add(now, -10, :day)
      })

    old_insert =
      append!(%{
        stream_id: "overview-counts-old-insert",
        event_type: "task.updated",
        occurred_at: DateTime.add(now, -1, :minute)
      })

    closed =
      append!(%{
        stream_id: "overview-counts-closed",
        event_type: "task.completed",
        occurred_at: DateTime.add(now, -2, :minute)
      })

    boundary =
      append!(%{
        stream_id: closed.stream_id,
        event_type: "task.updated",
        occurred_at: DateTime.add(now, -3, :minute)
      })

    set_inserted_at(delayed, DateTime.add(now, -1, :hour))
    set_inserted_at(old_insert, DateTime.add(cutoff, -1, :second))
    set_inserted_at(closed, DateTime.add(now, -2, :hour))
    set_inserted_at(boundary, cutoff)
    assert {:ok, _stream} = Store.close_stream(closed.stream_id)

    assert Query.persisted_counts(now) == %{
             open_streams: 2,
             events_last_24h: 3
           }
  end

  test "event volume returns 60 ascending, gap-filled minute buckets" do
    reset_memory_tables()
    now = ~U[2030-07-17 12:34:56.654321Z]
    final_bucket = ~U[2030-07-17 12:34:00.000000Z]
    first_bucket = ~U[2030-07-17 11:35:00.000000Z]

    events =
      for sequence <- 1..6 do
        append!(%{
          stream_id: "overview-volume-#{sequence}",
          event_type: "task.updated",
          occurred_at: DateTime.add(now, sequence, :second)
        })
      end

    [first, middle_one, middle_two, final, before_range, after_range] = events

    set_inserted_at(first, first_bucket)
    set_inserted_at(middle_one, DateTime.add(first_bucket, 10, :minute))
    set_inserted_at(middle_two, DateTime.add(first_bucket, 10, :minute))
    set_inserted_at(final, DateTime.add(final_bucket, 59, :second))
    set_inserted_at(before_range, DateTime.add(first_bucket, -1, :microsecond))
    set_inserted_at(after_range, DateTime.add(final_bucket, 1, :minute))

    volume = Query.event_volume(now)

    assert length(volume) == 60

    assert Enum.map(volume, & &1.at) ==
             for(offset <- 0..59, do: DateTime.add(first_bucket, offset, :minute))

    assert hd(volume) == %{at: first_bucket, count: 1}
    assert Enum.at(volume, 1) == %{at: DateTime.add(first_bucket, 1, :minute), count: 0}
    assert Enum.at(volume, 10) == %{at: DateTime.add(first_bucket, 10, :minute), count: 2}
    assert List.last(volume) == %{at: final_bucket, count: 1}
    assert Enum.sum(Enum.map(volume, & &1.count)) == 4
  end

  test "recent events and active streams retain their authoritative ordering" do
    reset_memory_tables()
    occurred_at = ~U[2030-07-17 13:00:00.000000Z]

    lower =
      append!(%{
        id: "00000000-0000-4000-8000-000000000001",
        stream_id: "overview-recent-lower",
        event_type: "task.created",
        occurred_at: occurred_at
      })

    higher =
      append!(%{
        id: "00000000-0000-4000-8000-000000000002",
        stream_id: "overview-recent-higher",
        event_type: "task.updated",
        occurred_at: occurred_at
      })

    newest =
      append!(%{
        id: "00000000-0000-4000-8000-000000000003",
        stream_id: "overview-recent-newest",
        event_type: "task.completed",
        occurred_at: DateTime.add(occurred_at, 1, :second)
      })

    assert Enum.map(Query.recent_events(3), & &1.id) == [
             newest.id,
             higher.id,
             lower.id
           ]

    reset_memory_tables()
    tied_time = ~U[2030-07-17 12:00:00.000000Z]
    newest_time = DateTime.add(tied_time, 1, :hour)

    insert_stream!("active-a", last_event_at: tied_time)
    insert_stream!("active-undated")
    insert_stream!("active-z", last_event_at: newest_time)
    insert_stream!("active-b", last_event_at: tied_time)

    insert_stream!("closed-newest",
      last_event_at: DateTime.add(newest_time, 1, :hour),
      closed_at: newest_time
    )

    assert Enum.map(Query.active_streams(4), & &1.stream_id) == [
             "active-z",
             "active-b",
             "active-a",
             "active-undated"
           ]
  end

  test "overview labels runtime counters and treats missing counters as zero" do
    reset_memory_tables()

    counter_names = [
      "memory_events_appended",
      "memory_events_duplicates",
      "memory_events_errors"
    ]

    snapshot =
      Map.new(counter_names, fn name ->
        key = {:counter, name}
        {key, :ets.lookup(Backplane.Metrics, key)}
      end)

    on_exit(fn ->
      Enum.each(snapshot, fn {key, rows} ->
        :ets.delete(Backplane.Metrics, key)

        if rows != [] do
          :ets.insert(Backplane.Metrics, rows)
        end
      end)
    end)

    :ets.insert(Backplane.Metrics, {{:counter, "memory_events_appended"}, 7})
    :ets.delete(Backplane.Metrics, {:counter, "memory_events_duplicates"})
    :ets.insert(Backplane.Metrics, {{:counter, "memory_events_errors"}, 2})

    overview = Operations.overview()

    assert Map.keys(overview) |> Enum.sort() ==
             [
               :active_streams,
               :event_volume,
               :persisted_counts,
               :pipeline,
               :recent_events,
               :runtime_metrics
             ]

    assert {:ok,
            %{
              appended: 7,
              duplicates: 0,
              errors: 2,
              scope: :since_process_start
            }} = overview.runtime_metrics

    assert Enum.all?(overview, fn {_region, result} -> match?({:ok, _value}, result) end)
  end

  test "collect_regions keeps one failure from erasing healthy regions" do
    regions = %{
      pipeline: fn -> :healthy end,
      persisted_counts: fn -> raise "database unavailable" end,
      event_volume: fn -> :volume end,
      runtime_metrics: fn -> :metrics end,
      recent_events: fn -> :recent end,
      active_streams: fn -> :streams end
    }

    result = Operations.collect_regions(regions)

    assert result.pipeline == {:ok, :healthy}

    assert {:error, %RuntimeError{message: "database unavailable"}} =
             result.persisted_counts

    assert result.event_volume == {:ok, :volume}
    assert result.runtime_metrics == {:ok, :metrics}
    assert result.recent_events == {:ok, :recent}
    assert result.active_streams == {:ok, :streams}
  end

  defp reset_memory_tables do
    repo().delete_all(Event)
    repo().delete_all(Stream)
  end

  defp append!(attrs) do
    assert {:ok, event} = Store.append(attrs, telemetry: false)
    event
  end

  defp set_inserted_at(event, inserted_at) do
    {1, nil} =
      repo().update_all(
        from(stored in Event, where: stored.id == ^event.id),
        set: [inserted_at: inserted_at]
      )
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
end
