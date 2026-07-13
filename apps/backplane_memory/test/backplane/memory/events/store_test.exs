defmodule Backplane.Memory.Events.StoreTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Events.{Event, Store}

  test "allocates ordered sequences and returns idempotent duplicates" do
    attrs = %{
      stream_id: "store-session-#{System.unique_integer([:positive])}",
      event_type: "conversation.user_message",
      content: "hello",
      idempotency_key: "message-1"
    }

    assert {:ok, {:inserted, first}} = Store.append(attrs)
    assert first.sequence == 1

    assert {:ok, {:inserted, second}} =
             Store.append(%{attrs | content: "next", idempotency_key: "message-2"})

    assert second.sequence == 2
    assert {:ok, {:duplicate, duplicate}} = Store.append(attrs)
    assert duplicate.id == first.id
  end

  test "rejects new events after closing a stream" do
    stream_id = "closed-session-#{System.unique_integer([:positive])}"

    assert {:ok, {:inserted, _}} =
             Store.append(%{stream_id: stream_id, event_type: "session.started"})

    assert {:ok, _stream} = Store.close_stream(stream_id)

    assert {:error, :stream_closed} =
             Store.append(%{stream_id: stream_id, event_type: "session.ended"})

    assert [event] = Store.list(stream_id)
    assert %Event{sequence: 1} = event
  end

  test "batch rolls back all events when one event targets a closed stream" do
    closed = "batch-closed-#{System.unique_integer([:positive])}"
    open = "batch-open-#{System.unique_integer([:positive])}"

    assert {:ok, {:inserted, _}} =
             Store.append(%{stream_id: closed, event_type: "session.started"})

    assert {:ok, _} = Store.close_stream(closed)

    assert {:error, :stream_closed} =
             Store.append_batch([
               %{stream_id: open, event_type: "session.started"},
               %{stream_id: closed, event_type: "session.ended"}
             ])

    assert [] = Store.list(open)
  end
end
