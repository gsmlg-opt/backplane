defmodule Backplane.Memory.FactExtraction do
  @moduledoc "Source-linked fact candidates: deterministic provenance checks and explicit model assessment."

  alias Backplane.Memory.Projections.EventOrder

  @dimensions ~w(subject property_value scope current_correction durable statement_equivalent self_contained)
  @max_assertion_units 128
  @max_assertion_bytes 65_536
  @unit_boundary ~r/[.!?。！？]+["'”’»」』）)\]}]*(?=\s|\z)/u
  @partition_fields [:memory_space_id, :host_id, :scope, :namespace]

  def bundle(summary, partition, events) when is_list(events) do
    cond do
      not Enum.all?(@partition_fields, &(Map.get(summary, &1) == Map.get(partition, &1))) ->
        {:error, :fact_source_partition_mismatch}

      Enum.any?(events, fn event ->
        event.session_id != summary.session_id or
            Enum.any?(@partition_fields, &(Map.get(event, &1) != Map.get(partition, &1)))
      end) ->
        {:error, :fact_source_partition_mismatch}

      summary.source_complete != true or not is_nil(summary.superseded_at) ->
        {:error, :fact_sources_incomplete}

      events == [] or Enum.any?(events, &truncated?/1) ->
        {:error, :fact_sources_incomplete}

      true ->
        records = events |> EventOrder.current_inputs() |> Enum.map(&source_record/1)

        with {:ok, units} <- assertion_units(records) do
          bundle = %{
            "summary_id" => summary.id,
            "input_revision" => summary.input_revision,
            "events" => records,
            "assertion_units" => units
          }

          if byte_size(Jason.encode!(bundle)) <= 65_536,
            do: {:ok, bundle},
            else: {:error, :fact_sources_too_large}
        end
    end
  end

  defp assertion_units(records) do
    units =
      records
      |> Enum.filter(&(user_assertion?(&1) or &1["role"] == "tool"))
      |> Enum.flat_map(&event_units/1)

    if length(units) <= @max_assertion_units and
         Enum.all?(units, &(byte_size(&1["text"]) <= 2_000)) and
         Enum.sum(Enum.map(units, &byte_size(&1["text"]))) <= @max_assertion_bytes,
       do: {:ok, Enum.with_index(units, &Map.put(&1, "unit_index", &2))},
       else: {:error, :fact_assertion_units_too_large}
  end

  defp event_units(event) do
    text = event["text"]

    ends =
      Regex.scan(@unit_boundary, text, return: :index)
      |> Enum.map(fn [{start, length}] -> start + length end)
      |> Kernel.++([byte_size(text)])
      |> Enum.uniq()

    {units, _cursor} =
      Enum.map_reduce(ends, 0, fn ending, cursor ->
        raw = binary_part(text, cursor, ending - cursor)
        leading = String.trim_leading(raw)
        unit = String.trim_trailing(leading)
        start = cursor + byte_size(raw) - byte_size(leading)

        {%{
           "event_id" => event["id"],
           "text" => unit,
           "start_byte" => start,
           "end_byte" => start + byte_size(unit)
         }, ending}
      end)

    Enum.reject(units, &(&1["text"] == ""))
  end

  def digest(bundle) do
    {:ok, encoded} = Backplane.Memory.CanonicalJSON.encode(bundle)
    hash(encoded)
  end

  def validate(candidates, bundle) when is_list(candidates) and length(candidates) <= 32 do
    candidates
    |> Enum.reduce_while({:ok, []}, fn candidate, {:ok, facts} ->
      case validate_candidate(candidate, bundle) do
        {:ok, fact} -> {:cont, {:ok, [fact | facts]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, facts} -> {:ok, facts |> Enum.uniq() |> Enum.sort_by(& &1["statement"])}
      error -> error
    end
  end

  def validate(_candidates, _bundle), do: {:error, :invalid_fact_candidate}

  def accept([], %{"empty_supported" => true, "verdicts" => []}), do: {:ok, []}

  def accept([_ | _] = facts, %{"verdicts" => verdicts}) when is_list(verdicts) do
    expected = Enum.to_list(0..(length(facts) - 1))

    valid? =
      Enum.all?(verdicts, fn verdict ->
        is_map(verdict) and is_integer(verdict["index"]) and
          Enum.all?(@dimensions, &(verdict[&1] == "supported"))
      end)

    if valid? and Enum.sort(Enum.map(verdicts, & &1["index"])) == expected,
      do: {:ok, facts},
      else: {:error, :fact_semantics_unverified}
  end

  def accept(_facts, _assessment), do: {:error, :fact_semantics_unverified}

  def validate_citation(citation, bundle) when is_map(citation) do
    event = find_event(bundle, citation["event_id"])
    start = citation["start_byte"]
    ending = citation["end_byte"]

    valid? =
      is_map(event) and is_integer(start) and is_integer(ending) and start >= 0 and
        ending > start and ending <= byte_size(event["text"]) and
        citation["text_sha256"] == event["text_sha256"] and
        citation["source_revision"] == event["source_revision"] and
        String.valid?(binary_part(event["text"], 0, start)) and
        String.valid?(binary_part(event["text"], start, ending - start)) and
        binary_part(event["text"], start, ending - start) == citation["quote"]

    if valid?, do: :ok, else: {:error, :invalid_fact_citation}
  end

  def validate_citation(_citation, _bundle), do: {:error, :invalid_fact_citation}

  defp validate_candidate(candidate, bundle) when is_map(candidate) do
    with true <- text?(candidate["statement"], 2_000),
         citations when is_list(citations) and length(citations) in 1..16 <-
           candidate["citations"],
         {:ok, bound} <- bind_citations(citations, bundle),
         :ok <- attribution(candidate["subject"], bound, bundle),
         true <- field?(candidate["property"], bound),
         true <- field?(candidate["value"], bound),
         true <- scope?(candidate["semantic_scope"], bound),
         :ok <- assertion(candidate, bound, bundle),
         {:ok, corrections} <- corrections(candidate["correction_of"], bound, bundle) do
      {:ok,
       Map.take(candidate, ~w(statement subject property value semantic_scope))
       |> Map.merge(%{
         "version" => "source_fact.v1",
         "citations" => bound,
         "correction_of" => corrections,
         "summary_id" => bundle["summary_id"],
         "input_revision" => bundle["input_revision"],
         "assessment_policy" => "same_model_entailment.v1",
         "extraction_policy" => "verbatim_source_unit.v1"
       })}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_fact_candidate}
    end
  end

  defp validate_candidate(_candidate, _bundle), do: {:error, :invalid_fact_candidate}

  defp bind_citations(citations, bundle) do
    Enum.reduce_while(citations, {:ok, []}, fn citation, {:ok, bound} ->
      case bind_citation(citation, bundle) do
        {:ok, result} -> {:cont, {:ok, bound ++ [result]}}
        error -> {:halt, error}
      end
    end)
  end

  defp bind_citation(%{"event_id" => id, "quote" => quote} = citation, bundle) do
    with true <- text?(quote, 8_192),
         %{} = event <- find_event(bundle, id),
         [{start, length}] <- :binary.matches(event["text"], quote) do
      bound = %{
        "event_id" => id,
        "quote" => quote,
        "start_byte" => start,
        "end_byte" => start + length,
        "text_sha256" => event["text_sha256"],
        "source_revision" => event["source_revision"]
      }

      # Supplied coordinates/hashes must agree; never silently repair forged or stale citations.
      if Enum.all?(bound, fn {key, value} ->
           not Map.has_key?(citation, key) or citation[key] == value
         end) and
           validate_citation(bound, bundle) == :ok,
         do: {:ok, bound},
         else: {:error, :invalid_fact_citation}
    else
      _ -> {:error, :invalid_fact_citation}
    end
  end

  defp bind_citation(_citation, _bundle), do: {:error, :invalid_fact_citation}

  defp attribution(%{"kind" => kind} = subject, citations, bundle)
       when kind in ~w(speaker entity) do
    if field?(subject, citations) do
      event =
        citations |> Enum.at(subject["citation"]) |> then(&find_event(bundle, &1["event_id"]))

      if (kind == "speaker" and user_assertion?(event)) or
           (kind == "entity" and (user_assertion?(event) or event["role"] == "tool")),
         do: :ok,
         else: {:error, :invalid_fact_attribution}
    else
      {:error, :invalid_fact_attribution}
    end
  end

  defp attribution(_subject, _citations, _bundle), do: {:error, :invalid_fact_attribution}

  defp assertion(candidate, citations, bundle) do
    subject = candidate["subject"]
    index = subject["citation"]
    citation = Enum.at(citations, index)
    event = find_event(bundle, citation["event_id"])
    statement = candidate["statement"]

    unit? =
      Enum.any?(bundle["assertion_units"] || [], fn unit ->
        unit["event_id"] == citation["event_id"] and unit["text"] == statement and
          unit["start_byte"] == citation["start_byte"] and
          unit["end_byte"] == citation["end_byte"]
      end)

    fields = [candidate["property"], candidate["value"]]
    fields = if subject["kind"] == "entity", do: [subject | fields], else: fields
    scope = candidate["semantic_scope"]
    fields = if scope["kind"] == "explicit", do: [scope | fields], else: fields

    fields? =
      Enum.all?(fields, fn field ->
        field["citation"] == index and String.contains?(statement, field["text"])
      end)

    speaker? = subject["kind"] != "speaker" or subject["text"] == event["role"]

    if unit? and fields? and speaker? and citation["quote"] == statement,
      do: :ok,
      else: {:error, :invalid_fact_assertion}
  end

  defp field?(%{"text" => text, "citation" => index}, citations),
    do: text?(text, 1_000) and is_integer(index) and index >= 0 and index < length(citations)

  defp field?(_field, _citations), do: false
  defp scope?(%{"kind" => "unspecified"} = scope, _citations), do: map_size(scope) == 1
  defp scope?(%{"kind" => "explicit"} = scope, citations), do: field?(scope, citations)
  defp scope?(_scope, _citations), do: false

  defp corrections(values, citations, bundle) when is_list(values) and length(values) <= 16 do
    Enum.reduce_while(values, {:ok, []}, fn correction, {:ok, accepted} ->
      with %{"correction_citation" => index} <- correction,
           true <- is_integer(index) and index >= 0 and index < length(citations),
           {:ok, earlier} <- bind_citation(correction, bundle),
           old = find_event(bundle, earlier["event_id"]),
           current = find_event(bundle, Enum.at(citations, index)["event_id"]),
           true <- user_assertion?(current) and current["stream_id"] == old["stream_id"],
           true <- is_integer(old["sequence"]) and is_integer(current["sequence"]),
           true <- old["sequence"] < current["sequence"] do
        {:cont, {:ok, accepted ++ [Map.put(earlier, "correction_citation", index)]}}
      else
        _ -> {:halt, {:error, :invalid_fact_correction}}
      end
    end)
  end

  defp corrections(_values, _citations, _bundle), do: {:error, :invalid_fact_correction}
  defp find_event(bundle, id), do: Enum.find(bundle["events"], &(&1["id"] == id))

  defp text?(value, limit),
    do:
      is_binary(value) and String.valid?(value) and String.trim(value) != "" and
        byte_size(value) <= limit

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp truncated?(event) do
    source = event.payload["source"] || %{}

    source["truncated"] == true or source["content_truncated"] == true or
      (event.privacy || %{})["truncated"] == true or
      get_in(event.payload, ["_backplane", "content", "truncated"]) == true or
      get_in(event.payload, ["_backplane", "payload", "truncated"]) == true
  end

  defp source_record(event) do
    source = event.payload["source"] || %{}

    text =
      Enum.find(
        [
          event.content,
          source["message"],
          source["prompt"],
          event.payload["message"],
          event.payload["content"]
        ],
        "",
        &is_binary/1
      )

    role =
      event.role ||
        case event.event_type do
          type when type in ["conversation.user_message", "agent.prompt.submitted"] -> "user"
          "conversation.agent_message" -> "assistant"
          "agent.tool.completed" -> "tool"
          _ -> event.role || "other"
        end

    record = %{
      "id" => event.id,
      "stream_id" => event.stream_id,
      "sequence" => event.sequence,
      "source_sequence" => event.source_sequence,
      "source_revision" => source["source_revision"],
      "role" => role,
      "event_type" => event.event_type,
      "text" => text,
      "text_sha256" => hash(text)
    }

    if event.integration == "openclaw" do
      provenance = source["input_provenance"]

      origin =
        case provenance do
          nil -> "unknown"
          %{"kind" => kind} when kind in ~w(external_user inter_session internal_system) -> kind
          _ -> "unrecognized"
        end

      Map.merge(record, %{"input_origin" => origin, "input_provenance" => provenance})
    else
      record
    end
  end

  # A missing origin can support a traceable candidate, never proof of human
  # confirmation. Explicit synthetic origins cannot assert or correct as users.
  defp user_assertion?(event),
    do:
      event["role"] == "user" and
        event["input_origin"] not in ~w(internal_system inter_session unrecognized)
end
