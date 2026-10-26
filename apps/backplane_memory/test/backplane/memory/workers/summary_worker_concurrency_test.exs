defmodule Backplane.Memory.Workers.SummaryWorkerConcurrencyTest do
  use ExUnit.Case, async: false

  setup do
    keys = ~w(memory.pipeline.enabled memory.session_summary_v2.enabled)
    previous = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})
    Enum.each(keys, &:ets.insert(:backplane_settings, {&1, true}))

    on_exit(fn ->
      Enum.each(previous, fn {key, entries} ->
        :ets.delete(:backplane_settings, key)
        Enum.each(entries, &:ets.insert(:backplane_settings, &1))
      end)
    end)

    :ok
  end

  import Ecto.Query
  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.Events.Stream, as: EventStream
  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Projections.{ActivityContribution, ActivityDaily, Rebuild, Source}
  alias Backplane.Memory.Summaries.Summary
  alias Backplane.Memory.Workers.{EpisodicWorker, SummaryWorker}
  alias Ecto.Adapters.SQL.Sandbox

  test "a captured append queued ahead of summary persistence prevents stale commit and fanout" do
    host_id = unique("host-summary-append-race")
    session_id = unique("append-race")
    stream_id = "capture:#{host_id}:#{session_id}"
    subject_id = Source.subject_id!(host_id, session_id)
    cleanup_on_exit(host_id, session_id, subject_id)
    parent = self()

    {initial, episodic_jobs_before} =
      unboxed(fn ->
        initial = canonical_session(host_id, session_id)
        {initial, episodic_job_count()}
      end)

    locker =
      Task.async(fn ->
        unboxed(fn ->
          repo().transaction(fn ->
            repo().one!(
              from(stream in EventStream,
                where: stream.stream_id == ^stream_id,
                lock: "FOR UPDATE"
              )
            )

            send(parent, :stream_locked)
            assert_receive :release_stream, 5_000
          end)
        end)
      end)

    assert_receive :stream_locked

    append =
      Task.async(fn ->
        unboxed(fn ->
          send(parent, {:append_waiting, backend_pid()})
          ingest!(event(host_id, session_id, 4, "agent.tool.completed", "late"))
        end)
      end)

    assert_receive {:append_waiting, append_backend}
    assert :ok = wait_for_lock_waiter(append_backend, "%bpm_streams%")

    summarize =
      Task.async(fn ->
        unboxed(fn ->
          send(parent, {:summary_waiting, backend_pid()})
          perform(host_id, session_id, initial)
        end)
      end)

    assert_receive {:summary_waiting, summary_backend}
    assert :ok = wait_for_lock_waiter(summary_backend, "%pg_advisory_xact_lock%")
    send(locker.pid, :release_stream)

    assert {:ok, _result} = Task.await(append, 5_000)
    assert {:ok, _} = Task.await(locker, 5_000)
    assert :ok = Task.await(summarize, 5_000)

    unboxed(fn ->
      assert repo().aggregate(
               from(summary in Summary,
                 where: summary.host_id == ^host_id and summary.session_id == ^session_id
               ),
               :count
             ) == 0

      assert episodic_job_count() == episodic_jobs_before
    end)
  end

  defp canonical_session(host_id, session_id) do
    ingest!(event(host_id, session_id, 1, "agent.session.started", "start"))
    ingest!(event(host_id, session_id, 2, "agent.prompt.submitted", "initial"))
    ingest!(event(host_id, session_id, 3, "agent.session.ended", "done"))
    {:ok, result} = Rebuild.session(host_id, session_id)
    result
  end

  defp event(host_id, session_id, sequence, type, content) do
    valid_event(%{
      "event_id" => Ecto.UUID.generate(),
      "host_id" => host_id,
      "session_id" => session_id,
      "project" => "p",
      "sequence" => sequence,
      "event_type" => type,
      "occurred_at" => "2026-08-04T01:0#{sequence}:00.000Z",
      "idempotency_key" => "#{host_id}:#{session_id}:#{sequence}:#{type}",
      "payload" => %{"message" => content}
    })
  end

  defp ingest!(event) do
    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(
               ingest_auth_context(event["host_id"], %{partition: %{scope: event["scope"]}}),
               %{
                 "batch_id" => Ecto.UUID.generate(),
                 "host_id" => event["host_id"],
                 "events" => [event]
               }
             )
  end

  defp perform(host_id, session_id, projection) do
    SummaryWorker.perform(%Styx.Job{
      args: %{
        "memory_space_id" => projection.memory_space_id,
        "host_id" => host_id,
        "client_id" => projection.client_id,
        "source_client_id" => projection.source_client_id,
        "scope" => projection.scope,
        "namespace" => projection.namespace,
        "session_id" => session_id,
        "processing_version" => "summary-v1",
        "input_revision" => projection.input_revision
      }
    })
  end

  defp episodic_job_count do
    repo().aggregate(
      from(job in Styx.Job, where: job.worker == ^inspect(EpisodicWorker)),
      :count
    )
  end

  defp backend_pid do
    %{rows: [[pid]]} = repo().query!("SELECT pg_backend_pid()")
    pid
  end

  defp wait_for_lock_waiter(backend, query_pattern, attempts \\ 100)

  defp wait_for_lock_waiter(_backend, _query_pattern, 0), do: {:error, :lock_wait_timeout}

  defp wait_for_lock_waiter(backend, query_pattern, attempts) do
    waiting =
      unboxed(fn ->
        [[count]] =
          repo().query!(
            """
            SELECT count(*)
            FROM pg_stat_activity
            WHERE datname = current_database()
              AND pid = $1
              AND wait_event_type = 'Lock'
              AND query LIKE $2
            """,
            [backend, query_pattern]
          ).rows

        count
      end)

    if waiting == 1 do
      :ok
    else
      Process.sleep(10)
      wait_for_lock_waiter(backend, query_pattern, attempts - 1)
    end
  end

  defp cleanup_on_exit(host_id, session_id, subject_id) do
    on_exit(fn ->
      unboxed(fn ->
        repo().transaction(fn ->
          repo().query!("SET LOCAL session_replication_role = replica")

          repo().query!(
            """
            DELETE FROM styx_jobs
            WHERE args->>'event_id' IN (
              SELECT id::text FROM bpm_events WHERE host_id = $1 AND session_id = $2
            )
            """,
            [host_id, session_id]
          )

          repo().query!(
            "DELETE FROM memory_summary_source_events WHERE host_id = $1 AND session_id = $2",
            [host_id, session_id]
          )

          repo().delete_all(
            from(summary in Summary,
              where: summary.host_id == ^host_id and summary.session_id == ^session_id
            )
          )

          repo().query!("DELETE FROM bpm_projected_observations WHERE subject_id = $1", [
            subject_id
          ])

          repo().query!("DELETE FROM bpm_projected_sessions WHERE subject_id = $1", [subject_id])

          repo().delete_all(
            from(row in ActivityContribution, where: row.subject_id == ^subject_id)
          )

          repo().delete_all(from(row in ActivityDaily, where: row.host_id == ^host_id))

          repo().query!("DELETE FROM bpm_projection_snapshots WHERE subject_id = $1", [subject_id])

          repo().query!("DELETE FROM bpm_projection_states WHERE subject_id = $1", [subject_id])

          repo().query!("DELETE FROM bpm_events WHERE host_id = $1 AND session_id = $2", [
            host_id,
            session_id
          ])

          repo().query!("DELETE FROM bpm_streams WHERE host_id = $1 AND session_id = $2", [
            host_id,
            session_id
          ])
        end)
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
  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
