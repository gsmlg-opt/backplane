defmodule Backplane.Memory.EventNotifierTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Backplane.Memory.EventNotifier
  alias Backplane.Memory.Events.{Event, Store, Stream}
  alias Ecto.Adapters.SQL.Sandbox

  setup_all do
    :ok = Sandbox.mode(repo(), :auto)
    on_exit(fn -> :ok = Sandbox.mode(repo(), :manual) end)
    :ok
  end

  test "broadcasts a safe summary only after commit" do
    prefix = unique("notifier-commit")
    cleanup_on_exit(prefix)
    :ok = EventNotifier.subscribe()
    parent = self()

    transaction_task =
      Task.async(fn ->
        unboxed(fn ->
          repo().transaction(fn ->
            {:ok, event} =
              Store.append(%{
                stream_id: "#{prefix}:stream",
                event_type: "task.created"
              })

            send(parent, {:inserted_inside_transaction, self(), event})

            receive do
              :commit -> event
            end
          end)
        end)
      end)

    assert_receive {:inserted_inside_transaction, transaction_pid, event}
    refute_receive {:memory_event_inserted, _summary}, 100
    send(transaction_pid, :commit)

    assert {:ok, ^event} = Task.await(transaction_task, 5_000)

    assert_receive {:memory_event_inserted, summary}, 1_000

    assert Map.keys(summary) |> Enum.sort() ==
             [
               :agent_id,
               :event_type,
               :id,
               :occurred_at,
               :project,
               :run_id,
               :session_id,
               :status,
               :stream_id,
               :tool_name
             ]

    refute Map.has_key?(summary, :content)
    refute Map.has_key?(summary, :payload)
  end

  test "an outer transaction rollback emits no notification" do
    prefix = unique("notifier-rollback")
    cleanup_on_exit(prefix)
    :ok = EventNotifier.subscribe()
    parent = self()

    assert {:error, :deliberate_rollback} =
             unboxed(fn ->
               repo().transaction(fn ->
                 {:ok, event} =
                   Store.append(%{
                     stream_id: "#{prefix}:stream",
                     event_type: "task.created"
                   })

                 send(parent, {:inserted_before_rollback, event})
                 repo().rollback(:deliberate_rollback)
               end)
             end)

    assert_receive {:inserted_before_rollback, event}
    refute_receive {:memory_event_inserted, _summary}, 200

    unboxed(fn ->
      refute repo().get(Event, event.id)
      refute repo().get(Stream, event.stream_id)
    end)
  end

  test "an idempotent duplicate emits no second notification" do
    prefix = unique("notifier-duplicate")
    cleanup_on_exit(prefix)
    :ok = EventNotifier.subscribe()

    attrs = %{
      stream_id: "#{prefix}:stream",
      event_type: "task.created",
      idempotency_key: "#{prefix}:key"
    }

    first = unboxed(fn -> Store.append(attrs) end)
    assert {:ok, first_event} = first
    assert_receive {:memory_event_inserted, %{id: first_id}}, 1_000
    assert first_id == first_event.id

    assert {:ok, duplicate} = unboxed(fn -> Store.append(attrs) end)
    assert duplicate.id == first_event.id
    refute_receive {:memory_event_inserted, _summary}, 200
  end

  test "a batch emits once per inserted event" do
    prefix = unique("notifier-batch")
    cleanup_on_exit(prefix)
    :ok = EventNotifier.subscribe()

    assert {:ok, events} =
             unboxed(fn ->
               Store.append_batch([
                 %{stream_id: "#{prefix}:stream", event_type: "task.created"},
                 %{stream_id: "#{prefix}:stream", event_type: "task.updated"}
               ])
             end)

    assert_receive {:memory_event_inserted, first_summary}, 1_000
    assert_receive {:memory_event_inserted, second_summary}, 1_000

    assert MapSet.new([first_summary.id, second_summary.id]) ==
             MapSet.new(Enum.map(events, & &1.id))

    refute_receive {:memory_event_inserted, _summary}, 100
  end

  test "the summary excludes content and payload" do
    prefix = unique("notifier-safe")
    cleanup_on_exit(prefix)
    :ok = EventNotifier.subscribe()
    secret = "notifier-secret-sentinel"

    assert {:ok, event} =
             unboxed(fn ->
               Store.append(%{
                 stream_id: "#{prefix}:stream",
                 event_type: "tool.call.completed",
                 content: secret,
                 payload: %{"result" => secret}
               })
             end)

    assert_receive {:memory_event_inserted, summary}, 1_000
    assert summary.id == event.id
    refute Map.has_key?(summary, :content)
    refute Map.has_key?(summary, :payload)
    refute inspect(summary) =~ secret
  end

  defp unboxed(fun) do
    :ok = Sandbox.checkout(repo(), sandbox: false)

    try do
      fun.()
    after
      :ok = Sandbox.checkin(repo())
    end
  end

  defp cleanup_on_exit(prefix) do
    on_exit(fn ->
      unboxed(fn ->
        repo().delete_all(from(event in Event, where: like(event.stream_id, ^"#{prefix}%")))

        repo().delete_all(from(stream in Stream, where: like(stream.stream_id, ^"#{prefix}%")))
      end)
    end)
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  defp unique(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
