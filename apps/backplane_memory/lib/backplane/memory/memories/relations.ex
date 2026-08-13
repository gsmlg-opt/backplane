defmodule Backplane.Memory.Memories.Relations do
  @moduledoc false

  import Ecto.Query

  alias Backplane.Memory.Audit

  alias Backplane.Memory.Memories.{
    Attribution,
    Evidence,
    Memory,
    Relation,
    RelationEvidence,
    RelationPolicy
  }

  @symmetric ~w(contradiction duplicate unrelated)

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  def create_candidate(source_id, target_id, attrs) when is_map(attrs) do
    create_candidate(source_id, target_id, attrs, [])
  end

  def create_candidate(source_id, target_id, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    attrs = stringify(attrs)
    eligibility = Keyword.get(opts, :eligibility, :review)

    case repo().transaction(fn ->
           create_candidate_tx(source_id, target_id, attrs, eligibility)
         end) do
      {:ok, relation} -> {:ok, relation}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_classifier(source_id, target_id, attrs) when is_map(attrs) do
    attrs = stringify(attrs)

    case repo().transaction(fn ->
           create_candidate_tx(source_id, target_id, attrs, :classifier, true)
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_candidate(relation_id, resolution) when resolution in [:confirmed, :rejected] do
    status = Atom.to_string(resolution)

    case repo().transaction(fn -> resolve_tx(relation_id, status) end) do
      {:ok, relation} -> {:ok, relation}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_relations(memory_id) do
    Relation
    |> where([r], r.source_memory_id == ^memory_id or r.target_memory_id == ^memory_id)
    |> order_by([r], asc: r.created_at, asc: r.id)
    |> repo().all()
    |> Enum.map(fn relation ->
      evidence =
        RelationEvidence
        |> where([j], j.relation_id == ^relation.id)
        |> order_by([j], asc: j.role, asc: j.evidence_id)
        |> select([j], %{evidence_id: j.evidence_id, role: j.role})
        |> repo().all()

      relation |> Map.from_struct() |> Map.drop([:__meta__]) |> Map.put(:evidence, evidence)
    end)
  end

  defp create_candidate_tx(source_id, target_id, attrs, eligibility, automatic_policy? \\ false) do
    if source_id == target_id, do: repo().rollback(:same_memory)
    attrs = validate_candidate_attrs!(attrs)

    classification = attrs["classification"]
    {source_id, target_id, attrs} = canonical_pair(source_id, target_id, classification, attrs)
    memories = lock_memories!([source_id, target_id])
    source = Map.fetch!(memories, source_id)
    target = Map.fetch!(memories, target_id)
    validate_live_endpoints!(source, target)
    validate_candidate_eligibility!(source, target, eligibility)
    validate_partition!(source, target)

    {evidence, source_evidence, target_evidence} =
      endpoint_evidence!(source.id, target.id, attrs)

    identity = candidate_identity(source.id, target.id, attrs)
    advisory_lock!(identity)

    outcome =
      if automatic_policy?,
        do: RelationPolicy.outcome(attrs, source_evidence, target_evidence),
        else: :manual_review

    candidate_attrs =
      attrs
      |> Map.merge(classification_fields(classification))
      |> Map.put("correlation_id", attrs["correlation_id"] || Ecto.UUID.generate())
      |> Map.merge(%{
        "source_memory_id" => source.id,
        "target_memory_id" => target.id,
        "status" => "candidate"
      })

    apply_policy(
      outcome,
      find_identity(identity),
      candidate_attrs,
      evidence,
      attrs,
      source,
      target
    )
  end

  defp apply_policy(:reject_noop, _existing, attrs, evidence, _input, source, target) do
    if not policy_audited?(attrs, source, target) do
      audit_policy(attrs, evidence, :reject_noop, source, target, nil, [])
    end

    :noop
  end

  defp apply_policy(outcome, existing, candidate_attrs, evidence, attrs, source, target) do
    relation =
      case existing do
        %Relation{} = existing ->
          if same_candidate?(existing, candidate_attrs, evidence, attrs["correlation_id"]),
            do: existing,
            else: repo().rollback(:idempotency_conflict)

        nil ->
          relation =
            %Relation{} |> Relation.candidate_changeset(candidate_attrs) |> repo().insert!()

          Enum.each(evidence, fn {role, evidence_id} ->
            %RelationEvidence{}
            |> RelationEvidence.changeset(%{
              relation_id: relation.id,
              evidence_id: evidence_id,
              role: role
            })
            |> repo().insert!()
          end)

          Audit.log(
            "memory_relation.candidate",
            "system",
            [source.id, target.id],
            relation_audit_metadata(relation, evidence, "candidate", source, target)
          )

          relation
      end

    {relation, transitions} = apply_policy_outcome(outcome, relation, source, target)

    if is_nil(existing) and outcome != :manual_review do
      audit_policy(candidate_attrs, evidence, outcome, source, target, relation, transitions)
    end

    relation
  end

  defp apply_policy_outcome(
         :confirm,
         %Relation{status: "candidate"} = relation,
         _source,
         _target
       ),
       do: {resolve_pending!(relation, "confirmed"), []}

  defp apply_policy_outcome(:confirm, relation, _source, _target), do: {relation, []}

  defp apply_policy_outcome(:review, relation, source, target) do
    transitions =
      if relation.classification == "contradiction",
        do: mark_disputed_for_review!([source, target]),
        else: []

    {relation, transitions}
  end

  defp apply_policy_outcome(:manual_review, relation, _source, _target), do: {relation, []}

  defp mark_disputed_for_review!(memories) do
    Enum.flat_map(memories, fn memory ->
      if memory.lifecycle_state in ~w(disputed archived superseded tombstoned) do
        []
      else
        updated =
          memory
          |> Memory.lifecycle_changeset(%{lifecycle_state: "disputed", superseded_by: nil})
          |> repo().update!()

        [
          %{
            memory_id: memory.id,
            before: lifecycle_snapshot(memory),
            after: lifecycle_snapshot(updated)
          }
        ]
      end
    end)
  end

  defp audit_policy(attrs, evidence, outcome, source, target, relation, transitions) do
    Audit.log(
      "memory_relation.policy",
      "system",
      [source.id, target.id],
      Map.merge(relation_trace_metadata(source, target), %{
        relation_id: relation && relation.id,
        correlation_id: attrs["correlation_id"],
        source_memory_id: source.id,
        target_memory_id: target.id,
        classification: attrs["classification"],
        confidence: attrs["confidence"],
        classifier_model: attrs["classifier_model"],
        classifier_version: attrs["classifier_version"],
        input_revision: attrs["input_revision"],
        evidence:
          Enum.map(evidence, fn {role, evidence_id} -> %{role: role, evidence_id: evidence_id} end),
        outcome: outcome,
        result: Atom.to_string(outcome),
        lifecycle_transitions: transitions
      })
    )
  end

  defp policy_audited?(attrs, source, target) do
    input_revision = attrs["input_revision"]
    source_id = source.id
    target_id = target.id

    repo().exists?(
      from(a in "memory_audit_log",
        where:
          a.operation == "memory_relation.policy" and
            fragment("?->>'input_revision' = ?", a.metadata, ^input_revision) and
            fragment("?->>'source_memory_id' = ?", a.metadata, ^source_id) and
            fragment("?->>'target_memory_id' = ?", a.metadata, ^target_id)
      )
    )
  end

  defp validate_candidate_eligibility!(source, target, :classifier) do
    eligible? = fn memory -> memory.lifecycle_state not in ~w(archived superseded tombstoned) end

    if eligible?.(source) and eligible?.(target), do: :ok, else: repo().rollback(:not_found)
  end

  defp validate_candidate_eligibility!(_source, _target, :review), do: :ok

  defp validate_candidate_eligibility!(_source, _target, _eligibility),
    do: repo().rollback(:invalid_eligibility)

  defp resolve_tx(relation_id, status) do
    relation = repo().one(from(r in Relation, where: r.id == ^relation_id, lock: "FOR UPDATE"))
    if is_nil(relation), do: repo().rollback(:not_found)

    cond do
      relation.status == status ->
        relation

      relation.status != "candidate" ->
        repo().rollback(:resolution_conflict)

      true ->
        resolve_pending!(relation, status)
    end
  end

  defp resolve_pending!(relation, status) do
    memories = lock_memories!([relation.source_memory_id, relation.target_memory_id])
    source = Map.fetch!(memories, relation.source_memory_id)
    target = Map.fetch!(memories, relation.target_memory_id)
    validate_live_endpoints!(source, target)
    validate_partition!(source, target)

    if status == "confirmed" and relation.classification == "temporal_replacement" do
      if conflicting_supersession?(relation), do: repo().rollback(:conflicting_supersession)
      if supersession_reaches?(target.id, source.id), do: repo().rollback(:supersession_cycle)
      validate_temporal!(source, target)
    end

    before = Map.new(memories, fn {id, memory} -> {id, lifecycle_snapshot(memory)} end)
    updated = relation |> Relation.resolution_changeset(status) |> repo().update!()

    after_states =
      memories
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Map.new(fn memory ->
        updated_memory = recompute_lifecycle!(memory)
        {memory.id, lifecycle_snapshot(updated_memory)}
      end)

    transitions =
      before
      |> Enum.sort_by(fn {memory_id, _state} -> memory_id end)
      |> Enum.map(fn {memory_id, before_state} ->
        %{memory_id: memory_id, before: before_state, after: Map.fetch!(after_states, memory_id)}
      end)

    evidence = relation_evidence_tuples(relation.id)

    Audit.log(
      "memory_relation.resolve",
      "system",
      [source.id, target.id],
      relation_audit_metadata(updated, evidence, status, source, target)
      |> Map.put(:lifecycle_transitions, transitions)
    )

    updated
  end

  defp recompute_lifecycle!(%Memory{deleted_at: deleted_at} = memory)
       when not is_nil(deleted_at) do
    memory
    |> Memory.lifecycle_changeset(%{lifecycle_state: "tombstoned", superseded_by: nil})
    |> repo().update!()
  end

  defp recompute_lifecycle!(memory) do
    supersession =
      repo().one(
        from(r in Relation,
          where:
            r.source_memory_id == ^memory.id and r.status == "confirmed" and
              r.classification == "temporal_replacement",
          order_by: [desc: r.resolved_at, desc: r.id],
          limit: 1
        )
      )

    contradiction? =
      repo().exists?(
        from(r in Relation,
          where:
            r.status == "confirmed" and r.classification == "contradiction" and
              (r.source_memory_id == ^memory.id or r.target_memory_id == ^memory.id)
        )
      )

    attrs =
      cond do
        supersession ->
          %{lifecycle_state: "superseded", superseded_by: supersession.target_memory_id}

        memory.lifecycle_state == "archived" ->
          %{lifecycle_state: "archived", superseded_by: nil}

        contradiction? ->
          %{lifecycle_state: "disputed", superseded_by: nil}

        memory.lifecycle_state == "candidate" ->
          %{lifecycle_state: "candidate", superseded_by: nil}

        true ->
          %{lifecycle_state: "active", superseded_by: nil}
      end

    memory |> Memory.lifecycle_changeset(attrs) |> repo().update!()
  end

  defp lock_memories!(ids) do
    expected_count = ids |> Enum.uniq() |> length()

    Memory
    |> where([m], m.id in ^Enum.sort(ids))
    |> order_by([m], asc: m.id)
    |> lock("FOR UPDATE")
    |> repo().all()
    |> case do
      memories when length(memories) == expected_count -> Map.new(memories, &{&1.id, &1})
      _ -> repo().rollback(:not_found)
    end
  end

  defp validate_live_endpoints!(source, target) do
    live? = fn memory ->
      is_nil(memory.deleted_at) and memory.lifecycle_state != "tombstoned"
    end

    if live?.(source) and live?.(target), do: :ok, else: repo().rollback(:not_found)
  end

  defp validate_partition!(source, target) do
    fields = [:host_id, :scope, :namespace, :memory_type]

    equal? =
      Enum.all?(fields, &(Map.fetch!(source, &1) == Map.fetch!(target, &1))) and
        Attribution.project(source.metadata) == Attribution.project(target.metadata) and
        (source.client_id || "") == (target.client_id || "")

    if equal?, do: :ok, else: repo().rollback(:partition_mismatch)
  end

  defp endpoint_evidence!(source_id, target_id, attrs) do
    source_ids = attrs["source_evidence_ids"]
    target_ids = attrs["target_evidence_ids"]

    if not is_list(source_ids) or source_ids == [] or not is_list(target_ids) or target_ids == [],
      do: repo().rollback(:evidence_required)

    requested = Enum.uniq(source_ids ++ target_ids)

    evidence =
      Evidence
      |> where([e], e.id in ^requested)
      |> order_by([e], asc: e.created_at, asc: e.id)
      |> repo().all()

    owners = Map.new(evidence, &{&1.id, &1.memory_id})

    valid? =
      map_size(owners) == length(requested) and
        Enum.all?(source_ids, &(owners[&1] == source_id)) and
        Enum.all?(target_ids, &(owners[&1] == target_id))

    if not valid?, do: repo().rollback(:invalid_evidence)

    tuples =
      Enum.map(Enum.uniq(source_ids), &{"source", &1}) ++
        Enum.map(Enum.uniq(target_ids), &{"target", &1})

    by_id = Map.new(evidence, &{&1.id, &1})

    {tuples, Enum.map(Enum.uniq(source_ids), &Map.fetch!(by_id, &1)),
     Enum.map(Enum.uniq(target_ids), &Map.fetch!(by_id, &1))}
  end

  defp classification_fields("contradiction"),
    do: %{"domain" => "lifecycle", "relation_type" => "contradicts"}

  defp classification_fields("temporal_replacement"),
    do: %{"domain" => "lifecycle", "relation_type" => "supersedes"}

  defp classification_fields("extension"),
    do: %{"domain" => "knowledge", "relation_type" => "extends"}

  defp classification_fields("duplicate"),
    do: %{"domain" => "knowledge", "relation_type" => "related"}

  defp classification_fields("unrelated"),
    do: %{"domain" => "knowledge", "relation_type" => "related"}

  defp classification_fields(_), do: repo().rollback(:invalid_classification)

  defp canonical_pair(source, target, classification, attrs) when classification in @symmetric do
    if source < target do
      {source, target, attrs}
    else
      swapped =
        attrs
        |> Map.put("source_evidence_ids", attrs["target_evidence_ids"])
        |> Map.put("target_evidence_ids", attrs["source_evidence_ids"])

      {target, source, swapped}
    end
  end

  defp canonical_pair(source, target, _classification, attrs), do: {source, target, attrs}

  defp candidate_identity(source, target, attrs),
    do:
      {source, target, classification_fields(attrs["classification"])["domain"],
       classification_fields(attrs["classification"])["relation_type"], attrs["classifier_model"],
       attrs["classifier_version"], attrs["input_revision"]}

  defp find_identity({source, target, domain, type, model, version, revision}) do
    repo().one(
      from(r in Relation,
        where:
          r.source_memory_id == ^source and
            r.target_memory_id == ^target and r.domain == ^domain and r.relation_type == ^type and
            r.classifier_model == ^model and r.classifier_version == ^version and
            r.input_revision == ^revision
      )
    )
  end

  defp same_candidate?(relation, attrs, evidence, requested_correlation_id) do
    persisted_evidence =
      RelationEvidence
      |> where([join], join.relation_id == ^relation.id)
      |> select([join], {join.role, join.evidence_id})
      |> repo().all()

    relation.classification == attrs["classification"] and
      relation.confidence == attrs["confidence"] and
      (is_nil(requested_correlation_id) or relation.correlation_id == requested_correlation_id) and
      MapSet.new(persisted_evidence) == MapSet.new(evidence)
  end

  defp conflicting_supersession?(relation) do
    repo().exists?(
      from(r in Relation,
        where:
          r.id != ^relation.id and r.source_memory_id == ^relation.source_memory_id and
            r.status == "confirmed" and r.relation_type == "supersedes"
      )
    )
  end

  defp lifecycle_snapshot(memory) do
    %{lifecycle_state: memory.lifecycle_state, superseded_by: memory.superseded_by}
  end

  defp relation_evidence_tuples(relation_id) do
    RelationEvidence
    |> where([join], join.relation_id == ^relation_id)
    |> order_by([join], asc: join.role, asc: join.evidence_id)
    |> select([join], {join.role, join.evidence_id})
    |> repo().all()
  end

  defp relation_audit_metadata(relation, evidence, result, source, target) do
    Map.merge(relation_trace_metadata(source, target), %{
      correlation_id: relation.correlation_id,
      relation_id: relation.id,
      source_memory_id: relation.source_memory_id,
      target_memory_id: relation.target_memory_id,
      source_host_id: source.host_id,
      source_client_id: source.client_id,
      target_host_id: target.host_id,
      target_client_id: target.client_id,
      domain: relation.domain,
      relation_type: relation.relation_type,
      classification: relation.classification,
      confidence: relation.confidence,
      classifier_model: relation.classifier_model,
      classifier_version: relation.classifier_version,
      input_revision: relation.input_revision,
      evidence:
        evidence
        |> Enum.sort()
        |> Enum.map(fn {role, evidence_id} -> %{role: role, evidence_id: evidence_id} end),
      result: result
    })
  end

  defp relation_trace_metadata(source, target) do
    traces = Enum.map([source, target], &Backplane.Memory.Memories.provenance_trace/1)
    request_ids = traces |> Enum.flat_map(& &1.request_ids) |> Enum.uniq() |> Enum.sort()
    correlation_ids = traces |> Enum.flat_map(& &1.correlation_ids) |> Enum.uniq() |> Enum.sort()

    %{
      host_id: source.host_id,
      client_id: source.client_id,
      scope: source.scope,
      namespace: source.namespace,
      request_id: List.first(request_ids),
      request_ids: request_ids,
      correlation_ids: correlation_ids
    }
  end

  defp validate_candidate_attrs!(attrs) do
    required_strings = ~w(classification classifier_model classifier_version input_revision)

    valid_strings? =
      Enum.all?(required_strings, fn field ->
        value = attrs[field]
        is_binary(value) and String.trim(value) != ""
      end)

    confidence = attrs["confidence"]
    valid_confidence? = is_number(confidence) and confidence >= 0 and confidence <= 1

    attrs = normalize_correlation_id!(attrs)

    if valid_strings? and valid_confidence?, do: attrs, else: repo().rollback(:invalid_candidate)
  end

  defp normalize_correlation_id!(%{"correlation_id" => correlation_id} = attrs)
       when not is_nil(correlation_id) do
    case Ecto.UUID.cast(correlation_id) do
      {:ok, normalized} -> Map.put(attrs, "correlation_id", normalized)
      :error -> repo().rollback(:invalid_candidate)
    end
  end

  defp normalize_correlation_id!(attrs), do: attrs

  defp validate_temporal!(source, target) do
    with {:ok, source_at} <- parse_validity(source.metadata),
         {:ok, target_at} <- parse_validity(target.metadata),
         :lt <- DateTime.compare(source_at, target_at) do
      :ok
    else
      _ -> repo().rollback(:invalid_temporal_replacement)
    end
  end

  defp parse_validity(metadata) do
    case metadata["valid_from"] || metadata[:valid_from] do
      value when is_binary(value) ->
        DateTime.from_iso8601(value)
        |> case do
          {:ok, dt, _offset} -> {:ok, dt}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp supersession_reaches?(current, wanted, seen \\ MapSet.new()) do
    cond do
      current == wanted ->
        true

      MapSet.member?(seen, current) ->
        true

      true ->
        case repo().get(Memory, current) do
          %Memory{superseded_by: next} when is_binary(next) ->
            supersession_reaches?(next, wanted, MapSet.put(seen, current))

          _ ->
            false
        end
    end
  end

  defp advisory_lock!(identity) do
    <<key::signed-64, _::binary>> =
      :crypto.hash(:sha256, :erlang.term_to_binary(identity, [:deterministic]))

    repo().query!("SELECT pg_advisory_xact_lock($1::bigint)", [key])
  end

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end
