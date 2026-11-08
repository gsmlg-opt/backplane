defmodule Backplane.Memory.Projections.SourceTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Events.Store
  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Projections.Source

  import Backplane.Memory.IngestFixtures

  test "source excludes legacy rows, isolates collision-prone host/session pairs, and orders subjects" do
    prefix = "source-#{System.unique_integer([:positive])}"
    first_host = "#{prefix}a"
    first_session = "bc"
    second_host = "#{prefix}ab"
    second_session = "c"

    assert {:ok, _legacy} =
             Store.append(%{
               stream_id: "legacy-#{Ecto.UUID.generate()}",
               event_type: "conversation.user_message",
               host_id: "#{prefix}-legacy",
               session_id: "#{prefix}-legacy",
               content: "not captured"
             })

    captured = [
      captured_event(second_host, second_session, 2, "agent.tool.completed"),
      captured_event(first_host, first_session, 1, "agent.prompt.submitted"),
      captured_event(second_host, second_session, 1, "agent.prompt.submitted"),
      captured_event(second_host, second_session, 2, "agent.tool.failed")
    ]

    Enum.each(captured, &ingest!/1)

    assert {:ok, subjects} = Source.subjects()

    expected_subjects = [
      %{
        "host_id" => first_host,
        "session_id" => first_session,
        "subject_id" => Source.subject_id!(first_host, first_session)
      },
      %{
        "host_id" => second_host,
        "session_id" => second_session,
        "subject_id" => Source.subject_id!(second_host, second_session)
      }
    ]

    target_hosts = MapSet.new([first_host, second_host])

    assert Enum.filter(subjects, &MapSet.member?(target_hosts, &1["host_id"])) ==
             expected_subjects

    refute Source.subject_id!(first_host, first_session) ==
             Source.subject_id!(second_host, second_session)

    assert {:ok, events} = Source.events(second_host, second_session)

    assert Enum.map(events, &{&1.source_sequence, &1.event_type, &1.id}) ==
             captured
             |> Enum.filter(
               &(&1["host_id"] == second_host and &1["session_id"] == second_session)
             )
             |> Enum.map(&{&1["sequence"], &1["event_type"], &1["event_id"]})
             |> Enum.sort()

    assert {:ok, [_only_other_subject]} = Source.events(first_host, first_session)

    assert {:ok, reduced} =
             Source.reduce_subjects([], fn subject, acc -> {:cont, [subject | acc]} end,
               page_size: 1
             )

    assert Enum.reverse(reduced) == subjects
  end

  test "source validates explicit captured subject identifiers" do
    for invalid <- [nil, "", "   ", 42] do
      assert {:error, :invalid_host_id} = Source.events(invalid, "session")
      assert {:error, :invalid_session_id} = Source.events("host", invalid)
    end

    assert {:error, :invalid_host_id} = Source.subject_id("", "session")
    assert {:error, :invalid_session_id} = Source.subject_id("host", "")
  end

  defp captured_event(host_id, session_id, sequence, event_type) do
    valid_event(%{
      "event_id" => Ecto.UUID.generate(),
      "host_id" => host_id,
      "session_id" => session_id,
      "sequence" => sequence,
      "event_type" => event_type,
      "idempotency_key" => "#{host_id}:#{session_id}:#{sequence}:#{event_type}"
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
end
