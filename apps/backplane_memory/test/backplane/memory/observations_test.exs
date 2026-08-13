defmodule Backplane.Memory.ObservationsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Observations
  alias Backplane.Memory.Events.{Event, Store, Stream}
  alias Backplane.Memory.Observations.{Observation, Session}
  alias Backplane.Memory.Workers.SummaryWorker

  @settings_table :backplane_settings

  setup do
    snapshot =
      for key <- ["memory.pipeline.enabled", "memory.events.enabled", "memory.events.dual_write"],
          into: %{},
          do: {key, :ets.lookup(@settings_table, key)}

    on_exit(fn ->
      Enum.each(snapshot, fn {key, rows} ->
        :ets.delete(@settings_table, key)
        if rows != [], do: :ets.insert(@settings_table, rows)
      end)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # record/3
  # ---------------------------------------------------------------------------

  describe "record/3" do
    test "inserts an observation and returns {:ok, obs}" do
      assert {:ok, obs} = Observations.record("sess-1", "fixed a bug in lib/foo.ex")
      assert obs.session_id == "sess-1"
      assert obs.content == "fixed a bug in lib/foo.ex"
      assert obs.is_error == false
      assert is_binary(obs.id)
    end

    test "stores optional tool_name" do
      assert {:ok, obs} = Observations.record("sess-2", "ran tests", tool_name: "Bash")
      assert obs.tool_name == "Bash"
    end

    test "stores is_error flag" do
      assert {:ok, obs} = Observations.record("sess-3", "compilation failed", is_error: true)
      assert obs.is_error == true
    end

    test "extracts file paths into files map" do
      assert {:ok, obs} =
               Observations.record("sess-4", "edited /project/lib/foo.ex and apps/bar/mix.exs")

      paths = obs.files["paths"]
      assert is_list(paths)
      assert Enum.any?(paths, &String.contains?(&1, "foo.ex"))
    end

    test "returns {:error, :filtered} when privacy filter rejects the content" do
      # Privacy filter strips secrets; we rely on the filter module's own logic.
      # A session_id-only call with empty content triggers changeset validation instead.
      result = Observations.record("sess-5", "")
      # Either filtered or changeset error — it must not be :ok
      assert result != {:ok, %{}}
      assert match?({:error, _}, result)
    end

    test "dual-write records the legacy observation and ordered event atomically" do
      enable_dual_write()

      assert {:ok, observation} = Observations.record("dual-write-session", "recorded safely")

      assert [event] =
               repo().all(
                 from(e in Event,
                   where: e.session_id == "dual-write-session"
                 )
               )

      refute event.id == observation.id
      assert event.stream_id == "session:dual-write-session"
      assert event.event_type == "legacy.observation"
      assert event.content == observation.content
      assert event.sequence == 1
      assert event.payload["_backplane"]["legacy_observation_id"] == observation.id
    end

    test "dual-write sanitizes content once and shares the bounded result" do
      enable_dual_write()
      content = String.duplicate("x", 65_537)

      assert {:ok, observation} =
               Observations.record("single-sanitize-session", content)

      event = event_for_observation(observation)

      assert observation.content == event.content
      assert byte_size(observation.content) == 65_536
    end

    test "all flags false keeps the unchanged legacy path event-free" do
      disable_all_flags()

      assert {:ok, %Observation{content: "legacy only"}} =
               Observations.record("legacy-session", "legacy only")

      refute repo().exists?(from(e in Event, where: e.session_id == "legacy-session"))
      refute repo().get(Stream, "session:legacy-session")
    end

    test "session lifecycle transitions dual-write ordered events" do
      enable_dual_write()

      assert {:ok, _session} = Observations.register_session("lifecycle-session", "project")
      assert {1, nil} = Observations.end_session("lifecycle-session")

      assert Enum.map(
               repo().all(
                 from(e in Event,
                   where: e.session_id == "lifecycle-session",
                   order_by: e.sequence
                 )
               ),
               & &1.event_type
             ) ==
               ["session.started", "session.ended"]
    end

    test "events-only mode remains on the legacy path and ignores event-only options" do
      enable_events_only()

      assert {:ok, observation} =
               Observations.record("events-only-session", "legacy survives",
                 event_type: "not.accepted",
                 payload: [],
                 stream_id: nil,
                 idempotency_key: %{invalid: true}
               )

      assert %Observation{} = observation
      assert observation.content == "legacy survives"
      refute repo().exists?(from(e in Event, where: e.session_id == "events-only-session"))
    end

    test "dual-write derives completed, failed, and legacy event types" do
      enable_dual_write()

      assert {:ok, completed} =
               Observations.record("mapping-completed", "tool output", tool_name: "Bash")

      assert {:ok, failed} =
               Observations.record("mapping-failed", "tool error",
                 tool_name: "Bash",
                 is_error: true
               )

      assert {:ok, legacy} = Observations.record("mapping-legacy", "plain observation")

      assert event_for_observation(completed).event_type == "tool.call.completed"
      assert event_for_observation(failed).event_type == "tool.call.failed"
      assert event_for_observation(legacy).event_type == "legacy.observation"
    end

    test "dual-write accepts only the additive event option whitelist" do
      enable_dual_write()
      occurred_at = ~U[2026-07-16 04:00:00.000000Z]
      forbidden_id = Ecto.UUID.generate()

      assert {:ok, observation} =
               Observations.record("explicit-session", "explicit content",
                 tool_name: "CustomTool",
                 event_type: "task.created",
                 payload: %{"input" => %{"value" => 1}},
                 stream_id: "explicit-stream",
                 project: "explicit-project",
                 agent_id: "explicit-agent",
                 host_id: "explicit-host",
                 client_id: "explicit-client",
                 run_id: "explicit-run",
                 correlation_id: "explicit-correlation",
                 causation_id: Ecto.UUID.generate(),
                 occurred_at: occurred_at,
                 idempotency_key: "explicit-key",
                 id: forbidden_id,
                 namespace: "public",
                 importance: 100,
                 actor_type: "user",
                 role: "user",
                 status: "forged"
               )

      event = event_for_observation(observation)

      assert event.id != observation.id
      assert event.id != forbidden_id
      assert event.stream_id == "explicit-stream"
      assert event.session_id == "explicit-session"
      assert event.project == "explicit-project"
      assert event.agent_id == "explicit-agent"
      assert event.host_id == "explicit-host"
      assert event.client_id == "explicit-client"
      assert event.run_id == "explicit-run"
      assert event.event_type == "task.created"
      assert event.tool_name == "CustomTool"
      assert event.correlation_id == "explicit-correlation"
      assert event.occurred_at == occurred_at
      assert event.idempotency_key == "explicit-key"
      assert event.namespace == "private"
      assert event.importance == 0
      assert event.actor_type == "system"
      assert event.role == "system"
      assert event.status == "ok"
      assert event.payload["input"] == %{"value" => 1}
      assert event.payload["_backplane"]["legacy_observation_id"] == observation.id
    end

    test "an exact idempotent retry returns the linked original observation" do
      enable_dual_write()
      session_id = "observation-retry"
      opts = [tool_name: "Bash", idempotency_key: "observation-retry-key"]

      assert {:ok, original} = Observations.record(session_id, "stable", opts)
      assert {:ok, retry} = Observations.record(session_id, "stable", opts)
      assert retry.id == original.id

      assert repo().aggregate(from(o in Observation, where: o.session_id == ^session_id), :count) ==
               1

      assert repo().aggregate(from(e in Event, where: e.session_id == ^session_id), :count) == 1
      assert repo().get!(Stream, "session:" <> session_id).next_sequence == 2
    end

    test "an oversized payload keeps linkage and remains idempotently retryable" do
      enable_dual_write()
      session_id = "observation-oversized-retry"

      opts = [
        tool_name: "Bash",
        idempotency_key: "observation-oversized-key",
        payload: %{"blob" => String.duplicate("x", 262_144)}
      ]

      assert {:ok, original} = Observations.record(session_id, "stable oversized output", opts)
      assert {:ok, retry} = Observations.record(session_id, "stable oversized output", opts)
      assert retry.id == original.id

      event = event_for_observation(original)
      assert event.payload["_backplane"]["legacy_observation_id"] == original.id
      assert event.payload["_backplane"]["payload"]["truncated"]
      assert byte_size(Jason.encode!(event.payload)) <= 262_144
    end

    test "a changed retry conflicts and never inserts a second observation" do
      enable_dual_write()
      session_id = "observation-conflict"
      opts = [tool_name: "Bash", idempotency_key: "observation-conflict-key"]

      assert {:ok, _original} = Observations.record(session_id, "stable", opts)

      assert {:error, :idempotency_conflict} =
               Observations.record(session_id, "changed", opts)

      assert repo().aggregate(from(o in Observation, where: o.session_id == ^session_id), :count) ==
               1
    end

    test "observation failure rolls back the event, stream, metadata, and cursor" do
      enable_dual_write()
      session_id = "observation-rollback"
      stream_id = "session:" <> session_id

      assert {:error, %Ecto.Changeset{}} =
               Observations.record(session_id, "",
                 project: "must-roll-back",
                 idempotency_key: "rollback-empty"
               )

      refute repo().get(Stream, stream_id)
      refute repo().get_by(Event, idempotency_key: "rollback-empty")

      assert {:ok, observation} = Observations.record(session_id, "valid")
      assert event_for_observation(observation).sequence == 1
    end

    test "event validation failure inserts no observation" do
      enable_dual_write()

      assert {:error, :invalid_event_type} =
               Observations.record("invalid-event-session", "content", event_type: "not.accepted")

      refute repo().exists?(
               from(o in Observation, where: o.session_id == "invalid-event-session")
             )
    end

    test "outer transaction emits exactly once after resolution and reports rollback as error" do
      enable_dual_write()
      attach_event_telemetry()

      opts = [tool_name: "Bash", idempotency_key: "outer-telemetry-success"]

      assert {:ok, original} = Observations.record("outer-telemetry", "persisted", opts)

      assert_receive {:event_telemetry, [:backplane, :memory, :event, :append],
                      %{duration: duration}, %{status: :inserted}}

      assert duration >= 0
      refute_receive {:event_telemetry, _, _, _}

      assert {:ok, duplicate} = Observations.record("outer-telemetry", "persisted", opts)
      assert duplicate.id == original.id

      assert_receive {:event_telemetry, [:backplane, :memory, :event, :duplicate], _,
                      %{status: :duplicate}}

      refute_receive {:event_telemetry, _, _, _}

      assert {:error, %Ecto.Changeset{}} =
               Observations.record("outer-telemetry-rollback", "",
                 idempotency_key: "outer-telemetry-rollback"
               )

      assert_receive {:event_telemetry, [:backplane, :memory, :event, :error],
                      %{content_bytes: 0, payload_bytes: 0}, %{status: :error}}

      refute_receive {:event_telemetry, [:backplane, :memory, :event, :append], _, _}
      refute repo().get(Stream, "session:outer-telemetry-rollback")
    end
  end

  # ---------------------------------------------------------------------------
  # register_session/2
  # ---------------------------------------------------------------------------

  describe "register_session/2" do
    test "creates a new session record" do
      assert {:ok, session} = Observations.register_session("sid-a", "my-project")
      assert session.session_id == "sid-a"
      assert session.project == "my-project"
    end

    test "is idempotent — re-registering the same session_id does not error" do
      assert {:ok, _} = Observations.register_session("sid-b", "proj")
      # Second call must not crash
      assert {:ok, _} = Observations.register_session("sid-b", "proj-updated")
    end

    test "idempotent call does not overwrite the original project" do
      assert {:ok, _} = Observations.register_session("sid-c", "original")
      # on_conflict: :nothing — second insert silently skipped
      assert {:ok, _} = Observations.register_session("sid-c", "overwrite")

      session = repo().get(Session, "sid-c")
      assert session.project == "original"
    end

    test "dual-write creates session.started only for the first registration" do
      enable_dual_write()
      session_id = "register-dual"

      assert {:ok, %Session{}} = Observations.register_session(session_id, "original")
      assert {:ok, %Session{}} = Observations.register_session(session_id, "overwrite")

      assert repo().get!(Session, session_id).project == "original"

      assert [%Event{event_type: "session.started", sequence: 1}] =
               repo().all(from(e in Event, where: e.session_id == ^session_id))
    end

    test "enabling dual-write does not backfill an already registered legacy session" do
      session_id = "register-no-backfill"
      assert {:ok, %Session{}} = Observations.register_session(session_id, "legacy")

      enable_dual_write()
      assert {:ok, %Session{}} = Observations.register_session(session_id, "ignored")

      refute repo().exists?(from(e in Event, where: e.session_id == ^session_id))
      assert repo().get!(Session, session_id).project == "legacy"
    end

    test "a lifecycle idempotency conflict rolls back the session insert" do
      enable_dual_write()
      session_id = "register-conflict"
      key = "session.started:" <> session_id

      assert {:ok, _event} =
               Store.append(
                 %{
                   stream_id: "other-register-stream",
                   event_type: "session.started",
                   idempotency_key: key
                 },
                 telemetry: false
               )

      assert {:error, :idempotency_conflict} =
               Observations.register_session(session_id, "project")

      refute repo().get(Session, session_id)
    end

    test "lifecycle telemetry emits only for attempted committed or failed events" do
      enable_dual_write()
      attach_event_telemetry()

      session_id = "lifecycle-telemetry"
      assert {:ok, %Session{}} = Observations.register_session(session_id, "project")

      assert_receive {:event_telemetry, [:backplane, :memory, :event, :append], _,
                      %{status: :inserted, event_type: "session.started"}}

      assert {:ok, %Session{}} = Observations.register_session(session_id, "ignored")
      refute_receive {:event_telemetry, _, _, _}

      assert {1, nil} = Observations.end_session(session_id)

      assert_receive {:event_telemetry, [:backplane, :memory, :event, :append], _,
                      %{status: :inserted, event_type: "session.ended"}}

      assert {0, nil} = Observations.end_session(session_id)
      assert {0, nil} = Observations.end_session("unknown-lifecycle-telemetry")
      refute_receive {:event_telemetry, _, _, _}

      failed_session = "lifecycle-telemetry-failed"
      key = "session.started:" <> failed_session

      assert {:ok, _} =
               Store.append(
                 %{
                   stream_id: "conflicting-lifecycle-telemetry",
                   event_type: "session.started",
                   idempotency_key: key
                 },
                 telemetry: false
               )

      assert {:error, :idempotency_conflict} =
               Observations.register_session(failed_session, "project")

      assert_receive {:event_telemetry, [:backplane, :memory, :event, :error], _,
                      %{status: :error}}

      refute_receive {:event_telemetry, _, _, _}
    end
  end

  # ---------------------------------------------------------------------------
  # end_session/1
  # ---------------------------------------------------------------------------

  describe "end_session/1" do
    test "sets ended_at on a started session" do
      {:ok, _} = Observations.register_session("end-a", "p")
      assert {1, nil} = Observations.end_session("end-a")

      session = repo().get(Session, "end-a")
      assert session.ended_at != nil
    end

    test "calling end_session on an already-ended session is a no-op" do
      {:ok, _} = Observations.register_session("end-b", "p")
      assert {1, nil} = Observations.end_session("end-b")
      # Second call matches 0 rows (already has ended_at set)
      assert {0, nil} = Observations.end_session("end-b")
    end

    test "end_session on unknown session_id returns {0, nil}" do
      assert {0, nil} = Observations.end_session("nonexistent-session-xyz")
    end

    test "dual-write atomically ends the session, appends the event, and closes the stream" do
      enable_dual_write()
      session_id = "end-dual"

      assert {:ok, _session} = Observations.register_session(session_id, "project")
      assert {1, nil} = Observations.end_session(session_id)

      assert %Session{ended_at: %DateTime{}} = repo().get!(Session, session_id)

      assert [
               %Event{event_type: "session.started", sequence: 1},
               %Event{event_type: "session.ended", sequence: 2}
             ] =
               repo().all(
                 from(e in Event, where: e.session_id == ^session_id, order_by: e.sequence)
               )

      assert %Stream{closed_at: %DateTime{}} = repo().get!(Stream, "session:" <> session_id)
      assert {0, nil} = Observations.end_session(session_id)
    end

    test "end-event conflict rolls back ended_at and leaves the session stream open" do
      enable_dual_write()
      attach_event_telemetry()
      session_id = "end-conflict"
      key = "session.ended:" <> session_id

      assert {:ok, _session} = Observations.register_session(session_id, "project")

      assert_receive {:event_telemetry, [:backplane, :memory, :event, :append], _,
                      %{event_type: "session.started"}}

      assert {:ok, _event} =
               Store.append(
                 %{
                   stream_id: "other-end-stream",
                   event_type: "session.ended",
                   idempotency_key: key
                 },
                 telemetry: false
               )

      assert {:error, :idempotency_conflict} = Observations.end_session(session_id)

      assert_receive {:event_telemetry, [:backplane, :memory, :event, :error], _,
                      %{status: :error}}

      refute_receive {:event_telemetry, [:backplane, :memory, :event, :append], _, _}
      assert repo().get!(Session, session_id).ended_at == nil
      assert repo().get!(Stream, "session:" <> session_id).closed_at == nil
    end

    test "first end enqueues one summary while repeat, unknown, and failed ends enqueue none" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        enable_dual_write()
        session_id = "end-summary-once"
        failed_session_id = "end-summary-failed"

        assert {:ok, _session} = Observations.register_session(session_id, "project")
        assert {1, nil} = Observations.end_session(session_id)
        assert {0, nil} = Observations.end_session(session_id)
        assert {0, nil} = Observations.end_session("end-summary-unknown")

        assert {:ok, _session} =
                 Observations.register_session(failed_session_id, "project")

        assert {:ok, _event} =
                 Store.append(
                   %{
                     stream_id: "other-summary-failure-stream",
                     event_type: "session.ended",
                     idempotency_key: "session.ended:" <> failed_session_id
                   },
                   telemetry: false
                 )

        assert {:error, :idempotency_conflict} =
                 Observations.end_session(failed_session_id)

        jobs =
          Oban.Testing.all_enqueued(repo(),
            worker: SummaryWorker,
            args: %{"session_id" => session_id}
          )

        assert length(jobs) == 1

        assert [] =
                 Oban.Testing.all_enqueued(repo(),
                   worker: SummaryWorker,
                   args: %{"session_id" => failed_session_id}
                 )
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # file_history/2
  # ---------------------------------------------------------------------------

  describe "file_history/2" do
    test "returns observations whose files map includes any of the given paths" do
      {:ok, _} = Observations.record("fh-sess-1", "updated lib/foo.ex")
      {:ok, _} = Observations.record("fh-sess-1", "changed apps/bar/mix.exs")
      {:ok, _} = Observations.record("fh-sess-1", "no path here at all")

      results = Observations.file_history(["lib/foo.ex"])
      contents = Enum.map(results, & &1.content)
      assert Enum.any?(contents, &String.contains?(&1, "foo.ex"))
      refute Enum.any?(contents, &(&1 == "no path here at all"))
    end

    test "excludes observations from the given session when exclude_session is set" do
      {:ok, _} = Observations.record("fh-mine", "changed lib/foo.ex")
      {:ok, _} = Observations.record("fh-other", "touched lib/foo.ex too")

      results = Observations.file_history(["lib/foo.ex"], exclude_session: "fh-mine")
      session_ids = Enum.map(results, & &1.session_id)
      refute "fh-mine" in session_ids
      assert "fh-other" in session_ids
    end

    test "respects the limit option" do
      for i <- 1..5 do
        Observations.record("fh-limit-sess", "edited lib/foo.ex version #{i}")
      end

      results = Observations.file_history(["lib/foo.ex"], limit: 2)
      assert length(results) <= 2
    end

    test "breaks created_at ties by descending observation id" do
      created_at = ~U[2026-01-01 00:00:00.000000Z]

      rows =
        for suffix <- [1, 3, 2] do
          %{
            id:
              "00000000-0000-0000-0000-#{String.pad_leading(Integer.to_string(suffix), 12, "0")}",
            session_id: "fh-tie",
            content: "tie #{suffix}",
            files: %{"paths" => ["lib/foo.ex"]},
            created_at: created_at
          }
        end

      {3, nil} = repo().insert_all(Observation, rows)

      assert Enum.map(Observations.file_history(["lib/foo.ex"]), & &1.id) ==
               Enum.map([3, 2, 1], fn suffix ->
                 "00000000-0000-0000-0000-#{String.pad_leading(Integer.to_string(suffix), 12, "0")}"
               end)
    end

    test "returns empty list when no observations match the given paths" do
      assert [] = Observations.file_history(["does/not/exist.ex"])
    end
  end

  defp event_for_observation(%Observation{id: observation_id}) do
    repo().one!(
      from(e in Event,
        where:
          fragment(
            "?->'_backplane'->>'legacy_observation_id' = ?",
            e.payload,
            ^observation_id
          )
      )
    )
  end

  defp enable_events_only do
    :ets.insert(@settings_table, {"memory.pipeline.enabled", true})
    :ets.insert(@settings_table, {"memory.events.enabled", true})
    :ets.insert(@settings_table, {"memory.events.dual_write", false})
  end

  defp disable_all_flags do
    :ets.insert(@settings_table, {"memory.pipeline.enabled", false})
    :ets.insert(@settings_table, {"memory.events.enabled", false})
    :ets.insert(@settings_table, {"memory.events.dual_write", false})
  end

  defp enable_dual_write do
    enable_events_only()
    :ets.insert(@settings_table, {"memory.events.dual_write", true})
  end

  defp attach_event_telemetry do
    handler_id = "observations-event-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        for(
          outcome <- [:append, :duplicate, :error],
          do: [:backplane, :memory, :event, outcome]
        ),
        fn name, measurements, metadata, _config ->
          send(parent, {:event_telemetry, name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
