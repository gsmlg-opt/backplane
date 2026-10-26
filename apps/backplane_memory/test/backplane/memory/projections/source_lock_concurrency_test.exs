defmodule Backplane.Memory.Projections.SourceLockConcurrencyTest do
  use ExUnit.Case, async: false

  alias Backplane.Memory.Events.{Store, Stream}
  alias Backplane.Memory.IngestFixtures
  alias Backplane.Memory.Projections.Source
  alias Backplane.MemorySpaces.MemorySpace
  alias Ecto.Adapters.SQL.Sandbox

  @timeout 10_000

  test "source waits for the canonical subject before taking stream rows" do
    host_id = "source-lock-#{Ecto.UUID.generate()}"
    session_id = Ecto.UUID.generate()
    stream_id = "#{host_id}:#{session_id}"

    memory_space_id =
      unboxed(fn ->
        memory_space_id = IngestFixtures.ensure_memory_space!(host_id)

        repo().insert!(%Stream{
          stream_id: stream_id,
          memory_space_id: memory_space_id,
          host_id: host_id,
          session_id: session_id,
          scope: "global",
          namespace: "private"
        })

        memory_space_id
      end)

    on_exit(fn ->
      unboxed(fn ->
        repo().delete!(repo().get!(Stream, stream_id))
        repo().delete!(repo().get!(MemorySpace, memory_space_id))
      end)
    end)

    parent = self()
    subject_id = Source.subject_id!(host_id, session_id)

    writer =
      Task.async(fn ->
        unboxed(fn ->
          repo().transaction(fn ->
            # Pause a canonical writer between its subject and stream locks.
            repo().query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [subject_id])
            send(parent, :subject_locked)

            receive do
              :append ->
                assert {:ok, event} =
                         Store.append(
                           %{
                             stream_id: stream_id,
                             memory_space_id: memory_space_id,
                             host_id: host_id,
                             session_id: session_id,
                             scope: "global",
                             namespace: "private",
                             event_type: "observation.recorded",
                             schema_version: 1,
                             source_sequence: 1,
                             content: "lock-order regression"
                           },
                           telemetry: false
                         )

                send(parent, {:appended, event.id})
                repo().rollback(:writer_finished)
            after
              @timeout -> repo().rollback(:writer_timeout)
            end
          end)
        end)
      end)

    assert_receive :subject_locked, @timeout

    reader =
      Task.async(fn ->
        unboxed(fn ->
          repo().transaction(fn ->
            [[backend_pid]] = repo().query!("SELECT pg_backend_pid()").rows
            send(parent, {:source_backend, backend_pid})
            assert [%Stream{stream_id: ^stream_id}] = Source.lock_streams(host_id, session_id)
            repo().rollback(:reader_finished)
          end)
        end)
      end)

    try do
      assert_receive {:source_backend, backend_pid}, @timeout
      assert wait_for_advisory_lock(backend_pid)

      # Source must not already hold the row needed by this append. Both
      # transactions roll back, preserving immutable canonical event storage.
      send(writer.pid, :append)
      assert_receive {:appended, _event_id}, @timeout
      assert {:error, :writer_finished} = Task.await(writer, @timeout)
      assert {:error, :reader_finished} = Task.await(reader, @timeout)
    after
      Task.shutdown(writer, :brutal_kill)
      Task.shutdown(reader, :brutal_kill)
    end
  end

  defp wait_for_advisory_lock(backend_pid) do
    unboxed(fn ->
      Enum.reduce_while(1..200, false, fn _, _ ->
        result =
          repo().query!(
            "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = $1",
            [backend_pid]
          )

        if result.rows == [["Lock", "advisory"]] do
          {:halt, true}
        else
          Process.sleep(10)
          {:cont, false}
        end
      end)
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

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
