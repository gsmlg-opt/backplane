defmodule Backplane.Memory.FactExtractionTest do
  use ExUnit.Case, async: true
  alias Backplane.Memory.FactExtraction

  defp bundle do
    partition = %{
      memory_space_id: Ecto.UUID.generate(),
      scope: "private",
      namespace: "private",
      host_id: "host"
    }

    summary =
      Map.merge(partition, %{
        id: Ecto.UUID.generate(),
        session_id: "session",
        input_revision: "current",
        source_complete: true,
        superseded_at: nil
      })

    event =
      Map.merge(partition, %{
        id: Ecto.UUID.generate(),
        session_id: "session",
        stream_id: "stream",
        sequence: 2,
        source_sequence: 2,
        event_type: "conversation.user_message",
        role: "user",
        integration: "hermes",
        payload: %{},
        content: "My preferred label is café. Record: sample-1.",
        privacy: %{}
      })

    {:ok, bundle} = FactExtraction.bundle(summary, partition, [event])
    {bundle, summary, partition, event}
  end

  defp candidate(bundle) do
    [event] = bundle["events"]

    %{
      "statement" => "My preferred label is café.",
      "subject" => %{"kind" => "speaker", "text" => "user", "citation" => 0},
      "property" => %{"text" => "preferred label", "citation" => 0},
      "value" => %{"text" => "café", "citation" => 0},
      "semantic_scope" => %{"kind" => "unspecified"},
      "citations" => [%{"event_id" => event["id"], "quote" => "My preferred label is café."}],
      "correction_of" => []
    }
  end

  defp assessment do
    %{
      "empty_supported" => false,
      "verdicts" => [
        %{
          "index" => 0,
          "subject" => "supported",
          "property_value" => "supported",
          "scope" => "supported",
          "current_correction" => "supported",
          "durable" => "supported",
          "statement_equivalent" => "supported",
          "self_contained" => "supported"
        }
      ]
    }
  end

  test "source units retain Unicode punctuation and closers without splitting qualifiers" do
    {_, summary, partition, event} = bundle()

    text =
      "  For testing: use 3.5 kg, never 2; unless paused. ‘我不使用红色！’\n次は青です。 \"Use green?!\" Remaining context"

    {:ok, result} = FactExtraction.bundle(summary, partition, [%{event | content: text}])
    units = result["assertion_units"]

    assert Enum.map(units, & &1["text"]) == [
             "For testing: use 3.5 kg, never 2; unless paused.",
             "‘我不使用红色！’",
             "次は青です。",
             "\"Use green?!\"",
             "Remaining context"
           ]

    for unit <- units do
      assert unit["text"] ==
               binary_part(text, unit["start_byte"], unit["end_byte"] - unit["start_byte"])

      assert unit["event_id"] == event.id
    end

    {:ok, result} =
      FactExtraction.bundle(summary, partition, [
        %{event | content: "Only for lab:\nuse blue; never orange"}
      ])

    assert [%{"text" => "Only for lab:\nuse blue; never orange"}] = result["assertion_units"]
  end

  test "unit and source byte limits reject whole input instead of omitting coverage" do
    {_, summary, partition, event} = bundle()
    within = Enum.map_join(1..128, " ", &"Assertion #{&1}.")

    assert {:ok, complete} =
             FactExtraction.bundle(summary, partition, [%{event | content: within}])

    assert length(complete["assertion_units"]) == 128
    text = Enum.map_join(1..129, " ", &"Assertion #{&1}.")

    assert {:error, :fact_assertion_units_too_large} =
             FactExtraction.bundle(summary, partition, [%{event | content: text}])

    assert {:error, :fact_assertion_units_too_large} =
             FactExtraction.bundle(summary, partition, [
               %{event | content: String.duplicate("界", 22_000)}
             ])
  end

  test "total assertion bytes are bounded across individually small units" do
    {_, summary, partition, event} = bundle()
    text = Enum.map_join(1..66, " ", fn _ -> String.duplicate("x", 999) <> "." end)

    assert {:error, :fact_assertion_units_too_large} =
             FactExtraction.bundle(summary, partition, [%{event | content: text}])
  end

  test "source-extractive policy rejects paraphrase even with fully positive assessment" do
    {bundle, _, _, _} = bundle()
    original = candidate(bundle)
    assert {:ok, [fact]} = FactExtraction.validate([original], bundle)
    assert fact["extraction_policy"] == "verbatim_source_unit.v1"
    assert {:ok, [_]} = FactExtraction.accept([fact], assessment())

    for text <- [
          "The user's preferred label is café.",
          "My preferred label is café for sample-1.",
          "café"
        ] do
      assert {:error, :invalid_fact_assertion} =
               FactExtraction.validate([%{original | "statement" => text}], bundle)
    end
  end

  test "a complete unit preserves negation, conditions, quantifiers and explicit scope" do
    {_, summary, partition, event} = bundle()
    text = "For laboratory runs, I do not use all red labels unless asked."
    {:ok, bundle} = FactExtraction.bundle(summary, partition, [%{event | content: text}])

    fact = %{
      candidate(bundle)
      | "statement" => text,
        "property" => %{"text" => "labels", "citation" => 0},
        "value" => %{"text" => "red", "citation" => 0},
        "semantic_scope" => %{"kind" => "explicit", "text" => "laboratory runs", "citation" => 0},
        "citations" => [%{"event_id" => event.id, "quote" => text}]
    }

    assert {:ok, [_]} = FactExtraction.validate([fact], bundle)

    for shortened <- [
          "I do not use all red labels unless asked.",
          "For laboratory runs, I use all red labels unless asked.",
          "For laboratory runs, I do not use red labels."
        ] do
      clipped = %{
        fact
        | "statement" => shortened,
          "citations" => [%{"event_id" => event.id, "quote" => shortened}]
      }

      assert {:error, _} = FactExtraction.validate([clipped], bundle)
    end
  end

  test "assertion fields share one original unit and recorded speaker identity" do
    {bundle, _, _, event} = bundle()
    fact = candidate(bundle)

    for {field, replacement} <- [
          {"subject", %{"kind" => "entity", "text" => "sample-1", "citation" => 0}},
          {"subject", %{"kind" => "speaker", "text" => "assistant", "citation" => 0}},
          {"property", %{"text" => "deployment preference", "citation" => 0}},
          {"value", %{"text" => "tea", "citation" => 0}},
          {"semantic_scope", %{"kind" => "explicit", "text" => "sample-1", "citation" => 0}}
        ] do
      assert {:error, _} = FactExtraction.validate([Map.put(fact, field, replacement)], bundle)
    end

    other = %{"event_id" => event.id, "quote" => "Record: sample-1."}

    crossed = %{
      fact
      | "citations" => fact["citations"] ++ [other],
        "value" => %{"text" => "sample-1", "citation" => 1}
    }

    assert {:error, :invalid_fact_assertion} = FactExtraction.validate([crossed], bundle)
    uncertain = put_in(assessment(), ["verdicts", Access.at(0), "self_contained"], "uncertain")
    assert {:ok, facts} = FactExtraction.validate([fact], bundle)
    assert {:error, :fact_semantics_unverified} = FactExtraction.accept(facts, uncertain)
  end

  test "server binds original quotes to exact Unicode byte spans and hashes" do
    {bundle, _, _, event} = bundle()
    assert {:ok, [fact]} = FactExtraction.validate([candidate(bundle)], bundle)

    assert [%{"start_byte" => 0, "end_byte" => ending, "text_sha256" => hash} = citation] =
             fact["citations"]

    assert ending == byte_size("My preferred label is café.")
    assert hash == Base.encode16(:crypto.hash(:sha256, event.content), case: :lower)
    assert :ok = FactExtraction.validate_citation(citation, bundle)

    assert {:error, :invalid_fact_citation} =
             FactExtraction.validate_citation(%{citation | "end_byte" => ending - 2}, bundle)

    assert {:error, :invalid_fact_citation} =
             FactExtraction.validate_citation(%{citation | "text_sha256" => "stale"}, bundle)
  end

  test "truncated canonical content or payload cannot masquerade as complete original evidence" do
    {_bundle, summary, partition, event} = bundle()

    for field <- ["content", "payload"] do
      truncated = %{event | payload: %{"_backplane" => %{field => %{"truncated" => true}}}}

      assert {:error, :fact_sources_incomplete} =
               FactExtraction.bundle(summary, partition, [truncated])
    end
  end

  test "superseded original message revisions cannot supply citations" do
    {_bundle, summary, partition, event} = bundle()

    source = %{
      "installation_id" => "install",
      "profile_id" => "profile",
      "message_uid" => "message",
      "source_revision" => 1
    }

    old = %{event | payload: %{"source" => source}}

    current = %{
      event
      | id: Ecto.UUID.generate(),
        source_sequence: 3,
        sequence: 3,
        payload: %{"source" => %{source | "source_revision" => 2}}
    }

    {:ok, bundle} = FactExtraction.bundle(summary, partition, [old, current])
    assert [new_event] = bundle["events"]
    assert new_event["id"] == current.id
    forged = put_in(candidate(bundle), ["citations", Access.at(0), "event_id"], old.id)
    assert {:error, :invalid_fact_citation} = FactExtraction.validate([forged], bundle)
  end

  test "foreign sources, unknown citations and legacy strings fail closed" do
    {bundle, summary, partition, event} = bundle()

    assert {:error, :fact_source_partition_mismatch} =
             FactExtraction.bundle(summary, partition, [%{event | scope: "foreign"}])

    forged =
      put_in(candidate(bundle), ["citations", Access.at(0), "event_id"], Ecto.UUID.generate())

    assert {:error, :invalid_fact_citation} = FactExtraction.validate([forged], bundle)
    assert {:error, :invalid_fact_candidate} = FactExtraction.validate(["legacy fact"], bundle)
  end

  test "citation references are local to each fact, not event positions or one-based indexes" do
    {bundle, _, _, _} = bundle()
    fact = candidate(bundle)
    assert {:ok, [_]} = FactExtraction.validate([fact], bundle)

    for field <- ~w(subject property value) do
      invalid = put_in(fact, [field, "citation"], 1)
      assert {:error, _} = FactExtraction.validate([invalid], bundle)
    end
  end

  test "recorded assistant roles cannot support a speaker preference" do
    {_, summary, partition, event} = bundle()

    {:ok, bundle} =
      FactExtraction.bundle(summary, partition, [
        %{event | role: "assistant", event_type: "conversation.agent_message"}
      ])

    assert {:error, :invalid_fact_attribution} =
             FactExtraction.validate([candidate(bundle)], bundle)
  end

  test "existing identifier span does not prove semantic scope" do
    {_, summary, partition, event} = bundle()
    text = "My preferred label is café (record sample-1)."
    {:ok, bundle} = FactExtraction.bundle(summary, partition, [%{event | content: text}])

    fact =
      candidate(bundle)
      |> Map.put("statement", text)
      |> Map.put("semantic_scope", %{"kind" => "explicit", "text" => "sample-1", "citation" => 0})
      |> put_in(["citations", Access.at(0), "quote"], text)

    assert {:ok, [linked]} = FactExtraction.validate([fact], bundle)
    rejected = put_in(assessment(), ["verdicts", Access.at(0), "scope"], "unsupported")
    assert {:error, :fact_semantics_unverified} = FactExtraction.accept([linked], rejected)

    assert {:error, :fact_semantics_unverified} =
             FactExtraction.accept([linked], %{"verdicts" => []})

    assert {:error, :fact_semantics_unverified} = FactExtraction.accept([], rejected)
  end

  test "only complete supported assessments publish and empty extraction requires its own verdict" do
    {bundle, _, _, _} = bundle()
    {:ok, facts} = FactExtraction.validate([candidate(bundle)], bundle)
    assert {:ok, ^facts} = FactExtraction.accept(facts, assessment())
    assert {:ok, []} = FactExtraction.accept([], %{"empty_supported" => true, "verdicts" => []})

    uncertain =
      put_in(assessment(), ["verdicts", Access.at(0), "current_correction"], "uncertain")

    assert {:error, :fact_semantics_unverified} = FactExtraction.accept(facts, uncertain)
  end

  test "corrections require older same-stream evidence and a direct user correction" do
    {_, summary, partition, event} = bundle()

    older = %{
      event
      | id: Ecto.UUID.generate(),
        sequence: 1,
        source_sequence: 1,
        content: "I guessed another label.",
        role: "assistant",
        event_type: "conversation.agent_message"
    }

    {:ok, bundle} = FactExtraction.bundle(summary, partition, [event, older])
    fact = candidate(%{bundle | "events" => [List.last(bundle["events"])]})
    correction = %{"event_id" => older.id, "quote" => older.content, "correction_citation" => 0}

    assert {:ok, [_]} =
             FactExtraction.validate([%{fact | "correction_of" => [correction]}], bundle)

    future = %{older | source_sequence: 3, sequence: 3}
    {:ok, future_bundle} = FactExtraction.bundle(summary, partition, [event, future])

    assert {:error, :invalid_fact_correction} =
             FactExtraction.validate([%{fact | "correction_of" => [correction]}], future_bundle)
  end
end
