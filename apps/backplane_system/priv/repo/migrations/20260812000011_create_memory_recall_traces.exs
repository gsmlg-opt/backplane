defmodule Backplane.Repo.Migrations.CreateMemoryRecallTraces do
  use Ecto.Migration

  def up do
    create table(:memory_recall_runs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:host_id, :text, null: false)
      add(:client_id, :text, null: false)
      add(:scope, :text, null: false)
      add(:namespace, :text, null: false)
      add(:request_id, :text, null: false)
      add(:correlation_id, :text, null: false)
      add(:query_hash, :binary, null: false)
      add(:normalized_query, :text)
      add(:query_plan, :map, null: false, default: %{})
      add(:filters, :map, null: false, default: %{})
      add(:channel_weights, :map, null: false, default: %{})
      add(:channel_availability, :map, null: false, default: %{})
      add(:channel_errors, :map, null: false, default: %{})
      add(:token_budget, :integer, null: false)
      add(:tokens_used, :integer, null: false, default: 0)
      add(:result_count, :integer, null: false, default: 0)
      add(:latency_ms, :integer)
      add(:query_embedding_model, :text)
      add(:reranker_model, :text)
      add(:status, :text, null: false, default: "running")
      add(:failure_class, :text)
      add(:terminal_digest, :binary)
      add(:completed_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :memory_recall_runs,
        [:host_id, :client_id, :scope, :namespace, :request_id],
        name: :memory_recall_runs_partition_request_uniq
      )
    )

    create(
      unique_index(
        :memory_recall_runs,
        [:id, :host_id, :client_id, :scope, :namespace],
        name: :memory_recall_runs_partition_identity_uniq
      )
    )

    create(
      index(
        :memory_recall_runs,
        [:host_id, :client_id, :scope, :namespace, :inserted_at, :id],
        name: :memory_recall_runs_partition_page_idx
      )
    )

    create(index(:memory_recall_runs, [:expires_at], name: :memory_recall_runs_retention_idx))

    create(
      index(
        :memory_recall_runs,
        [:host_id, :client_id, :scope, :namespace, :correlation_id],
        name: :memory_recall_runs_partition_correlation_idx
      )
    )

    create(
      constraint(:memory_recall_runs, :memory_recall_runs_status_check,
        check: "status IN ('running', 'complete', 'failed')"
      )
    )

    create(
      constraint(:memory_recall_runs, :memory_recall_runs_counts_check,
        check:
          "token_budget > 0 AND token_budget <= 100000 AND tokens_used >= 0 AND tokens_used <= token_budget AND result_count >= 0 AND result_count <= 500"
      )
    )

    create(
      constraint(:memory_recall_runs, :memory_recall_runs_latency_check,
        check: "latency_ms IS NULL OR latency_ms >= 0"
      )
    )

    create(
      constraint(:memory_recall_runs, :memory_recall_runs_query_hash_check,
        check: "octet_length(query_hash) = 32"
      )
    )

    create(
      constraint(:memory_recall_runs, :memory_recall_runs_completion_check,
        check:
          "(status = 'running' AND completed_at IS NULL AND failure_class IS NULL AND terminal_digest IS NULL) OR (status = 'complete' AND completed_at IS NOT NULL AND failure_class IS NULL AND octet_length(terminal_digest) = 32) OR (status = 'failed' AND completed_at IS NOT NULL AND failure_class IS NOT NULL AND octet_length(terminal_digest) = 32)"
      )
    )

    create(
      constraint(:memory_recall_runs, :memory_recall_runs_retention_check,
        check: "expires_at >= inserted_at"
      )
    )

    create table(:memory_recall_candidates, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:host_id, :text, null: false)
      add(:client_id, :text, null: false)
      add(:scope, :text, null: false)
      add(:namespace, :text, null: false)

      add(
        :recall_run_id,
        references(:memory_recall_runs,
          type: :binary_id,
          on_delete: :delete_all,
          with: [
            host_id: :host_id,
            client_id: :client_id,
            scope: :scope,
            namespace: :namespace
          ],
          match: :full,
          name: :memory_recall_candidates_partition_fkey
        ),
        null: false
      )

      add(:candidate_id, :binary_id, null: false)
      add(:candidate_kind, :text, null: false)
      add(:memory_type, :text, null: false)
      add(:source_ids, {:array, :binary_id}, null: false)
      add(:channel_scores, :map, null: false, default: %{})
      add(:fts_rank, :integer)
      add(:vector_rank, :integer)
      add(:graph_rank, :integer)
      add(:fts_score, :float)
      add(:vector_score, :float)
      add(:graph_score, :float)
      add(:rrf_score, :float)
      add(:lifecycle_score, :float)
      add(:reranker_score, :float)
      add(:final_score, :float)
      add(:selected, :boolean, null: false, default: false)
      add(:rejection_reason, :text)
      add(:token_estimate, :integer, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :memory_recall_candidates,
        [:recall_run_id, :candidate_id, :candidate_kind],
        name: :memory_recall_candidates_run_candidate_uniq
      )
    )

    create(
      index(
        :memory_recall_candidates,
        [:recall_run_id, :selected, :final_score],
        name: :memory_recall_candidates_run_selection_idx
      )
    )

    create(
      constraint(:memory_recall_candidates, :memory_recall_candidates_kind_check,
        check: "candidate_kind IN ('memory', 'lesson', 'crystal', 'summary', 'observation')"
      )
    )

    create(
      constraint(:memory_recall_candidates, :memory_recall_candidates_type_check,
        check: "memory_type IN ('working', 'episodic', 'semantic', 'procedural')"
      )
    )

    create(
      constraint(:memory_recall_candidates, :memory_recall_candidates_provenance_check,
        check: "cardinality(source_ids) BETWEEN 1 AND 256"
      )
    )

    create(
      constraint(:memory_recall_candidates, :memory_recall_candidates_rank_check,
        check:
          "(fts_rank IS NULL OR fts_rank > 0) AND (vector_rank IS NULL OR vector_rank > 0) AND (graph_rank IS NULL OR graph_rank > 0)"
      )
    )

    create(
      constraint(:memory_recall_candidates, :memory_recall_candidates_token_check,
        check: "token_estimate >= 0 AND token_estimate <= 1000000"
      )
    )

    create(
      constraint(:memory_recall_candidates, :memory_recall_candidates_selection_truth_check,
        check:
          "(selected = true AND rejection_reason IS NULL) OR (selected = false AND rejection_reason IS NOT NULL AND rejection_reason IN ('diversity', 'token_budget', 'lifecycle', 'duplicate', 'below_threshold', 'superseded', 'disputed', 'archived', 'channel_error', 'review'))"
      )
    )

    create(
      constraint(:memory_recall_candidates, :memory_recall_candidates_finite_scores_check,
        check: finite_scores()
      )
    )
  end

  def down do
    drop(table(:memory_recall_candidates))
    drop(table(:memory_recall_runs))
  end

  defp finite_scores do
    ~w(fts_score vector_score graph_score rrf_score lifecycle_score reranker_score final_score)
    |> Enum.map_join(" AND ", fn column ->
      "(#{column} IS NULL OR #{column} NOT IN ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8))"
    end)
  end
end
