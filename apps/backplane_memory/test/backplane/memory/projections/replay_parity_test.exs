defmodule Backplane.Memory.Projections.ReplayParityTest do
  use Backplane.Memory.DataCase, async: false

  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Projections.{Snapshot, Source, State}

  setup do
    previous_enabled = Application.get_env(:backplane_memory, :projection_repair_enabled)
    Application.put_env(:backplane_memory, :projection_repair_enabled, true)

    on_exit(fn -> restore_env(:projection_repair_enabled, previous_enabled) end)

    :ok
  end

  test "shuffled canonical event replay converges to the ordered session and timeline" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      ordered_host = unique("ordered-host")
      ordered_session = unique("ordered-session")
      shuffled_host = unique("shuffled-host")
      shuffled_session = unique("shuffled-session")

      ordered_events = captured_events(ordered_host, ordered_session)
      shuffled_events = captured_events(shuffled_host, shuffled_session)

      ingest_all!(ordered_events)
      ordered_raw_before = raw_events(ordered_host, ordered_session)

      assert %{success: 6, failure: 0} = Oban.drain_queue(queue: :memory)
      assert raw_events(ordered_host, ordered_session) == ordered_raw_before

      shuffled_prefix = events_at(shuffled_events, [1, 4, 6])
      ingest_all!(shuffled_prefix)
      shuffled_prefix_raw_before = raw_events(shuffled_host, shuffled_session)

      # Three repairs plus the expired-gap summary.
      assert %{success: 4, failure: 0} = Oban.drain_queue(queue: :memory)
      assert raw_events(shuffled_host, shuffled_session) == shuffled_prefix_raw_before

      shuffled_subject = Source.subject_id!(shuffled_host, shuffled_session)

      assert %{
               "session" => %{
                 read_model: %{
                   "gaps" => [%{"from" => 2, "to" => 3}, %{"from" => 5, "to" => 5}]
                 }
               }
             } = snapshots(shuffled_subject)

      ingest_all!(events_at(shuffled_events, [2, 5, 3]))
      shuffled_raw_before = raw_events(shuffled_host, shuffled_session)

      # Three repairs, the superseding complete summary, and the prior episodic successor.
      assert %{success: 5, failure: 0} = Oban.drain_queue(queue: :memory)
      assert raw_events(shuffled_host, shuffled_session) == shuffled_raw_before

      ordered_subject = Source.subject_id!(ordered_host, ordered_session)
      ordered_snapshots = snapshots(ordered_subject)
      shuffled_snapshots = snapshots(shuffled_subject)

      assert_complete_without_gaps(ordered_subject, ordered_snapshots)
      assert_complete_without_gaps(shuffled_subject, shuffled_snapshots)

      ordered_timeline = ordered_snapshots["observations"].read_model
      shuffled_timeline = shuffled_snapshots["observations"].read_model

      assert Enum.map(ordered_timeline["observations"], & &1["source_sequence"]) ==
               [1, 2, 3, 4, 5, 6]

      assert Enum.map(shuffled_timeline["observations"], & &1["source_sequence"]) ==
               [1, 2, 3, 4, 5, 6]

      assert normalize_session(
               ordered_snapshots["session"].read_model,
               event_id_map(ordered_events)
             ) ==
               normalize_session(
                 shuffled_snapshots["session"].read_model,
                 event_id_map(shuffled_events)
               )

      assert normalize_timeline(ordered_timeline, event_id_map(ordered_events)) ==
               normalize_timeline(shuffled_timeline, event_id_map(shuffled_events))
    end)
  end

  defp captured_events(host_id, session_id) do
    [
      semantic_event(1, "agent.session.started", "2026-08-11T01:00:00.000Z", %{
        "source" => %{"reason" => "interactive"}
      }),
      semantic_event(2, "agent.prompt.submitted", "2026-08-11T01:01:00.000Z", %{
        "source" => %{"prompt" => "Implement deterministic replay parity"}
      }),
      semantic_event(3, "agent.tool.completed", "2026-08-11T01:02:00.000Z", %{
        "source" => %{
          "tool_name" => "Read",
          "tool_input" => %{"file_path" => "/workspace/lib/replay.ex"},
          "tool_response" => %{"bytes" => 128, "status" => "ok"}
        }
      }),
      semantic_event(4, "agent.tool.failed", "2026-08-11T01:03:00.000Z", %{
        "source" => %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "mix test"},
          "error" => "exit status 1",
          "files" => ["test/replay_test.exs"]
        }
      }),
      semantic_event(5, "git.commit.created", "2026-08-11T01:04:00.000Z", %{
        "source" => %{
          "commit_hash" => "abc123def456",
          "commit_message" => "test(memory): prove replay parity",
          "files" => ["test/replay_test.exs", "lib/replay.ex"]
        }
      }),
      semantic_event(6, "agent.session.ended", "2026-08-11T01:05:00.000Z", %{
        "source" => %{"reason" => "completed"}
      })
    ]
    |> Enum.map(fn event ->
      sequence = event["sequence"]

      Map.merge(event, %{
        "event_id" => Ecto.UUID.generate(),
        "host_id" => host_id,
        "session_id" => session_id,
        "idempotency_key" => "#{host_id}:#{session_id}:#{sequence}"
      })
    end)
  end

  defp semantic_event(sequence, event_type, occurred_at, payload) do
    valid_event(%{
      "sequence" => sequence,
      "event_type" => event_type,
      "occurred_at" => occurred_at,
      "captured_at" => captured_at(sequence),
      "payload" => payload
    })
  end

  defp captured_at(sequence), do: "2026-08-11T01:0#{sequence}:30.000Z"

  defp events_at(events, sequences) do
    Enum.map(sequences, fn sequence ->
      Enum.find(events, &(&1["sequence"] == sequence))
    end)
  end

  defp ingest_all!(events), do: Enum.each(events, &ingest!/1)

  defp ingest!(event) do
    auth = ingest_auth_context(event["host_id"], %{partition: %{scope: event["scope"]}})

    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(auth, %{
               "batch_id" => Ecto.UUID.generate(),
               "host_id" => event["host_id"],
               "events" => [event]
             })
  end

  defp assert_complete_without_gaps(subject_id, snapshots) do
    states = states(subject_id)
    projectors = Enum.map(states, & &1.projector)

    assert projectors in [
             ~w(activity observations replay session summary),
             ~w(activity crystal observations replay session summary)
           ]

    assert Enum.all?(states, fn
             %{projector: "crystal", status: "enqueued", last_error: nil} ->
               true

             %{projector: "summary", status: status, last_error: nil}
             when status in ["pending", "complete"] ->
               true

             %{status: "complete", last_error: nil} ->
               true

             _state ->
               false
           end)

    assert snapshots["session"].read_model["gaps"] == []
    assert snapshots["session"].read_model["status"] == "completed"
  end

  defp normalize_session(session, event_ids) do
    session
    |> Map.put("host_id", "host-id")
    |> Map.put("client_id", "client-id")
    |> Map.put("session_id", "session-id")
    |> Map.put("subject_id", "subject-id")
    |> Map.update!("source_event_ids", &Enum.map(&1, fn id -> Map.fetch!(event_ids, id) end))
  end

  defp normalize_timeline(timeline, event_ids) do
    timeline
    |> Map.put("host_id", "host-id")
    |> Map.put("client_id", "client-id")
    |> Map.put("session_id", "session-id")
    |> Map.update!("observations", fn observations ->
      Enum.map(observations, fn observation ->
        Map.update!(observation, "event_id", &Map.fetch!(event_ids, &1))
      end)
    end)
  end

  defp event_id_map(events) do
    Map.new(events, fn event -> {event["event_id"], "event-#{event["sequence"]}"} end)
  end

  defp raw_events(host_id, session_id) do
    repo().all(
      from(event in Event,
        where: event.host_id == ^host_id and event.session_id == ^session_id,
        order_by: [asc: event.source_sequence, asc: event.id]
      )
    )
  end

  defp snapshots(subject_id) do
    repo().all(from(snapshot in Snapshot, where: snapshot.subject_id == ^subject_id))
    |> Map.new(&{&1.projector, &1})
  end

  defp states(subject_id) do
    repo().all(
      from(state in State,
        where: state.subject_id == ^subject_id,
        order_by: [asc: state.projector]
      )
    )
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp restore_env(key, nil), do: Application.delete_env(:backplane_memory, key)
  defp restore_env(key, value), do: Application.put_env(:backplane_memory, key, value)
end
