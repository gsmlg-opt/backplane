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

  test "concurrent canonical event-ID collisions resolve as conflicts across stream locks" do
    for topology <- [:same_stream, :cross_stream] do
      prefix = unique("event-id-race-#{topology}") <> "-" <> Ecto.UUID.generate()
      stream_a = prefix <> ":a"
      stream_b = if topology == :same_stream, do: stream_a, else: prefix <> ":b"
      event_id = Ecto.UUID.generate()
      occurred_at = DateTime.utc_now()
      cleanup_on_exit(prefix)
      parent = self()

      winner_attrs = canonical_event(stream_a, event_id, prefix <> ":winner", occurred_at)

      loser_attrs =
        stream_b
        |> canonical_event(event_id, prefix <> ":loser", occurred_at)
        |> Map.put(:source_sequence, 2)

      winner =
        Task.async(fn ->
          unboxed(fn ->
            Ecto.Multi.new()
            |> Store.append_multi(:event, winner_attrs)
            |> Ecto.Multi.run(:barrier, fn _repo, %{event: {:inserted, event}} ->
              send(parent, {:event_id_winner_uncommitted, topology, self(), event.id})

              receive do
                {:commit_event_id_winner, ^topology} -> {:ok, :commit}
              after
                @task_timeout -> {:error, :barrier_timeout}
              end
            end)
            |> repo().transaction()
          end)
        end)

      release_on_exit(winner, {:commit_event_id_winner, topology})

      assert_receive {:event_id_winner_uncommitted, ^topology, winner_pid, ^event_id},
                     @task_timeout

      assert winner_pid == winner.pid

      loser = Task.async(fn -> unboxed(fn -> Store.append(loser_attrs) end) end)
      Process.sleep(50)
      refute Task.yield(loser, 0)

      send(winner.pid, {:commit_event_id_winner, topology})

      assert {:ok, %{event: {:inserted, %Event{id: ^event_id}}}} =
               Task.await(winner, @task_timeout)

      assert {:error, :idempotency_conflict} = Task.await(loser, @task_timeout)

      assert [%Event{id: ^event_id}] =
               unboxed(fn -> repo().all(from(e in Event, where: e.id == ^event_id)) end)
    end
  end

  test "concurrent canonical source-identity collisions resolve as conflicts across stream locks" do
    for topology <- [:same_stream, :cross_stream] do
      prefix = unique("source-identity-race-#{topology}") <> "-" <> Ecto.UUID.generate()
      stream_a = prefix <> ":a"
      stream_b = if topology == :same_stream, do: stream_a, else: prefix <> ":b"
      session_id = prefix <> ":session"
      occurred_at = DateTime.utc_now()
      cleanup_on_exit(prefix)
      parent = self()

      winner_attrs =
        stream_a
        |> canonical_event(Ecto.UUID.generate(), prefix <> ":winner", occurred_at)
        |> Map.put(:session_id, session_id)

      loser_attrs =
        stream_b
        |> canonical_event(Ecto.UUID.generate(), prefix <> ":loser", occurred_at)
        |> Map.put(:session_id, session_id)

      winner =
        Task.async(fn ->
          unboxed(fn ->
            Ecto.Multi.new()
            |> Store.append_multi(:event, winner_attrs)
            |> Ecto.Multi.run(:barrier, fn _repo, %{event: {:inserted, event}} ->
              send(parent, {:source_identity_winner_uncommitted, topology, self(), event.id})

              receive do
                {:commit_source_identity_winner, ^topology} -> {:ok, :commit}
              after
                @task_timeout -> {:error, :barrier_timeout}
              end
            end)
            |> repo().transaction()
          end)
        end)

      release_on_exit(winner, {:commit_source_identity_winner, topology})

      assert_receive {:source_identity_winner_uncommitted, ^topology, winner_pid, winner_id},
                     @task_timeout

      assert winner_pid == winner.pid

      loser = Task.async(fn -> unboxed(fn -> Store.append(loser_attrs) end) end)
      Process.sleep(50)
      refute Task.yield(loser, 0)

      send(winner.pid, {:commit_source_identity_winner, topology})

      assert {:ok, %{event: {:inserted, %Event{id: ^winner_id}}}} =
               Task.await(winner, @task_timeout)

      assert {:error, :idempotency_conflict} = Task.await(loser, @task_timeout)

      assert [%Event{id: ^winner_id}] =
               unboxed(fn ->
                 repo().all(
                   from(e in Event,
                     where:
                       e.host_id == "host-1" and e.session_id == ^session_id and
                         e.source_sequence == 1 and e.event_type == "agent.prompt.submitted" and
                         like(e.stream_id, ^"#{prefix}%")
                   )
                 )
               end)
    end
  end

  test "concurrent canonical writers serialize stream project selection" do
    prefix = unique("stream-project-race") <> "-" <> Ecto.UUID.generate()
    stream_id = prefix <> ":stream"
    cleanup_on_exit(prefix)
    parent = self()

    winner_attrs =
      canonical_event(stream_id, Ecto.UUID.generate(), prefix <> ":winner", DateTime.utc_now())
      |> Map.put(:project, "project-one")

    loser_attrs =
      canonical_event(stream_id, Ecto.UUID.generate(), prefix <> ":loser", DateTime.utc_now())
      |> Map.merge(%{project: "project-two", source_sequence: 2})

    winner =
      Task.async(fn ->
        unboxed(fn ->
          Ecto.Multi.new()
          |> Store.append_multi(:event, winner_attrs)
          |> Ecto.Multi.run(:barrier, fn _repo, %{event: {:inserted, event}} ->
            send(parent, {:stream_project_winner_uncommitted, self(), event.id})

            receive do
              :commit_stream_project_winner -> {:ok, :commit}
            after
              @task_timeout -> {:error, :barrier_timeout}
            end
          end)
          |> repo().transaction()
        end)
      end)

    release_on_exit(winner, :commit_stream_project_winner)

    assert_receive {:stream_project_winner_uncommitted, winner_pid, winner_id}, @task_timeout
    assert winner_pid == winner.pid

    loser = Task.async(fn -> unboxed(fn -> Store.append(loser_attrs) end) end)
    Process.sleep(50)
    refute Task.yield(loser, 0)

    send(winner.pid, :commit_stream_project_winner)

    assert {:ok, %{event: {:inserted, %Event{id: ^winner_id}}}} =
             Task.await(winner, @task_timeout)

    assert {:error, :stream_metadata_conflict} = Task.await(loser, @task_timeout)

    assert {%Stream{project: "project-one", next_sequence: 2}, [%Event{id: ^winner_id}]} =
             unboxed(fn -> {repo().get!(Stream, stream_id), Store.list(stream_id)} end)
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

  defp canonical_event(stream_id, event_id, idempotency_key, occurred_at) do
    %{
      id: event_id,
      stream_id: stream_id,
      event_type: "agent.prompt.submitted",
      host_id: "host-1",
      agent_id: "agent-1",
      integration: "codex",
      session_id: stream_id,
      source_sequence: 1,
      schema_version: 1,
      occurred_at: occurred_at,
      idempotency_key: idempotency_key,
      payload_hash: "sha256:test",
      privacy: %{"server_filtered" => true},
      trace: %{},
      raw_envelope: %{"idempotency_key" => idempotency_key},
      payload: %{"message" => "hello"}
    }
  end

  defp cleanup_on_exit(prefix) do
    on_exit(fn ->
      unboxed(fn ->
        repo().transaction(fn ->
          repo().query!("SET LOCAL session_replication_role = replica")
          repo().delete_all(from(e in Event, where: like(e.stream_id, ^"#{prefix}%")))
          repo().delete_all(from(s in Stream, where: like(s.stream_id, ^"#{prefix}%")))
        end)
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
