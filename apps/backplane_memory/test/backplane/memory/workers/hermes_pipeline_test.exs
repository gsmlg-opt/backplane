defmodule Backplane.Memory.Workers.HermesPipelineTest do
  use Backplane.Memory.DataCase, async: false
  import Backplane.Memory.IngestFixtures
  alias Backplane.Memory.{Ingest, Memories}
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Projections.{ProjectedSession, ReadModels, Rebuild, Source}
  alias Backplane.Memory.Summaries.{SourceEvent, Summary}
  alias Backplane.Memory.Workers.{EpisodicWorker, SummaryWorker}

  defmodule ExtractionFixture do
    def extract_facts(content) do
      send(self(), {:hermes_extraction_input, content})
      {:ok, ["Current project language is Elixir"]}
    end
  end

  setup do
    keys =
      ~w(memory.pipeline.enabled memory.fact_extraction_v2.enabled memory.session_summary_v2.enabled memory.llm_model)

    settings = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})
    previous_llm = Application.get_env(:backplane_memory, :llm_module)
    Enum.each(keys, &:ets.insert(:backplane_settings, {&1, true}))
    :ets.insert(:backplane_settings, {"memory.llm_model", "controlled-extraction-fixture"})
    Application.put_env(:backplane_memory, :llm_module, ExtractionFixture)

    on_exit(fn ->
      Enum.each(settings, fn {key, entries} ->
        :ets.delete(:backplane_settings, key)
        Enum.each(entries, &:ets.insert(:backplane_settings, &1))
      end)

      if previous_llm,
        do: Application.put_env(:backplane_memory, :llm_module, previous_llm),
        else: Application.delete_env(:backplane_memory, :llm_module)
    end)

    :ok
  end

  test "Hermes canonical messages keep real identities and project only latest revisions into extraction" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      host = "hermes-pipeline-host"
      session = "real-hermes-session"
      installation = Ecto.UUID.generate()
      auth = ingest_auth_context(host)

      events = [
        capture(host, session, installation, 1, "agent.session.started", %{}),
        capture(host, session, installation, 2, "conversation.user_message", %{
          "message_uid" => "actual-uid",
          "role" => "user",
          "source_revision" => 1,
          "content" => "Superseded language is Ruby"
        }),
        capture(host, session, installation, 3, "conversation.user_message", %{
          "message_uid" => "actual-uid",
          "role" => "user",
          "source_revision" => 2,
          "content" => "Current project language is Elixir"
        }),
        capture(host, session, installation, 4, "conversation.agent_message", %{
          "message_uid" => "other-actual-uid",
          "role" => "assistant",
          "source_revision" => 1,
          "content" => "Acknowledged current project language"
        }),
        capture(host, session, installation, 5, "agent.session.ended", %{})
      ]

      assert {:ok, %{"results" => results}} =
               Ingest.ingest_batch(auth, %{
                 "batch_id" => Ecto.UUID.generate(),
                 "host_id" => host,
                 "events" => events
               })

      assert Enum.all?(results, &(&1["status"] == "accepted"))
      assert repo().aggregate(Event, :count) == 5
      historical = repo().get!(Event, Enum.at(events, 1)["event_id"])
      assert historical.content == "Superseded language is Ruby"
      assert historical.role == "user"
      assert historical.parent_session_id == "real-parent-session"
      assert get_in(historical.payload, ["source", "message_uid"]) == "actual-uid"
      assert get_in(historical.payload, ["source", "author"]) == %{"name" => "actual speaker"}

      assert {:ok, projection} = Rebuild.session(host, session)
      assert {:ok, input} = ReadModels.summary_input(host, session)
      contents = Enum.map(input.observations, & &1.content)
      assert "Current project language is Elixir" in contents
      refute "Superseded language is Ruby" in contents

      projected = repo().get!(ProjectedSession, Source.subject_id!(host, session))

      assert :ok =
               SummaryWorker.perform(%Styx.Job{
                 args: %{
                   "host_id" => host,
                   "session_id" => session,
                   "memory_space_id" => projected.memory_space_id,
                   "client_id" => projected.client_id,
                   "source_client_id" => projected.source_client_id,
                   "scope" => projected.scope,
                   "namespace" => projected.namespace,
                   "processing_version" => "summary-v1",
                   "input_revision" => projection.input_revision
                 }
               })

      summary =
        repo().get_by!(Summary,
          subject_id: projected.subject_id,
          processing_version: "summary-v1"
        )

      assert summary.content =~ "Current project language is Elixir"
      refute summary.content =~ "Superseded language is Ruby"

      assert repo().aggregate(
               from(link in SourceEvent, where: link.summary_id == ^summary.id),
               :count
             ) == 5

      assert :ok = EpisodicWorker.perform(%Styx.Job{args: %{"summary_id" => summary.id}})
      assert_received {:hermes_extraction_input, extraction_input}
      assert extraction_input == summary.content

      memory =
        repo().get_by!(Backplane.Memory.Memories.Memory,
          content: "Current project language is Elixir"
        )

      evidence = Memories.list_evidence(memory.id)
      assert Enum.any?(evidence, &(&1.source_type == "summary" and &1.source_id == summary.id))

      assert Enum.any?(
               evidence,
               &(&1.source_type == "event" and &1.source_id == Enum.at(events, 2)["event_id"])
             )

      assert Backplane.Memory.CurrentContext.metadata(memory)["trust"] == "candidate_inference"
    end)
  end

  defp capture(host, session, installation, sequence, event_type, message) do
    source =
      Map.merge(
        %{
          "protocol" => "hermes_capture.v1",
          "installation_id" => installation,
          "profile_id" => "primary",
          "session_id" => session,
          "source_sequence" => sequence,
          "author" => %{"name" => "actual speaker"}
        },
        message
      )

    payload = %{"source" => source}

    valid_event(%{
      "host_id" => host,
      "integration" => "hermes",
      "client_id" => "hermes",
      "agent_id" => "Rikka",
      "session_id" => session,
      "parent_session_id" => "real-parent-session",
      "sequence" => sequence,
      "event_type" => event_type,
      "idempotency_key" => "hermes:#{installation}:#{sequence}",
      "payload" => payload,
      "payload_hash" => Backplane.Memory.Ingest.EventValidator.payload_hash(payload)
    })
  end
end
