defmodule Backplane.Memory.Memories.RelationClassifier do
  @moduledoc false

  import Ecto.Query

  alias Backplane.Memory.CanonicalJSON
  alias Backplane.Memory.Memories
  alias Backplane.Memory.Memories.{Attribution, Evidence, Memory, Relations}
  alias Backplane.Memory.Privacy.Filter

  @classifier_version "relation-classifier-v1"
  @max_candidates 20
  # Normalize claim/entity hints in Elixir; cap the partition scan so malformed JSON cannot cause an unbounded read.
  @candidate_scan_limit 200
  @max_evidence_per_endpoint 20
  @max_model_evidence 10
  @max_model_content_chars 2_000
  @max_model_metadata_chars 200
  @max_model_comparisons 5
  @max_entities 20
  @max_entity_scan 100
  @max_entity_chars 100
  @max_claim_chars 500
  @max_content_hint_chars 2_000
  @max_content_tokens 100
  @content_stopwords ~w(and for from into the that this through with)

  def process(memory_id, opts \\ []) when is_binary(memory_id) do
    with {:ok, subject} <- get_subject(memory_id, opts) do
      if live?(subject) and relation_classifiable?(subject) do
        {deterministic, model} =
          subject
          |> candidate_peers()
          |> Enum.split_with(&deterministic_candidate?(&1, subject))

        (deterministic ++ Enum.take(model, @max_model_comparisons))
        |> Enum.reduce(:ok, fn peer, result ->
          case {result, classify_and_persist(peer, subject, opts)} do
            {:ok, next_result} -> next_result
            {{:error, _reason}, _next_result} -> result
          end
        end)
      else
        :ok
      end
    else
      {:error, :not_found} -> :ok
    end
  end

  defp get_subject(memory_id, opts) do
    case Keyword.fetch(opts, :partition) do
      {:ok, partition} -> Memories.get(memory_id, partition)
      :error -> test_subject(memory_id)
    end
  end

  if Mix.env() == :test do
    defp test_subject(memory_id), do: Memories.trusted_get(memory_id)
  else
    defp test_subject(_memory_id), do: {:error, :not_found}
  end

  defp live?(memory),
    do:
      is_nil(memory.deleted_at) and
        memory.lifecycle_state not in ~w(tombstoned superseded archived)

  defp relation_classifiable?(memory), do: memory.memory_type in ~w(semantic procedural)

  defp candidate_peers(subject) do
    project = Attribution.project(subject.metadata)

    Memory
    |> where([m], m.id != ^subject.id)
    |> where([m], is_nil(m.deleted_at))
    |> where([m], m.lifecycle_state not in ["tombstoned", "superseded", "archived"])
    |> where([m], m.host_id == ^subject.host_id)
    |> where([m], m.scope == ^subject.scope)
    |> where([m], m.namespace == ^subject.namespace)
    |> where([m], m.memory_type == ^subject.memory_type)
    |> where(
      [m],
      fragment(
        "COALESCE(CASE WHEN jsonb_typeof(?->'project') = 'string' THEN ?->>'project' ELSE '' END, '')",
        m.metadata,
        m.metadata
      ) == ^project
    )
    |> where([m], fragment("COALESCE(?, '')", m.client_id) == ^(subject.client_id || ""))
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(@candidate_scan_limit)
    |> repo().all()
    |> Enum.filter(&candidate_hint?(&1, subject))
    |> Enum.sort_by(&candidate_rank(&1, subject))
    |> Enum.take(@max_candidates)
  end

  defp candidate_hint?(candidate, subject) do
    ambiguous_overlap?(
      candidate,
      subject,
      normalize_claim(candidate.metadata),
      normalize_claim(subject.metadata)
    )
  end

  defp candidate_rank(candidate, subject) do
    rank =
      cond do
        deterministic_candidate?(candidate, subject) ->
          0

        claim_overlap?(normalize_claim(candidate.metadata), normalize_claim(subject.metadata)) ->
          1

        entity_overlap?(candidate, subject) ->
          2

        true ->
          3
      end

    {rank, -content_overlap_score(candidate, subject), candidate.id}
  end

  defp deterministic_candidate?(candidate, subject) do
    deterministic_classification(
      candidate,
      subject,
      normalize_claim(candidate.metadata),
      normalize_claim(subject.metadata)
    ) != nil
  end

  defp classify_and_persist(source, target, opts) do
    source_claim = normalize_claim(source.metadata)
    target_claim = normalize_claim(target.metadata)

    case deterministic_classification(source, target, source_claim, target_claim) do
      nil ->
        maybe_model_classification(source, target, source_claim, target_claim, opts)

      {classification, source, target} ->
        persist(source, target, classification, "deterministic")
    end
  end

  defp deterministic_classification(
         source,
         target,
         %{subject: subject, predicate: predicate, value: value, cardinality: "single"},
         %{subject: subject, predicate: predicate, value: value, cardinality: "single"}
       ),
       do: {%{classification: "duplicate", confidence: 1.0}, source, target}

  defp deterministic_classification(
         source,
         target,
         %{subject: subject, predicate: predicate, cardinality: "single"} = source_claim,
         %{subject: subject, predicate: predicate, cardinality: "single"} = target_claim
       ) do
    with true <- source_claim.value != target_claim.value,
         {:ok, source_interval} <- validity_interval(source.metadata),
         {:ok, target_interval} <- validity_interval(target.metadata) do
      classify_validity(source, source_interval, target, target_interval)
    else
      _ -> nil
    end
  end

  defp deterministic_classification(_source, _target, _source_claim, _target_claim), do: nil

  defp validity_interval(metadata) do
    with from when is_binary(from) <- metadata["valid_from"],
         {:ok, from, _offset} <- DateTime.from_iso8601(from),
         {:ok, to} <- optional_valid_to(metadata["valid_to"], from) do
      {:ok, {from, to}}
    else
      _ -> :error
    end
  end

  defp optional_valid_to(nil, _from), do: {:ok, nil}

  defp optional_valid_to(value, from) when is_binary(value) do
    with {:ok, to, _offset} <- DateTime.from_iso8601(value),
         :lt <- DateTime.compare(from, to) do
      {:ok, to}
    else
      _ -> :error
    end
  end

  defp optional_valid_to(_value, _from), do: :error

  defp ordered_non_overlapping(
         source,
         {source_from, source_to},
         target,
         {target_from, target_to}
       ) do
    cond do
      is_struct(source_to, DateTime) and
          DateTime.compare(source_to, target_from) in [:lt, :eq] ->
        {:ok, source, target}

      is_struct(target_to, DateTime) and
          DateTime.compare(target_to, source_from) in [:lt, :eq] ->
        {:ok, target, source}

      true ->
        :error
    end
  end

  defp classify_validity(source, source_interval, target, target_interval) do
    case ordered_non_overlapping(source, source_interval, target, target_interval) do
      {:ok, older, newer} ->
        {%{
           classification: "temporal_replacement",
           confidence: 1.0,
           automatic_confirmation: true
         }, older, newer}

      :error ->
        {%{classification: "contradiction", confidence: 1.0}, source, target}
    end
  end

  defp maybe_model_classification(source, target, source_claim, target_claim, opts) do
    model = configured_model(opts)

    if model && ambiguous_overlap?(source, target, source_claim, target_claim) do
      llm_module =
        Keyword.get(
          opts,
          :llm_module,
          Application.get_env(:backplane_memory, :llm_module, Backplane.Memory.LLM)
        )

      case llm_module.classify_relation(
             model_input(source, source_claim),
             model_input(target, target_claim)
           ) do
        {:ok, response} -> persist_model_result(source, target, response, opts)
        {:skip, :no_llm} -> :ok
        {:error, reason} -> {:error, reason}
        _other -> {:error, :invalid_classifier_response}
      end
    else
      :ok
    end
  end

  defp persist_model_result(source, target, response, opts) do
    with {:ok, classification} <- normalize_model_result(response),
         {:ok, source, target, classification} <-
           permitted_model_relation(source, target, classification) do
      persist(
        source,
        target,
        classification,
        configured_model(opts)
      )
    else
      :skip -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_model_result(%{"classification" => classification, "confidence" => confidence})
       when classification in ~w(duplicate extension temporal_replacement contradiction unrelated) and
              is_number(confidence) and confidence >= 0 and confidence <= 1 do
    {:ok, %{classification: classification, confidence: confidence / 1}}
  end

  defp normalize_model_result(_response), do: {:error, :invalid_classifier_response}

  defp permitted_model_relation(_source, _target, %{classification: "unrelated"}), do: :skip

  defp permitted_model_relation(source, target, %{classification: classification} = result)
       when classification in ["duplicate", "extension"],
       do: {:ok, source, target, result}

  defp permitted_model_relation(source, target, %{classification: "contradiction"} = result) do
    if conflicting_single_claims?(source, target) do
      {:ok, source, target, Map.put(result, :automatic_confirmation, false)}
    else
      :skip
    end
  end

  defp permitted_model_relation(
         source,
         target,
         %{classification: "temporal_replacement"} = result
       ) do
    if conflicting_single_claims?(source, target) do
      case {validity_interval(source.metadata), validity_interval(target.metadata)} do
        {{:ok, source_interval}, {:ok, target_interval}} ->
          case ordered_non_overlapping(source, source_interval, target, target_interval) do
            {:ok, older, newer} ->
              {:ok, older, newer, Map.put(result, :automatic_confirmation, true)}

            :error ->
              {:ok, source, target, Map.put(result, :automatic_confirmation, false)}
          end

        _unknown_validity ->
          {:ok, source, target, Map.put(result, :automatic_confirmation, false)}
      end
    else
      :skip
    end
  end

  defp conflicting_single_claims?(source, target) do
    case {normalize_claim(source.metadata), normalize_claim(target.metadata)} do
      {%{subject: subject, predicate: predicate, cardinality: "single", value: source_value},
       %{subject: subject, predicate: predicate, cardinality: "single", value: target_value}} ->
        source_value != target_value

      _ ->
        false
    end
  end

  defp persist(source, target, classification, model) do
    source_evidence_ids = evidence_ids(source.id)
    target_evidence_ids = evidence_ids(target.id)

    if source_evidence_ids == [] or target_evidence_ids == [] do
      :ok
    else
      source_claim = normalize_claim(source.metadata)
      target_claim = normalize_claim(target.metadata)

      attrs =
        %{
          classification: classification.classification,
          confidence: classification.confidence,
          automatic_confirmation: Map.get(classification, :automatic_confirmation, false),
          classifier_model: model,
          classifier_version: @classifier_version,
          input_revision:
            input_revision(
              source,
              target,
              source_claim,
              target_claim,
              source_evidence_ids,
              target_evidence_ids,
              model
            ),
          source_evidence_ids: source_evidence_ids,
          target_evidence_ids: target_evidence_ids
        }
        |> Map.merge(relation_trace(source, target))

      case Relations.apply_classifier(source.id, target.id, attrs) do
        {:ok, _relation} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp relation_trace(source, target) do
    traces = Enum.map([source, target], &Memories.provenance_trace/1)
    request_ids = traces |> Enum.flat_map(& &1.request_ids) |> Enum.uniq() |> Enum.sort()
    correlation_ids = traces |> Enum.flat_map(& &1.correlation_ids) |> Enum.uniq() |> Enum.sort()

    %{
      request_id: List.first(request_ids),
      request_ids: request_ids,
      correlation_id: List.first(request_ids),
      correlation_ids: correlation_ids
    }
  end

  defp evidence_ids(memory_id) do
    Evidence
    |> where([e], e.memory_id == ^memory_id)
    |> order_by([e], asc: e.created_at, asc: e.id)
    |> limit(@max_evidence_per_endpoint)
    |> select([e], e.id)
    |> repo().all()
  end

  defp input_revision(
         source,
         target,
         source_claim,
         target_claim,
         source_evidence_ids,
         target_evidence_ids,
         model
       ) do
    endpoints =
      [
        revision_endpoint(source, source_claim, source_evidence_ids),
        revision_endpoint(target, target_claim, target_evidence_ids)
      ]
      |> Enum.sort_by(& &1["id"])

    {:ok, encoded} =
      CanonicalJSON.encode(%{
        "classifier_model" => model,
        "classifier_version" => @classifier_version,
        "endpoints" => endpoints
      })

    encoded |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp revision_endpoint(memory, claim, evidence_ids) do
    %{
      "id" => memory.id,
      "content_hash" => Base.encode16(memory.content_hash, case: :lower),
      "claim" => claim_map(claim),
      "valid_from" => metadata_string(memory.metadata, "valid_from"),
      "valid_to" => metadata_string(memory.metadata, "valid_to"),
      "evidence_ids" => Enum.sort(evidence_ids),
      "evidence_state" => evidence_state(memory.id)
    }
  end

  defp evidence_state(memory_id) do
    query = from(e in Evidence, where: e.memory_id == ^memory_id)
    count = repo().aggregate(query, :count, :id)

    latest_id =
      query
      |> order_by([e], desc: e.created_at, desc: e.id)
      |> limit(1)
      |> select([e], e.id)
      |> repo().one()

    %{"count" => count, "latest_id" => latest_id}
  end

  defp normalize_claim(%{"claim" => claim}) when is_map(claim) do
    with subject when is_binary(subject) <- claim["subject"],
         predicate when is_binary(predicate) <- claim["predicate"],
         value when is_binary(value) <- claim["value"],
         cardinality when is_binary(cardinality) <- claim["cardinality"],
         {:ok, subject} <- normalize_claim_text(subject),
         {:ok, predicate} <- normalize_claim_text(predicate),
         {:ok, value} <- normalize_claim_text(value),
         {:ok, cardinality} <- normalize_claim_text(cardinality) do
      %{
        subject: subject,
        predicate: predicate,
        value: value,
        cardinality: cardinality
      }
    else
      _ -> nil
    end
  end

  defp normalize_claim(_metadata), do: nil

  defp ambiguous_overlap?(source, target, source_claim, target_claim) do
    claim_overlap?(source_claim, target_claim) or
      entity_overlap?(source, target) or content_overlap_score(source, target) > 0
  end

  defp entity_overlap?(source, target) do
    not MapSet.disjoint?(
      normalize_entities(source.metadata),
      normalize_entities(target.metadata)
    )
  end

  defp claim_overlap?(
         %{subject: subject, predicate: predicate},
         %{subject: subject, predicate: predicate}
       ),
       do: true

  defp claim_overlap?(_source_claim, _target_claim), do: false

  defp normalize_entities(%{"entities" => entities}) when is_list(entities) do
    entities
    |> Enum.take(@max_entity_scan)
    |> Enum.filter(&is_binary/1)
    |> Enum.take(@max_entities)
    |> Enum.map(&privacy_filter(&1, @max_entity_chars))
    |> Enum.map(&normalize_text/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_entities(_metadata), do: MapSet.new()

  defp normalize_claim_text(value) do
    bounded = String.slice(value, 0, @max_claim_chars + 1)

    if String.length(bounded) <= @max_claim_chars,
      do: {:ok, normalize_text(bounded)},
      else: :error
  end

  defp content_overlap_score(source, target) do
    source.content
    |> content_tokens()
    |> MapSet.intersection(content_tokens(target.content))
    |> MapSet.size()
  end

  defp content_tokens(content) do
    content
    |> String.slice(0, @max_content_hint_chars)
    |> String.downcase()
    |> then(&Regex.scan(~r/[\p{L}\p{N}][\p{L}\p{N}_-]{2,}/u, &1))
    |> Enum.take(@max_content_tokens)
    |> Enum.map(&hd/1)
    |> Enum.reject(&(&1 in @content_stopwords))
    |> MapSet.new()
  end

  defp model_input(memory, claim) do
    metadata_descriptor = %{
      "claim" => claim_map(claim),
      "entities" => memory.metadata |> normalize_entities() |> Enum.sort(),
      "valid_from" => bounded_metadata_string(memory.metadata, "valid_from"),
      "valid_to" => bounded_metadata_string(memory.metadata, "valid_to")
    }

    {:ok, sanitized_metadata} = Filter.apply_payload(metadata_descriptor)

    Map.merge(sanitized_metadata, %{
      "content" => privacy_filter(memory.content, @max_model_content_chars),
      "evidence" => model_evidence(memory.id)
    })
  end

  defp model_evidence(memory_id) do
    Evidence
    |> where([e], e.memory_id == ^memory_id)
    |> order_by([e], asc: e.created_at, asc: e.id)
    |> limit(@max_model_evidence)
    |> repo().all()
    |> Enum.map(fn evidence ->
      %{
        "evidence_kind" => privacy_filter(evidence.evidence_kind, @max_model_metadata_chars),
        "support_score" => evidence.support_score
      }
    end)
  end

  defp privacy_filter(value, max_chars) when is_binary(value) do
    {:ok, filtered} = Filter.apply_bounded(value, max_chars)
    filtered
  end

  defp privacy_filter(_value, _max_chars), do: nil

  defp normalize_text(value) do
    value |> String.trim() |> String.replace(~r/\s+/u, " ") |> String.downcase()
  end

  defp claim_map(nil), do: nil

  defp claim_map(claim) do
    %{
      "subject" => claim.subject,
      "predicate" => claim.predicate,
      "value" => claim.value,
      "cardinality" => claim.cardinality
    }
  end

  defp metadata_string(metadata, key) do
    case metadata[key] do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp bounded_metadata_string(metadata, key) do
    metadata
    |> metadata_string(key)
    |> privacy_filter(@max_model_metadata_chars)
  end

  defp configured_model(opts),
    do: Keyword.get(opts, :model, Backplane.Settings.get("memory.llm_model"))

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
