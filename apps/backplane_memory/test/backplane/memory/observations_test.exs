defmodule Backplane.Memory.ObservationsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Events.{Event, Stream}
  alias Backplane.Memory.Observations
  alias Backplane.Memory.Projections.{ProjectedObservation, Rebuild, RepairFrontier}
  alias Backplane.Memory.Workers.SummaryWorker

  setup do
    partition = canonical_partition("observation-command-owner")
    opts = Map.to_list(partition) ++ [trusted_partition: partition]
    %{partition: partition, opts: opts}
  end

  test "writes a canonical event and no retired observation row", %{opts: opts} do
    previous = Application.get_env(:backplane_memory, :projection_repair_enabled, false)
    Application.put_env(:backplane_memory, :projection_repair_enabled, true)

    on_exit(fn ->
      Application.put_env(:backplane_memory, :projection_repair_enabled, previous)
    end)

    assert {:ok, observation} =
             Observations.record("canonical-write", "changed lib/example.ex", opts)

    event = repo().get!(Event, observation.id)
    assert event.id == observation.event_id
    assert event.schema_version == 1
    assert event.integration == "memory-api"
    assert event.source_sequence == 1
    assert event.payload_hash =~ "sha256:"
    assert event.event_type == "observation.recorded"
    assert observation.files == %{"paths" => ["lib/example.ex"]}
    assert [[0]] = repo().query!("SELECT count(*) FROM bpm_observations").rows
    assert repo().get_by!(RepairFrontier, host_id: event.host_id, session_id: event.session_id)
  end

  test "pausing background processing does not select a retired write path", %{opts: opts} do
    key = "memory.pipeline.enabled"
    previous = :ets.lookup(:backplane_settings, key)
    :ets.insert(:backplane_settings, {key, false})

    on_exit(fn ->
      :ets.delete(:backplane_settings, key)
      if previous != [], do: :ets.insert(:backplane_settings, previous)
    end)

    assert {:ok, observation} = Observations.record("processing-paused", "captured", opts)
    assert repo().get!(Event, observation.id).schema_version == 1
    assert [[0]] = repo().query!("SELECT count(*) FROM bpm_observations").rows
  end

  test "privacy filtering, truncation, errors and file extraction survive the cutover", %{
    opts: opts
  } do
    assert {:ok, observation} =
             Observations.record(
               "filtered-write",
               "edited /project/lib/foo.ex " <> String.duplicate("x", 65_537),
               opts ++
                 [tool_name: "Bash", is_error: true, payload: %{"password" => "private-value"}]
             )

    event = repo().get!(Event, observation.id)
    assert byte_size(observation.content) == 65_536
    assert observation.content == event.content
    assert observation.is_error
    assert event.event_type == "tool.call.failed"
    assert event.status == "failed"
    refute event.payload["password"] == "private-value"
  end

  test "exact retries return the original canonical identity and changed retries conflict", %{
    opts: opts
  } do
    opts = opts ++ [idempotency_key: "stable-command", tool_name: "Bash"]
    assert {:ok, original} = Observations.record("retry", "stable", opts)
    assert {:ok, duplicate} = Observations.record("retry", "stable", opts)
    assert duplicate.id == original.id
    assert {:error, :idempotency_conflict} = Observations.record("retry", "changed", opts)
    assert repo().aggregate(from(e in Event, where: e.session_id == "retry"), :count) == 1
  end

  test "oversized payload remains idempotently retryable", %{opts: opts} do
    opts =
      opts ++
        [idempotency_key: "large-payload", payload: %{"blob" => String.duplicate("x", 262_144)}]

    assert {:ok, original} = Observations.record("oversized", "stable", opts)
    assert {:ok, retry} = Observations.record("oversized", "stable", opts)
    assert original.id == retry.id
    assert repo().get!(Event, original.id).payload["_backplane"]["payload"]["truncated"]
  end

  test "shared partitions keep host session and request identities independent", %{
    partition: partition
  } do
    owners = [partition, %{partition | host_id: "second-observation-owner"}]

    identities =
      for owner <- owners do
        opts = Map.to_list(owner) ++ [trusted_partition: owner]
        assert {:ok, _} = Observations.register_session("shared-session", "project", opts)

        assert {:ok, original} =
                 Observations.record(
                   "shared-session",
                   "host-specific observation",
                   opts ++ [idempotency_key: "same-request-key"]
                 )

        assert {:ok, retry} =
                 Observations.record(
                   "shared-session",
                   "host-specific observation",
                   opts ++ [idempotency_key: "same-request-key"]
                 )

        assert original.id == retry.id
        assert {1, nil} = Observations.end_session("shared-session", opts)
        assert {0, nil} = Observations.end_session("shared-session", opts)
        original.id
      end

    assert length(Enum.uniq(identities)) == 2

    assert repo().aggregate(from(e in Event, where: e.session_id == "shared-session"), :count) ==
             6
  end

  test "caller metadata cannot replace trusted ownership or system actor", %{
    opts: opts,
    partition: partition
  } do
    assert {:ok, observation} =
             Observations.record(
               "trusted-owner",
               "safe",
               opts ++ [host_id: "forged", actor_type: "user", role: "user"]
             )

    event = repo().get!(Event, observation.id)
    assert event.host_id == partition.host_id
    assert event.memory_space_id == partition.memory_space_id
    assert event.actor_type == "system"
    assert event.role == "system"
  end

  test "invalid events leave no stream, event or retired row", %{opts: opts} do
    assert {:error, :invalid_content} = Observations.record("empty", "", opts)

    assert {:error, :invalid_event_type} =
             Observations.record("invalid", "content", opts ++ [event_type: "unknown"])

    assert {:error, :missing_identity} = Observations.record("", "content", opts)
    assert {:error, :incomplete_partition} = Observations.record("unowned", "content")
    assert repo().aggregate(Event, :count) == 0
    assert repo().aggregate(Stream, :count) == 0
  end

  test "registration uses authoritative events even while projections lag", %{opts: opts} do
    assert {:ok, first} = Observations.register_session("lifecycle", "original", opts)
    assert {:ok, retry} = Observations.register_session("lifecycle", "overwrite", opts)
    assert retry.project == first.project
    refute repo().get_by(Backplane.Memory.Projections.ProjectedSession, session_id: "lifecycle")
    assert {1, nil} = Observations.end_session("lifecycle", opts)
    assert {0, nil} = Observations.end_session("lifecycle", opts)

    events =
      repo().all(from(e in Event, where: e.session_id == "lifecycle", order_by: e.sequence))

    assert Enum.map(events, & &1.event_type) == ["session.started", "session.ended"]
    assert Enum.map(events, & &1.source_sequence) == [1, 2]
    assert repo().get!(Stream, hd(events).stream_id).closed_at
    assert [[0]] = repo().query!("SELECT count(*) FROM memory_sessions").rows
  end

  test "ending an absent session preserves require_existing semantics without creating a stream",
       %{opts: opts} do
    assert {0, nil} = Observations.end_session("missing", opts)

    assert {:error, :not_found} =
             Observations.end_session("missing", opts ++ [require_existing: true])

    assert repo().aggregate(Stream, :count) == 0
  end

  test "only the first committed end queues canonical consolidation", %{
    opts: opts,
    partition: partition
  } do
    Styx.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _} = Observations.register_session("summary-once", "project", opts)
      assert {1, nil} = Observations.end_session("summary-once", opts)
      assert {0, nil} = Observations.end_session("summary-once", opts)

      assert [job] =
               Styx.Testing.all_enqueued(repo(),
                 worker: SummaryWorker,
                 args: %{"session_id" => "summary-once"}
               )

      assert job.args["host_id"] == partition.host_id
      assert job.args["input_revision"]
      assert job.args["memory_space_id"] == partition.memory_space_id
    end)
  end

  test "an explicit shared stream cannot cross canonical partitions", %{opts: opts} do
    assert {:ok, _} =
             Observations.record("stream-owner", "owned", opts ++ [stream_id: "explicit-stream"])

    other = canonical_partition("other-observation-owner")
    other_opts = Map.to_list(other) ++ [trusted_partition: other, stream_id: "explicit-stream"]

    assert {:error, :stream_metadata_conflict} =
             Observations.record("stream-owner", "foreign", other_opts)

    assert repo().aggregate(Event, :count) == 1
  end

  test "observation commands cannot change a canonical subject's owner through another stream", %{
    partition: partition
  } do
    assert {:ok, _} =
             Backplane.Memory.Events.Store.append(
               Map.merge(partition, %{
                 stream_id: "captured-owner",
                 session_id: "one-subject",
                 schema_version: 1,
                 source_sequence: 1,
                 event_type: "agent.prompt.submitted",
                 content: "captured source"
               })
             )

    for changed <- [
          %{partition | namespace: "other"},
          %{partition | scope: "other"},
          %{partition | client_id: "other"},
          %{partition | source_client_id: "other"}
        ],
        stream_opts <- [[], [stream_id: "explicit-owner-drift"]] do
      opts = Map.to_list(changed) ++ [trusted_partition: changed] ++ stream_opts

      assert {:error, :stream_metadata_conflict} =
               Observations.record("one-subject", "rejected source", opts)

      assert {:error, :stream_metadata_conflict} =
               Observations.register_session("one-subject", "project", opts)
    end

    assert repo().aggregate(Event, :count) == 1
    assert repo().aggregate(Stream, :count) == 1

    assert {:ok, _} =
             Observations.record(
               "one-subject",
               "same canonical owner",
               Map.to_list(partition) ++ [trusted_partition: partition]
             )

    assert {:ok, _} = Rebuild.session(partition.host_id, "one-subject")
  end

  test "file history reads projections with canonical IDs and stable occurrence ordering", %{
    opts: opts,
    partition: partition
  } do
    occurred_at = ~U[2026-01-01 00:00:00.000000Z]

    assert {:ok, first} =
             Observations.record(
               "files-a",
               "changed lib/foo.ex",
               opts ++ [occurred_at: occurred_at]
             )

    assert {:ok, second} =
             Observations.record(
               "files-b",
               "changed lib/foo.ex",
               opts ++ [occurred_at: occurred_at]
             )

    assert {:ok, _} = Rebuild.session(partition.host_id, "files-a")
    assert {:ok, _} = Rebuild.session(partition.host_id, "files-b")

    assert Enum.map(Observations.file_history(["lib/foo.ex"], opts), & &1.event_id) ==
             Enum.sort([first.id, second.id], :desc)

    assert [%ProjectedObservation{event_id: id}] =
             Observations.file_history(
               ["lib/foo.ex"],
               opts ++ [exclude_session: "files-a", limit: 1]
             )

    assert id == second.id
    assert [] = Observations.file_history(["lib/foo.ex"])
  end

  test "file history excludes other canonical partitions", %{opts: opts, partition: partition} do
    assert {:ok, _} = Observations.record("local-files", "changed lib/foo.ex", opts)
    assert {:ok, _} = Rebuild.session(partition.host_id, "local-files")
    other = canonical_partition("foreign-file-owner")
    other_opts = Map.to_list(other) ++ [trusted_partition: other]
    assert {:ok, _} = Observations.record("foreign-files", "foreign lib/foo.ex", other_opts)
    assert {:ok, _} = Rebuild.session(other.host_id, "foreign-files")
    assert [%{host_id: host}] = Observations.file_history(["lib/foo.ex"], opts)
    assert host == partition.host_id
  end
end
