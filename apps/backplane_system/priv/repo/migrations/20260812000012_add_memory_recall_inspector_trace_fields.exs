defmodule Backplane.Repo.Migrations.AddMemoryRecallInspectorTraceFields do
  use Ecto.Migration

  def up do
    alter table(:memory_recall_runs) do
      add(:reranker_provider, :text)
      add(:reranker_status, :text)
      add(:reranker_error_class, :text)
      add(:reranker_duration_ms, :integer)
    end

    alter table(:memory_recall_candidates) do
      add(:source_refs, :map, null: false, default: %{"refs" => []})
      add(:pre_reranker_rank, :integer)
      add(:post_reranker_rank, :integer)
    end

    execute(create_source_refs_validator(), drop_source_refs_validator())

    create(
      index(
        :memory_recall_runs,
        [:host_id, :client_id, :scope, :namespace, :status, :inserted_at, :id],
        name: :memory_recall_runs_partition_status_page_idx
      )
    )

    create(
      constraint(:memory_recall_runs, :memory_recall_runs_reranker_status_check,
        check:
          "reranker_status IS NULL OR reranker_status IN ('ok', 'disabled', 'unavailable', 'empty', 'provider_error', 'exit', 'timeout', 'malformed', 'error')"
      )
    )

    create(
      constraint(:memory_recall_runs, :memory_recall_runs_reranker_duration_check,
        check: "reranker_duration_ms IS NULL OR reranker_duration_ms >= 0"
      )
    )

    create(
      constraint(:memory_recall_candidates, :memory_recall_candidates_source_refs_check,
        check: "#{qualified_function("memory_recall_source_refs_valid")}(source_refs, source_ids)"
      )
    )

    create(
      constraint(:memory_recall_candidates, :memory_recall_candidates_reranker_rank_check,
        check:
          "(pre_reranker_rank IS NULL OR pre_reranker_rank > 0) AND (post_reranker_rank IS NULL OR post_reranker_rank > 0)"
      )
    )
  end

  def down do
    drop(constraint(:memory_recall_candidates, :memory_recall_candidates_reranker_rank_check))
    drop(constraint(:memory_recall_candidates, :memory_recall_candidates_source_refs_check))
    drop(constraint(:memory_recall_runs, :memory_recall_runs_reranker_duration_check))
    drop(constraint(:memory_recall_runs, :memory_recall_runs_reranker_status_check))
    execute(drop_source_refs_validator())

    drop(
      index(
        :memory_recall_runs,
        [:host_id, :client_id, :scope, :namespace, :status, :inserted_at, :id],
        name: :memory_recall_runs_partition_status_page_idx
      )
    )

    alter table(:memory_recall_candidates) do
      remove(:post_reranker_rank)
      remove(:pre_reranker_rank)
      remove(:source_refs)
    end

    alter table(:memory_recall_runs) do
      remove(:reranker_duration_ms)
      remove(:reranker_error_class)
      remove(:reranker_status)
      remove(:reranker_provider)
    end
  end

  defp create_source_refs_validator do
    """
    CREATE FUNCTION #{qualified_function("memory_recall_source_refs_valid")}(payload jsonb, source_ids uuid[])
    RETURNS boolean
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $$
      WITH refs AS (
        SELECT ref
        FROM jsonb_array_elements(
          CASE
            WHEN jsonb_typeof(payload) = 'object'
              AND jsonb_typeof(payload->'refs') = 'array'
            THEN payload->'refs'
            ELSE '[]'::jsonb
          END
        ) AS ref
      ),
      parsed AS (
        SELECT (ref->>'id')::uuid AS id
        FROM refs
        WHERE jsonb_typeof(ref) = 'object'
          AND (ref->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      )
      SELECT
        jsonb_typeof(payload) = 'object'
        AND ARRAY(SELECT key FROM jsonb_object_keys(payload) AS key ORDER BY key) = ARRAY['refs']::text[]
        AND jsonb_typeof(payload->'refs') = 'array'
        AND (
          jsonb_array_length(payload->'refs') = 0
          OR (
            jsonb_array_length(payload->'refs') BETWEEN 1 AND 256
            AND NOT EXISTS (
              SELECT 1
              FROM refs
              WHERE jsonb_typeof(ref) IS DISTINCT FROM 'object'
                OR ARRAY(
                  SELECT key
                  FROM jsonb_object_keys(CASE WHEN jsonb_typeof(ref) = 'object' THEN ref ELSE '{}'::jsonb END) AS key
                  ORDER BY key
                ) <> ARRAY['id', 'type']::text[]
                OR ref->>'type' IS NULL
                OR ref->>'type' NOT IN ('memory', 'event', 'observation', 'summary', 'request', 'crystal', 'lesson')
                OR ref->>'id' IS NULL
                OR ref->>'id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            )
            AND ARRAY(SELECT DISTINCT id FROM parsed ORDER BY id)
              = ARRAY(SELECT DISTINCT id FROM unnest(source_ids) AS id ORDER BY id)
          )
        )
    $$
    """
  end

  defp drop_source_refs_validator,
    do: "DROP FUNCTION #{qualified_function("memory_recall_source_refs_valid")}(jsonb, uuid[])"

  defp qualified_function(function) do
    case prefix() do
      nil -> ~s|"#{function}"|
      prefix -> ~s|"#{String.replace(prefix, "\"", "\"\"")}"."#{function}"|
    end
  end
end
