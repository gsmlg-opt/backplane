defmodule Backplane.Memory.Workers.HermesPipelineTest do
  use Backplane.Memory.DataCase, async: false
  import Backplane.Memory.IngestFixtures
  alias Backplane.Memory.{Ingest, Memories}
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Projections.{ProjectedSession, ReadModels, Rebuild, Source}
  alias Backplane.Memory.Summaries.{SourceEvent, Summary}
  alias Backplane.Memory.Workers.{EpisodicWorker, SummaryWorker}

  defmodule ExtractionFixture do
    def extract_fact_candidates(content, bundle, _model) do
      send(self(), {:hermes_extraction_input, content})

      {:ok,
       Backplane.Memory.FactExtractionFixtures.proposals(
         ["Current project language is Elixir"],
         bundle
       )}
    end

    def assess_fact_candidates(_bundle, facts, _model),
      do: {:ok, Backplane.Memory.FactExtractionFixtures.assessment(facts)}
  end

  setup do
    keys =
      ~w(memory.pipeline.enabled memory.fact_extraction.enabled memory.session_summary.enabled memory.llm_model)

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

  for integration <- ~w(hermes openclaw) do
    @integration integration
    test "#{integration} canonical messages keep real identities and project only latest revisions into extraction" do
      integration = @integration

      Styx.Testing.with_testing_mode(:manual, fn ->
        host = "#{integration}-pipeline-host"
        session = "real-#{integration}-session"
        installation = Ecto.UUID.generate()
        auth = ingest_auth_context(host)

        events = [
          capture(integration, host, session, installation, 1, "agent.session.started", %{}),
          capture(integration, host, session, installation, 2, "conversation.user_message", %{
            "message_uid" => "actual-uid",
            "role" => "user",
            "source_revision" => 1,
            "content" => "Superseded language is Ruby"
          }),
          capture(integration, host, session, installation, 3, "conversation.user_message", %{
            "message_uid" => "actual-uid",
            "role" => "user",
            "source_revision" => 2,
            "content" => "Current project language is Elixir"
          }),
          capture(integration, host, session, installation, 4, "conversation.agent_message", %{
            "message_uid" => "other-actual-uid",
            "role" => "assistant",
            "source_revision" => 1,
            "content" => "Acknowledged current project language"
          }),
          capture(integration, host, session, installation, 5, "agent.session.ended", %{})
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

        assert Enum.any?(evidence, fn item ->
                 item.source_type == "request" and item.evidence_kind == "derives" and
                   item.support_score == 0.0
               end)

        assert {:ok, verification} =
                 Memories.verify(memory.id, Map.from_struct(projected))

        corrected_event_id = Enum.at(events, 2)["event_id"]
        assert Enum.any?(verification.summaries, &(&1.id == summary.id))

        assert Enum.any?(verification.summary_event_links, fn link ->
                 link.summary_id == summary.id and link.event_id == corrected_event_id
               end)

        assert Enum.any?(verification.source_events, &(&1.id == corrected_event_id))
        corrected_event = repo().get!(Event, corrected_event_id)
        assert corrected_event.role == "user"
        assert corrected_event.content == "Current project language is Elixir"

        assert Backplane.Memory.CurrentContext.metadata(memory)["trust"] == "candidate_inference"
      end)
    end
  end

  defp capture(integration, host, session, installation, sequence, event_type, message) do
    event_id = Ecto.UUID.generate()

    source =
      Map.merge(
        %{
          "protocol" => integration <> "_capture.v1",
          "installation_id" => installation,
          "profile_id" => "primary",
          "session_id" => session,
          "source_sequence" => sequence,
          "author" => %{"name" => "actual speaker"}
        },
        message
      )

    hook =
      case event_type do
        "agent.session.started" -> "session-start"
        "agent.session.ended" -> "session-end"
        _ -> "message"
      end

    source =
      if integration == "openclaw" do
        source =
          Map.merge(source, %{
            "event_id" => event_id,
            "agent_id" => "Rikka",
            "run_id" => "actual-run",
            "occurrence_id" => Map.get(message, "message_uid", "lifecycle:#{sequence}"),
            "occurred_at" => "2026-10-26T01:00:00Z",
            "captured_at" => "2026-10-26T01:00:00Z",
            "binding_fingerprint" => String.duplicate("a", 64)
          })

        source =
          if hook == "message" do
            content = source["content"]

            Map.put(source, "completeness", %{
              "truncated" => false,
              "coverage" => "full",
              "original_length" => length(String.codepoints(content)),
              "original_sha256" => Base.encode16(:crypto.hash(:sha256, content), case: :lower)
            })
          else
            Map.delete(source, "author")
          end

        assert {:ok, ^event_type} = Backplane.OpenClawCaptureContract.validate(hook, source)
        source
      else
        source
      end

    payload = %{"hook" => hook, "source" => source}

    valid_event(%{
      "event_id" => event_id,
      "host_id" => host,
      "integration" => integration,
      "client_id" => integration,
      "agent_id" => "Rikka",
      "session_id" => session,
      "parent_session_id" => "real-parent-session",
      "sequence" => sequence,
      "event_type" => event_type,
      "idempotency_key" => "#{integration}:#{installation}:#{sequence}",
      "payload" => payload,
      "payload_hash" => Backplane.Memory.Ingest.EventValidator.payload_hash(payload)
    })
  end
end
