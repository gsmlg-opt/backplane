defmodule Backplane.Memory.Workers.ProceduralWorker do
  @moduledoc "Oban worker: extract procedural memories from semantic memories (semantic → procedural). Nightly cron."

  use Oban.Worker, queue: :memory, max_attempts: 2

  import Ecto.Query
  require Logger
  alias Backplane.Memory.Memories.Evidence
  alias Backplane.Memory.Memories.EvidenceInheritance
  alias Backplane.Memory.Memories.Memory, as: MemorySchema
  alias Backplane.Memory.Lessons
  alias Backplane.Memory.Memories

  @min_semantic_count 10
  @processing_version "procedural-v1"
  @input_limit 30
  @max_inherited_evidence 300

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    Backplane.Memory.PipelineTelemetry.span("procedural", job.args, fn ->
      do_perform()
    end)
  end

  defp do_perform do
    llm_module = Application.get_env(:backplane_memory, :llm_module, Backplane.Memory.LLM)

    case Backplane.Settings.get("memory.llm_model") do
      nil ->
        require Logger
        Logger.debug("[memory] procedural worker: skipping, no llm_model configured")
        :ok

      _model ->
        do_extract_procedural(llm_module)
    end
  end

  defp do_extract_procedural(llm_module) do
    require Logger

    errors =
      qualifying_partitions()
      |> Enum.sort()
      |> Enum.flat_map(&process_partition(&1, llm_module))

    case errors do
      [] -> :ok
      [first | _rest] -> {:error, first}
    end
  end

  defp process_partition(partition, llm_module) do
    inputs = qualifying_inputs(partition)

    case inherited_evidence(inputs) do
      {:ok, evidence} ->
        extract_partition(partition, inputs, evidence, llm_module)

      {:error, reason} ->
        [reason]
    end
  end

  defp extract_partition(partition, inputs, evidence, llm_module) do
    case llm_module.extract_procedures(Enum.map_join(inputs, "\n", & &1.content)) do
      {:ok, procedures} when is_list(procedures) ->
        revision = input_revision(inputs)

        procedures
        |> normalize_outputs()
        |> Enum.with_index()
        |> Enum.flat_map(fn {output, ordinal} ->
          case persist_output(output, partition, revision, ordinal, evidence) do
            {:ok, _} ->
              []

            {:error, reason} ->
              Logger.warning("[memory] procedural worker: failed to insert",
                failure: failure_category(reason)
              )

              [reason]
          end
        end)

      {:error, reason} ->
        Logger.warning("[memory] procedural worker: LLM extract failed",
          partition_id: partition.client_id,
          host_id: partition.host_id,
          namespace: partition.namespace,
          scope: partition.scope,
          failure: failure_category(reason)
        )

        [reason]

      _ ->
        []
    end
  end

  defp persist_output({:procedure, procedure}, partition, revision, ordinal, evidence) do
    Memories.remember(procedure,
      type: "procedural",
      scope: elem(partition, 0),
      namespace: elem(partition, 1),
      metadata: %{"project" => elem(partition, 2)},
      client_id: empty_to_nil(elem(partition, 3)),
      agent_id: "consolidation",
      host_id: elem(partition, 4),
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
          project: elem(partition, 2),
          source_kind: "consolidation",
          confidence: confidence,
          evidence: evidence,
          idempotency_key: idempotency_key(partition, revision, ordinal)
        },
        %{
          scope: elem(partition, 0),
          namespace: elem(partition, 1),
          client_id: elem(partition, 3),
          host_id: elem(partition, 4)
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
          m.memory_type == "semantic" and is_nil(m.deleted_at) and not is_nil(m.scope) and
            (not is_nil(e.source_event_id) or not is_nil(e.source_observation_id) or
               not is_nil(e.source_summary_id) or not is_nil(e.source_session_id)),
        group_by: [
          m.scope,
          m.namespace,
          fragment(
            "COALESCE(CASE WHEN jsonb_typeof(?->'project') = 'string' THEN ?->>'project' ELSE '' END, '')",
            m.metadata,
            m.metadata
          ),
          fragment("COALESCE(?, '')", m.client_id),
          m.host_id
        ],
        having: count(m.id, :distinct) >= @min_semantic_count,
        select:
          {m.scope, m.namespace,
           fragment(
             "COALESCE(CASE WHEN jsonb_typeof(?->'project') = 'string' THEN ?->>'project' ELSE '' END, '')",
             m.metadata,
             m.metadata
           ), fragment("COALESCE(?, '')", m.client_id), m.host_id}
      )
    )
  end

  defp qualifying_inputs({scope, namespace, project, client_id, host_id}) do
    root_memory_ids = root_memory_ids()

    repo().all(
      from(m in MemorySchema,
        where:
          m.memory_type == "semantic" and is_nil(m.deleted_at) and not is_nil(m.scope) and
            m.id in subquery(root_memory_ids),
        where: m.scope == ^scope and m.namespace == ^namespace,
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
