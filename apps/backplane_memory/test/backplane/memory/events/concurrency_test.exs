defmodule Backplane.Memory.Events.ConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Backplane.Memory.Events.{Event, Store, Stream}
  alias Ecto.Adapters.SQL.Sandbox

  @task_timeout 30_000

  test "100 committed writers allocate every sequence exactly once" do
    prefix = unique("hundred-writers")
    stream_id = prefix <> ":stream"
    cleanup_on_exit(prefix)

    results =
      1..100
      |> Task.async_stream(
        fn n ->
          unboxed(fn ->
            Store.append(%{
              stream_id: stream_id,
              event_type: "task.updated",
              content: Integer.to_string(n),
              idempotency_key: "#{prefix}:#{n}"
            })
          end)
        end,
        max_concurrency: max_concurrency(),
        ordered: false,
        timeout: @task_timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    assert length(results) == 100

    assert Enum.all?(results, fn
             {:ok, {:ok, %Event{}}} -> true
             _ -> false
           end)

    {sequences, next_sequence} =
      unboxed(fn ->
        sequences =
          repo().all(
            from(e in Event,
              where: e.stream_id == ^stream_id,
              order_by: e.sequence,
              select: e.sequence
            )
          )

        {sequences, repo().get!(Stream, stream_id).next_sequence}
      end)

    assert sequences == Enum.to_list(1..100)
    assert next_sequence == 101
  end

  test "an outer transaction holding stream A does not block stream B" do
    prefix = unique("different-streams")
    stream_a = prefix <> ":a"
    stream_b = prefix <> ":b"
    cleanup_on_exit(prefix)
    parent = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Ecto.Multi.new()
          |> Store.append_multi(:event, %{
            stream_id: stream_a,
            event_type: "task.created"
          })
          |> Ecto.Multi.run(:barrier, fn _repo, %{event: {:inserted, event}} ->
            send(parent, {:stream_a_held, self(), event.id})

            receive do
              :release_stream_a -> {:ok, :released}
            after
              @task_timeout -> {:error, :barrier_timeout}
            end
          end)
          |> repo().transaction()
        end)
      end)

    release_on_exit(holder, :release_stream_a)

    assert_receive {:stream_a_held, holder_pid, _event_id}, @task_timeout
    assert holder_pid == holder.pid

    other =
      Task.async(fn ->
        unboxed(fn ->
          Store.append(%{stream_id: stream_b, event_type: "task.created"})
        end)
      end)

    other_result = Task.await(other, @task_timeout)
    send(holder.pid, :release_stream_a)
    holder_result = Task.await(holder, @task_timeout)

    assert {:ok, %Event{stream_id: ^stream_b, sequence: 1}} = other_result

    assert {:ok, %{event: {:inserted, %Event{stream_id: ^stream_a, sequence: 1}}}} =
             holder_result
  end

  test "opposite-order batches complete without a deadlock" do
    prefix = unique("opposite-batches")
    stream_a = prefix <> ":a"
    stream_b = prefix <> ":b"
    cleanup_on_exit(prefix)
    parent = self()

    left =
      concurrent_batch(parent, :left, [
        batch_event(stream_a, prefix <> ":left-a"),
        batch_event(stream_b, prefix <> ":left-b")
      ])

    release_on_exit(left, :start_batch)

    right =
      concurrent_batch(parent, :right, [
        batch_event(stream_b, prefix <> ":right-b"),
        batch_event(stream_a, prefix <> ":right-a")
      ])

    release_on_exit(right, :start_batch)

    assert_receive {:batch_ready, :left, left_pid}, @task_timeout
    assert_receive {:batch_ready, :right, right_pid}, @task_timeout
    send(left_pid, :start_batch)
    send(right_pid, :start_batch)

    assert {:ok, [%Event{}, %Event{}]} = Task.await(left, @task_timeout)
    assert {:ok, [%Event{}, %Event{}]} = Task.await(right, @task_timeout)

    sequences =
      unboxed(fn ->
        repo().all(
          from(e in Event,
            where: e.stream_id in ^[stream_a, stream_b],
            order_by: [asc: e.stream_id, asc: e.sequence],
            select: {e.stream_id, e.sequence}
          )
        )
      end)

    assert sequences == [{stream_a, 1}, {stream_a, 2}, {stream_b, 1}, {stream_b, 2}]
  end

  test "a blocked global-key loser resolves after rollback as a conflict" do
    prefix = unique("global-key-race")
    stream_a = prefix <> ":a"
    stream_b = prefix <> ":b"
    key = prefix <> ":same-key"
    cleanup_on_exit(prefix)
    parent = self()

    winner =
      Task.async(fn ->
        unboxed(fn ->
          Ecto.Multi.new()
          |> Store.append_multi(:event, %{
            stream_id: stream_a,
            event_type: "tool.call.completed",
            content: "winner",
            idempotency_key: key
          })
          |> Ecto.Multi.run(:barrier, fn repo, %{event: {:inserted, event}} ->
            backend_pid = repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
            send(parent, {:winner_uncommitted, self(), backend_pid, event.id})

            receive do
              :commit_winner -> {:ok, :commit}
            after
              @task_timeout -> {:error, :barrier_timeout}
            end
          end)
          |> repo().transaction()
        end)
      end)

    release_on_exit(winner, :commit_winner)

    assert_receive {:winner_uncommitted, winner_pid, _winner_backend, winner_id}, @task_timeout
    assert winner_pid == winner.pid

    loser =
      Task.async(fn ->
        unboxed(fn ->
          backend_pid = repo().query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
          send(parent, {:loser_started, backend_pid})

          Store.append(%{
            stream_id: stream_b,
            event_type: "tool.call.completed",
            content: "loser",
            idempotency_key: key
          })
        end)
      end)

    assert_receive {:loser_started, loser_backend}, @task_timeout
    assert waiting_on_lock?(loser_backend)

    send(winner.pid, :commit_winner)

    assert {:ok, %{event: {:inserted, %Event{id: ^winner_id}}}} =
             Task.await(winner, @task_timeout)

    assert {:error, :idempotency_conflict} = Task.await(loser, @task_timeout)

    {events, loser_stream} =
      unboxed(fn ->
        {
          repo().all(from(e in Event, where: e.idempotency_key == ^key)),
          repo().get(Stream, stream_b)
        }
      end)

    assert [%Event{id: ^winner_id, stream_id: ^stream_a}] = events
    refute loser_stream
  end

  defp concurrent_batch(parent, name, events) do
    Task.async(fn ->
      unboxed(fn ->
        send(parent, {:batch_ready, name, self()})

        receive do
          :start_batch -> Store.append_batch(events)
        after
          @task_timeout -> {:error, :barrier_timeout}
        end
      end)
    end)
  end

  defp waiting_on_lock?(backend_pid) do
    unboxed(fn ->
      Enum.reduce_while(1..1_000, false, fn _, _ ->
        result =
          repo().query!(
            "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
            [backend_pid]
          )

        case result.rows do
          [["Lock"]] -> {:halt, true}
          _ -> {:cont, false}
        end
      end)
    end)
  end

  defp batch_event(stream_id, idempotency_key) do
    %{
      stream_id: stream_id,
      event_type: "task.updated",
      idempotency_key: idempotency_key
    }
  end

  defp cleanup_on_exit(prefix) do
    on_exit(fn ->
      unboxed(fn ->
        repo().delete_all(from(e in Event, where: like(e.stream_id, ^"#{prefix}%")))
        repo().delete_all(from(s in Stream, where: like(s.stream_id, ^"#{prefix}%")))
      end)
    end)
  end

  defp release_on_exit(task, message) do
    on_exit(fn ->
      if Process.alive?(task.pid), do: send(task.pid, message)
    end)
  end

  defp unboxed(fun) do
    :ok = Sandbox.checkout(repo(), sandbox: false)

    try do
      fun.()
    after
      :ok = Sandbox.checkin(repo())
    end
  end

  defp max_concurrency do
    pool_size =
      :backplane_system
      |> Application.fetch_env!(repo())
      |> Keyword.fetch!(:pool_size)

    max(pool_size - 1, 1)
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  defp unique(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
