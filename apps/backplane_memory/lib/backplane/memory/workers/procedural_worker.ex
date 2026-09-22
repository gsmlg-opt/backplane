defmodule Backplane.Memory.Workers.ProceduralWorker do
  @moduledoc "Oban worker: extract procedural memories from semantic memories (semantic → procedural). Nightly cron."

  use Oban.Worker, queue: :memory, max_attempts: 2

  import Ecto.Query
  require Logger
  alias Backplane.Memory.Memories.Evidence
  alias Backplane.Memory.Memories.EvidenceInheritance
  alias Backplane.Memory.Memories.Memory, as: MemorySchema
  alias Backplane.MemorySpaces.BackfillIssue
  alias Backplane.Memory.Lessons
  alias Backplane.Memory.Memories
  alias Backplane.Memory.PartitionIdentity
  alias Backplane.Memory.Projections.ProcessingState

  @min_semantic_count 10
  @processing_version "procedural-v1"
  @input_limit 30
  @max_inherited_evidence 300

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    Backplane.Memory.PipelineTelemetry.span("procedural", job.args, fn ->
      do_perform(job)
    end)
  end

  defp do_perform(job) do
    quarantine_incomplete_inputs()
    llm_module = Application.get_env(:backplane_memory, :llm_module, Backplane.Memory.LLM)
    partitions = qualifying_partitions() |> Enum.sort()

    case Backplane.Settings.get("memory.llm_model") do
      nil ->
        require Logger
        Logger.debug("[memory] procedural worker: skipping, no llm_model configured")

        Enum.each(partitions, fn partition ->
          attrs = processing_attrs(partition, qualifying_inputs(partition))

          _ = transition_current(partition, attrs, "skipped_no_model", reason: :no_model)
        end)

        :ok

      _model ->
        do_extract_procedural(partitions, llm_module, job)
    end
  end

  defp do_extract_procedural(partitions, llm_module, job) do
    require Logger

    errors =
      partitions
      |> Enum.flat_map(&process_partition(&1, llm_module, job))

    case errors do
      [] -> :ok
      [first | _rest] -> {:error, first}
    end
  end

  defp process_partition(partition, llm_module, job) do
    inputs = qualifying_inputs(partition)
    state_attrs = processing_attrs(partition, inputs)

    case transition_current(partition, state_attrs, "running") do
      {:ok, _state} ->
        process_current_partition(partition, inputs, state_attrs, llm_module, job)

      {:stale, _state} ->
        []

      {:error, reason} ->
        [reason]
    end
  end

  defp process_current_partition(partition, inputs, state_attrs, llm_module, job) do
    try do
      with {:ok, evidence} <- inherited_evidence(inputs),
           {:ok, outputs} <- generate_outputs(partition, inputs, llm_module),
           {:ok, _result, _state} <-
             persist_outputs(partition, state_attrs, outputs, evidence) do
        []
      else
        {:stale, _state} ->
          []

        {:error, reason} ->
          _ =
            transition_current(
              partition,
              state_attrs,
              ProcessingState.failure_status(job),
              reason: reason
            )

          [reason]
      end
    rescue
      exception ->
        _ =
          transition_current(
            partition,
            state_attrs,
            ProcessingState.failure_status(job),
            reason: exception
          )

        reraise exception, __STACKTRACE__
    end
  end

  defp generate_outputs(partition, inputs, llm_module) do
    case llm_module.extract_procedures(Enum.map_join(inputs, "\n", & &1.content)) do
      {:ok, procedures} when is_list(procedures) ->
        {:ok, normalize_outputs(procedures)}

      {:error, reason} ->
        Logger.warning("[memory] procedural worker: LLM extract failed",
          memory_space_id: elem(partition, 0),
          partition_id: elem(partition, 4),
          host_id: elem(partition, 6),
          namespace: elem(partition, 2),
          scope: elem(partition, 1),
          failure: failure_category(reason)
        )

        {:error, reason}

      _ ->
        {:ok, []}
    end
  end

  defp persist_outputs(partition, state_attrs, outputs, evidence) do
    revision = state_attrs.input_revision

    ProcessingState.persist_current(
      repo(),
      state_attrs,
      fn -> current_attrs(partition) end,
      fn ->
        outputs
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, :persisted}, fn {output, ordinal}, _acc ->
          case persist_output(output, partition, revision, ordinal, evidence) do
            {:ok, _result} ->
              {:cont, {:ok, :persisted}}

            {:error, reason} ->
              Logger.warning("[memory] procedural worker: failed to insert",
                failure: failure_category(reason)
              )

              {:halt, {:error, reason}}
          end
        end)
      end
    )
  end

  defp persist_output({:procedure, procedure}, partition, revision, ordinal, evidence) do
    Memories.remember(procedure,
      type: "procedural",
      memory_space_id: elem(partition, 0),
      scope: elem(partition, 1),
      namespace: elem(partition, 2),
      metadata: %{"project" => elem(partition, 3)},
      client_id: elem(partition, 4),
      source_client_id: empty_to_nil(elem(partition, 5)),
      agent_id: "consolidation",
      host_id: elem(partition, 6),
      idempotency_scope: "memory-worker:procedural",
      idempotency_key: idempotency_key(partition, revision, ordinal),
      evidence: evidence
    )
  end

  defp persist_output(
         {:lesson, rule, context, confidence},
         partition,
         revision,
         ordinal,
         evidence
       ) do
    if Backplane.Memory.Config.lesson_auto_extract?() and evidence != [] do
      Lessons.create_candidate(
        %{
          rule: rule,
          context: context,
          project: elem(partition, 3),
          source_kind: "consolidation",
          confidence: confidence,
          evidence: evidence,
          idempotency_key: idempotency_key(partition, revision, ordinal)
        },
        %{
          memory_space_id: elem(partition, 0),
          scope: elem(partition, 1),
          namespace: elem(partition, 2),
          client_id: elem(partition, 4),
          source_client_id: empty_to_nil(elem(partition, 5)),
          host_id: elem(partition, 6)
        },
        %{actor: "system:lesson-consolidation", request_id: revision, correlation_id: revision}
      )
    else
      {:ok, :ignored}
    end
  end

  defp failure_category(%module{}), do: inspect(module)
  defp failure_category(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_category(_reason), do: "runtime_failure"

  defp qualifying_partitions do
    repo().all(
      from(m in MemorySchema,
        join: e in Evidence,
        on: e.memory_id == m.id,
        where:
          m.memory_type == "semantic" and is_nil(m.deleted_at) and
            not is_nil(m.memory_space_id) and not is_nil(m.scope) and
            not is_nil(m.namespace) and not is_nil(m.host_id) and not is_nil(m.client_id) and
            (not is_nil(e.source_event_id) or not is_nil(e.source_observation_id) or
               not is_nil(e.source_summary_id) or not is_nil(e.source_session_id)),
        group_by: [
          m.memory_space_id,
          m.scope,
          m.namespace,
          fragment(
            "COALESCE(CASE WHEN jsonb_typeof(?->'project') = 'string' THEN ?->>'project' ELSE '' END, '')",
            m.metadata,
            m.metadata
          ),
          fragment("COALESCE(?, '')", m.client_id),
          fragment("COALESCE(?, '')", m.source_client_id),
          m.host_id
        ],
        having: count(m.id, :distinct) >= @min_semantic_count,
        select:
          {m.memory_space_id, m.scope, m.namespace,
           fragment(
             "COALESCE(CASE WHEN jsonb_typeof(?->'project') = 'string' THEN ?->>'project' ELSE '' END, '')",
             m.metadata,
             m.metadata
           ), fragment("COALESCE(?, '')", m.client_id),
           fragment("COALESCE(?, '')", m.source_client_id), m.host_id}
      )
    )
    |> Enum.filter(fn {memory_space_id, scope, namespace, _project, client_id, _source, host_id} ->
      match?(
        {:ok, _},
        PartitionIdentity.validate_generator(%{
          memory_space_id: memory_space_id,
          host_id: host_id,
          client_id: client_id,
          scope: scope,
          namespace: namespace
        })
      )
    end)
    |> Enum.reject(&unresolved_partition?/1)
  end

  defp quarantine_incomplete_inputs do
    repo().all(
      from(m in MemorySchema,
        where:
          is_nil(m.memory_space_id) or fragment("nullif(btrim(?), '') IS NULL", m.host_id) or
            fragment("nullif(btrim(?), '') IS NULL", m.client_id) or
            fragment("nullif(btrim(?), '') IS NULL", m.scope) or
            fragment("nullif(btrim(?), '') IS NULL", m.namespace),
        select: %{
          id: m.id,
          memory_space_id: m.memory_space_id,
          host_id: m.host_id,
          client_id: m.client_id,
          source_client_id: m.source_client_id,
          scope: m.scope,
          namespace: m.namespace
        }
      )
    )
    |> Enum.each(fn memory ->
      validate_source_partition(memory)
    end)
  end

  @doc false
  def validate_source_partition(%{id: id} = memory) when is_binary(id) do
    partition =
      Map.take(memory, [
        :memory_space_id,
        :host_id,
        :client_id,
        :source_client_id,
        :scope,
        :namespace
      ])

    case PartitionIdentity.validate_generator(partition) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, reason} = error ->
        details = Map.new(partition, fn {key, value} -> {to_string(key), value} end)
        Memories.record_partition_issue("bpm_memories", id, reason, details)
        error
    end
  end

  defp unresolved_partition?(
         {memory_space_id, scope, namespace, _project, client_id, _source, host_id}
       ) do
    repo().exists?(
      from(issue in BackfillIssue,
        join: memory in MemorySchema,
        on: fragment("? = ?::text", issue.source_id, memory.id),
        where: issue.source_table == "bpm_memories" and issue.disposition == "pending",
        where:
          memory.memory_space_id == ^memory_space_id and memory.host_id == ^host_id and
            memory.client_id == ^client_id and memory.scope == ^scope and
            memory.namespace == ^namespace
      )
    )
  end

  defp qualifying_inputs(
         {memory_space_id, scope, namespace, project, client_id, _source_client_id, host_id}
       ) do
    root_memory_ids = root_memory_ids()

    repo().all(
      from(m in MemorySchema,
        where:
          m.memory_type == "semantic" and is_nil(m.deleted_at) and not is_nil(m.scope) and
            m.id in subquery(root_memory_ids),
        where: m.scope == ^scope and m.namespace == ^namespace,
        where: m.memory_space_id == ^memory_space_id,
        where:
          fragment(
            "COALESCE(CASE WHEN jsonb_typeof(?->'project') = 'string' THEN ?->>'project' ELSE '' END, '')",
            m.metadata,
            m.metadata
          ) == ^project,
        where: fragment("COALESCE(?, '')", m.client_id) == ^client_id,
        where: m.host_id == ^host_id,
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: @input_limit,
        select: %{
          id: m.id,
          content: m.content,
          content_hash: m.content_hash,
          scope: m.scope,
          namespace: m.namespace,
          metadata: m.metadata,
          client_id: m.client_id
        }
      )
    )
  end

  defp root_memory_ids do
    from(e in Evidence,
      where:
        not is_nil(e.source_event_id) or not is_nil(e.source_observation_id) or
          not is_nil(e.source_summary_id) or not is_nil(e.source_session_id),
      select: e.memory_id
    )
  end

  defp inherited_evidence(inputs) do
    with {:ok, roots} <-
           EvidenceInheritance.roots_by_memory(Enum.map(inputs, & &1.id),
             limit: @max_inherited_evidence
           ) do
      evidence =
        inputs
        |> Enum.flat_map(&Map.get(roots, &1.id, []))
        |> Enum.uniq_by(&source_identity/1)

      {:ok, evidence}
    end
  end

  defp input_revision(inputs) do
    inputs
    |> Enum.map_join("\n", fn memory ->
      memory.id <> ":" <> Base.encode16(memory.content_hash, case: :lower)
    end)
    |> sha256()
  end

  defp transition_current(partition, attrs, status, opts \\ []) do
    ProcessingState.transition_current(
      repo(),
      attrs,
      status,
      fn -> current_attrs(partition) end,
      opts
    )
  end

  defp current_attrs(partition) do
    # LLM generation stays outside this transaction. The short source fence prevents qualifying
    # memories or evidence from changing between this authoritative re-read and output/state writes.
    repo().query!("LOCK TABLE bpm_memories, bpm_memory_evidence IN SHARE MODE")
    {:ok, processing_attrs(partition, qualifying_inputs(partition))}
  end

  defp processing_attrs(partition, inputs) do
    {memory_space_id, scope, namespace, project, client_id, source_client_id, host_id} = partition

    %{
      memory_space_id: memory_space_id,
      host_id: host_id,
      source_client_id: empty_to_nil(source_client_id),
      scope: scope,
      namespace: namespace,
      projector: "procedural",
      subject_type: "memory_partition",
      subject_id:
        Enum.join([memory_space_id, host_id, client_id, scope, namespace, project], ":"),
      processing_version: @processing_version,
      input_revision: input_revision(inputs),
      output_revision: nil
    }
  end

  defp idempotency_key(partition, revision, ordinal) do
    partition_hash = partition |> :erlang.term_to_binary([:deterministic]) |> sha256()
    Enum.join([@processing_version, partition_hash, revision, ordinal], ":")
  end

  defp normalize_outputs(outputs) do
    outputs
    |> Enum.flat_map(fn
      output when is_binary(output) ->
        case String.trim(output) do
          "" -> []
          value -> [{:procedure, value}]
        end

      %{"type" => "lesson", "rule" => rule, "context" => context, "confidence" => confidence}
      when is_binary(rule) and is_binary(context) and is_number(confidence) and confidence >= 0 and
             confidence <= 1 ->
        [{:lesson, String.trim(rule), String.trim(context), confidence / 1}]

      _invalid ->
        []
    end)
    |> Enum.reject(fn
      {:lesson, "", _, _} -> true
      {:lesson, _, "", _} -> true
      _ -> false
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp source_identity(%{source_event_id: id}) when not is_nil(id), do: {:event, id}
  defp source_identity(%{source_observation_id: id}) when not is_nil(id), do: {:observation, id}
  defp source_identity(%{source_summary_id: id}) when not is_nil(id), do: {:summary, id}
  defp source_identity(%{source_session_id: id, host_id: host}), do: {:session, host, id}

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
