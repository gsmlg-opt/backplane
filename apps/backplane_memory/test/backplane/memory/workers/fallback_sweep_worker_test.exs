defmodule Backplane.Memory.Workers.FallbackSweepWorkerTest do
  use Backplane.Memory.DataCase, async: false

  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.{Audit, Config, Ingest, Observations}
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Projections.{ProjectedSession, Rebuild}
  alias Backplane.Memory.Sessions.FallbackSweep
  alias Backplane.Memory.Workers.{FallbackSweepWorker, SummaryWorker}

  @settings_table :backplane_settings
  @stale_key "memory.session_stale_after_seconds"
  @grace_key "memory.event_gap_grace_seconds"
  @batch_key "memory.fallback_sweep_batch_size"

  setup do
    snapshot =
      Map.new([@stale_key, @grace_key, @batch_key], fn key ->
        {key, :ets.lookup(@settings_table, key)}
      end)

    :ets.insert(@settings_table, {@stale_key, 60})
    :ets.insert(@settings_table, {@grace_key, 60})
    :ets.insert(@settings_table, {@batch_key, 100})

    on_exit(fn ->
      Enum.each(snapshot, fn
        {key, []} -> :ets.delete(@settings_table, key)
        {_key, [row]} -> :ets.insert(@settings_table, row)
      end)
    end)

    :ok
  end

  test "default stale threshold plus cron cadence meets the four-hour SLA" do
    :ets.delete(@settings_table, @stale_key)
    oban_config = Application.fetch_env!(:backplane, Oban)

    {Oban.Plugins.Cron, cron_options} =
      Enum.find(oban_config[:plugins], fn
        {Oban.Plugins.Cron, _options} -> true
        _other -> false
      end)

    assert {"*/30 * * * *", FallbackSweepWorker} in cron_options[:crontab]

    assert Config.session_stale_after_seconds() + Config.event_gap_grace_seconds() + 1_800 <=
             4 * 3_600
  end

  test "stale canonical activity is abandoned once, audited, and summarized after gap grace" do
    now = ~U[2026-08-12 08:00:00.000000Z]
    session_id = unique("stale")
    ingest!(event("host-stale", session_id, 1, "agent.session.started", shift(now, -61)))
    assert {:ok, %{session_status: "active"}} = Rebuild.session("host-stale", session_id)

    assert {:ok, %{abandoned: 1, enqueued: 0, swept: 1}} = sweep(now)
    assert {:ok, %{abandoned: 0, enqueued: 0, swept: 0}} = sweep(now)

    assert [abandonment] = abandonment_events("host-stale", session_id)
    assert abandonment.correlation_id == abandonment.trace["correlation_id"]
    assert abandonment.payload["source_input_revision"]

    assert %ProjectedSession{status: "abandoned", gap_count: 0} =
             repo().get_by!(ProjectedSession, host_id: "host-stale", session_id: session_id)

    assert [audit] = Audit.list(operation: "session.abandoned")
    assert audit.target_ids["event_id"] == abandonment.id
    assert audit.metadata["correlation_id"] == abandonment.correlation_id

    assert [] = Oban.Testing.all_enqueued(repo(), worker: SummaryWorker)

    assert {:ok, %{abandoned: 0, enqueued: 1, swept: 1}} = sweep(shift(now, 60))
    assert [_job] = Oban.Testing.all_enqueued(repo(), worker: SummaryWorker)
    assert {:ok, %{enqueued: 0, swept: 0}} = sweep(shift(now, 61))
    assert [_job] = Oban.Testing.all_enqueued(repo(), worker: SummaryWorker)
  end

  test "threshold is inclusive" do
    now = ~U[2026-08-12 09:00:00.000000Z]
    below = unique("below")
    exact = unique("exact")

    ingest!(event("host-threshold", below, 1, "agent.session.started", shift(now, -59)))
    ingest!(event("host-threshold", exact, 1, "agent.session.started", shift(now, -60)))
    assert {:ok, _} = Rebuild.session("host-threshold", below)
    assert {:ok, _} = Rebuild.session("host-threshold", exact)

    assert {:ok, %{abandoned: 1}} = sweep(now)
    assert [] = abandonment_events("host-threshold", below)
    assert [_event] = abandonment_events("host-threshold", exact)
  end

  test "stale active gaps are abandoned and summarized when grace expires" do
    now = ~U[2026-08-12 09:15:00.000000Z]
    session_id = unique("stale-gap")

    ingest!(event("host-stale-gap", session_id, 1, "agent.session.started", shift(now, -120)))

    ingest!(event("host-stale-gap", session_id, 3, "agent.prompt.submitted", shift(now, -61)))

    assert {:ok, %{session_status: "active", gaps: [%{"from" => 2, "to" => 2}]}} =
             Rebuild.session("host-stale-gap", session_id)

    assert {:ok, %{abandoned: 1, enqueued: 0}} = sweep(now)

    assert %ProjectedSession{status: "abandoned", gap_count: 1} =
             repo().get_by!(ProjectedSession,
               host_id: "host-stale-gap",
               session_id: session_id
             )

    assert [] = Oban.Testing.all_enqueued(repo(), worker: SummaryWorker)
    assert {:ok, %{enqueued: 0}} = sweep(shift(now, 59))
    assert {:ok, %{enqueued: 1}} = sweep(shift(now, 60))
    assert [_job] = Oban.Testing.all_enqueued(repo(), worker: SummaryWorker)
  end

  test "an event arriving after candidate selection prevents false abandonment" do
    now = ~U[2026-08-12 09:30:00.000000Z]
    session_id = unique("refreshed")
    ingest!(event("host-refresh", session_id, 1, "agent.session.started", shift(now, -120)))
    assert {:ok, _} = Rebuild.session("host-refresh", session_id)

    owner = self()

    task =
      Task.async(fn ->
        Oban.Testing.with_testing_mode(:manual, fn ->
          FallbackSweep.run(now,
            after_candidates: fn candidates ->
              send(owner, {:candidates_selected, candidates})
              receive do: (:continue -> :ok)
            end
          )
        end)
      end)

    assert_receive {:candidates_selected, [{"host-refresh", ^session_id}]}
    ingest!(event("host-refresh", session_id, 2, "agent.prompt.submitted", now))
    send(task.pid, :continue)

    assert {:ok, %{abandoned: 0, skipped: 1}} = Task.await(task, 10_000)
    assert [] = abandonment_events("host-refresh", session_id)
  end

  test "same session id on two hosts is independently closed while legacy decoys are ignored" do
    now = ~U[2026-08-12 10:00:00.000000Z]
    session_id = unique("shared")

    for host_id <- ["host-a", "host-b"] do
      ingest!(event(host_id, session_id, 1, "agent.session.started", shift(now, -61)))
      assert {:ok, _} = Rebuild.session(host_id, session_id)
    end

    Observations.register_session(session_id, "legacy-decoy")
    Observations.end_session(session_id)

    repo().update_all(
      from(session in Backplane.Memory.Observations.Session,
        where: session.session_id == ^session_id
      ),
      set: [consolidated_at: nil]
    )

    assert {:ok, %{candidates: 2, abandoned: 2, swept: 2}} = sweep(now)
    assert [_event] = abandonment_events("host-a", session_id)
    assert [_event] = abandonment_events("host-b", session_id)

    legacy = repo().get!(Backplane.Memory.Observations.Session, session_id)
    assert is_nil(legacy.consolidated_at)
  end

  test "stopped and completed sessions enqueue processing without false abandonment" do
    now = ~U[2026-08-12 11:00:00.000000Z]

    for {host_id, session_id, terminal} <- [
          {"host-stopped", unique("stopped"), "agent.session.stopped"},
          {"host-completed", unique("completed"), "agent.session.ended"}
        ] do
      ingest!(event(host_id, session_id, 1, "agent.session.started", shift(now, -120)))
      ingest!(event(host_id, session_id, 2, terminal, shift(now, -61)))
      assert {:ok, _} = Rebuild.session(host_id, session_id)
    end

    assert {:ok, %{abandoned: 0, enqueued: 2, swept: 2}} = sweep(now)

    assert [] =
             repo().all(
               from(event in Event, where: event.event_type == "agent.session.abandoned")
             )

    assert [_, _] = Oban.Testing.all_enqueued(repo(), worker: SummaryWorker)
  end

  test "sequence gaps defer only until grace and a late repair gets a new summary revision" do
    now = ~U[2026-08-12 12:00:00.000000Z]
    gapped = unique("gapped")

    ingest!(event("host-gap", gapped, 1, "agent.session.started", shift(now, -180)))
    ingest!(event("host-gap", gapped, 3, "agent.session.ended", shift(now, -30)))
    assert {:ok, %{gaps: [_gap]}} = Rebuild.session("host-gap", gapped)
    assert {:ok, %{enqueued: 0}} = sweep(now)
    assert [] = Oban.Testing.all_enqueued(repo(), worker: SummaryWorker)

    assert {:ok, %{enqueued: 1}} = sweep(shift(now, 30))
    assert [incomplete_job] = Oban.Testing.all_enqueued(repo(), worker: SummaryWorker)

    ingest!(event("host-gap", gapped, 2, "agent.tool.completed", shift(now, -29)))
    assert {:ok, repaired} = Rebuild.session("host-gap", gapped)
    refute repaired.input_revision == incomplete_job.args["input_revision"]
    assert {:ok, %{enqueued: 1}} = sweep(shift(now, 31))

    assert [first_job, second_job] =
             Oban.Testing.all_enqueued(repo(), worker: SummaryWorker)
             |> Enum.sort_by(& &1.id)

    assert first_job.args["input_revision"] != second_job.args["input_revision"]

    abandoned = unique("late-end")
    ingest!(event("host-late", abandoned, 1, "agent.session.started", shift(now, -180)))
    assert {:ok, _} = Rebuild.session("host-late", abandoned)
    assert {:ok, %{abandoned: 1}} = sweep(now)

    ingest!(event("host-late", abandoned, 2, "agent.session.ended", shift(now, 1)))

    assert {:ok, %{session_status: "completed"} = late} =
             Rebuild.session("host-late", abandoned)

    assert late.gaps == []
    assert [_event] = abandonment_events("host-late", abandoned)
    assert {:ok, %{enqueued: 1}} = sweep(shift(now, 61))
  end

  test "two sweep nodes serialize on canonical streams and report one actual closure" do
    now = ~U[2026-08-12 13:00:00.000000Z]
    session_id = unique("race")
    ingest!(event("host-race", session_id, 1, "agent.session.started", shift(now, -61)))
    assert {:ok, _} = Rebuild.session("host-race", session_id)

    results =
      1..2
      |> Enum.map(fn _index -> Task.async(fn -> sweep(now) end) end)
      |> Task.await_many(10_000)

    assert Enum.sum(Enum.map(results, fn {:ok, result} -> result.abandoned end)) == 1
    assert [_event] = abandonment_events("host-race", session_id)
    assert [_audit] = Audit.list(operation: "session.abandoned")
  end

  test "candidate query is bounded and uses the lifecycle candidate index" do
    now = ~U[2026-08-12 14:00:00.000000Z]
    query = FallbackSweep.candidate_query(now, 7)
    {sql, params} = Ecto.Adapters.SQL.to_sql(:all, repo(), query)

    assert sql =~ "LIMIT"
    assert 7 in params

    assert [[index_definition]] =
             repo().query!("""
             SELECT indexdef
             FROM pg_indexes
             WHERE schemaname = current_schema()
               AND indexname = 'bpm_projected_sessions_fallback_candidates_idx'
             """).rows

    assert index_definition =~ "USING btree (last_event_at, subject_id)"
    assert index_definition =~ "status"
    assert index_definition =~ "active"
    assert index_definition =~ "stopped"
    assert index_definition =~ "completed"
    assert index_definition =~ "abandoned"

    # A sandbox starts with a tiny relation, where PostgreSQL reasonably chooses
    # another cheap plan for the full joined query. Probe the candidate relation
    # directly and force index planning so cost estimates cannot hide whether the
    # partial predicate and ordering are usable by this index.
    repo().query!("SET LOCAL enable_seqscan = off")
    repo().query!("SET LOCAL enable_bitmapscan = off")
    repo().query!("SET LOCAL enable_sort = off")

    plan =
      repo().query!(
        """
        EXPLAIN
        SELECT host_id, session_id
        FROM bpm_projected_sessions
        WHERE status IN ('active', 'stopped', 'completed', 'abandoned')
          AND last_event_at <= $1
        ORDER BY last_event_at, subject_id
        LIMIT 7
        """,
        [now]
      ).rows
      |> List.flatten()
      |> Enum.join("\n")

    assert plan =~ "bpm_projected_sessions_fallback_candidates_idx"
  end

  defp sweep(now) do
    Oban.Testing.with_testing_mode(:manual, fn ->
      FallbackSweep.run(now)
    end)
  end

  defp event(host_id, session_id, sequence, type, occurred_at) do
    valid_event(%{
      "event_id" => Ecto.UUID.generate(),
      "host_id" => host_id,
      "session_id" => session_id,
      "sequence" => sequence,
      "event_type" => type,
      "occurred_at" => DateTime.to_iso8601(occurred_at),
      "captured_at" => DateTime.to_iso8601(occurred_at),
      "idempotency_key" => "#{host_id}:#{session_id}:#{sequence}:#{type}"
    })
  end

  defp ingest!(event) do
    auth = ingest_auth_context(event["host_id"], %{partition: %{scope: event["scope"]}})

    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(auth, %{
               "batch_id" => Ecto.UUID.generate(),
               "host_id" => event["host_id"],
               "events" => [event]
             })
  end

  defp abandonment_events(host_id, session_id) do
    repo().all(
      from(event in Event,
        where:
          event.host_id == ^host_id and event.session_id == ^session_id and
            event.event_type == "agent.session.abandoned",
        order_by: [asc: event.id]
      )
    )
  end

  defp shift(datetime, seconds), do: DateTime.add(datetime, seconds, :second)
  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
