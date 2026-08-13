defmodule Backplane.Memory.Memories.RelationsMigrationTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Memories

  test "deferred endpoint evidence constraint rejects bare relations and accepts both roles" do
    {:ok, source} = remember("migration source", "migration-source")
    {:ok, target} = remember("migration target", "migration-target")

    error =
      assert_raise Postgrex.Error, fn ->
        repo().transaction(fn ->
          insert_relation(source.id, target.id, "bare")
          repo().query!("SET CONSTRAINTS bpm_memory_relations_evidence_required IMMEDIATE")
        end)
      end

    assert error.postgres.code == :check_violation

    source_evidence_id = source.id |> Memories.list_evidence() |> hd() |> Map.fetch!(:id)
    target_evidence_id = target.id |> Memories.list_evidence() |> hd() |> Map.fetch!(:id)

    assert {:ok, relation_id} =
             repo().transaction(fn ->
               relation_id = insert_relation(source.id, target.id, "both")
               insert_relation_evidence(relation_id, source_evidence_id, "source")
               insert_relation_evidence(relation_id, target_evidence_id, "target")
               repo().query!("SET CONSTRAINTS bpm_memory_relations_evidence_required IMMEDIATE")
               Ecto.UUID.load!(relation_id)
             end)

    assert is_binary(relation_id)
  end

  test "confirmed supersession has a partial unique source index" do
    assert [[definition]] =
             repo().query!("""
             SELECT indexdef
             FROM pg_indexes
             WHERE indexname = 'bpm_memory_relations_confirmed_supersession_uniq'
             """).rows

    assert definition =~ "UNIQUE INDEX"
    assert definition =~ "source_memory_id"
    assert definition =~ "status = 'confirmed'"
    assert definition =~ "relation_type = 'supersedes'"
  end

  test "relation correlation is durable and required" do
    assert [["uuid", "NO"]] =
             repo().query!("""
             SELECT data_type, is_nullable
             FROM information_schema.columns
             WHERE table_name = 'bpm_memory_relations' AND column_name = 'correlation_id'
             """).rows
  end

  defp insert_relation(source_id, target_id, revision) do
    %{rows: [[relation_id]]} =
      repo().query!(
        """
        INSERT INTO bpm_memory_relations
          (source_memory_id, target_memory_id, domain, relation_type, classification,
           confidence, status, classifier_model, classifier_version, input_revision, correlation_id)
        VALUES ($1, $2, 'knowledge', 'extends', 'extension',
                0.9, 'candidate', 'migration-test', 'v1', $3, $4)
        RETURNING id
        """,
        [
          Ecto.UUID.dump!(source_id),
          Ecto.UUID.dump!(target_id),
          revision,
          Ecto.UUID.dump!(Ecto.UUID.generate())
        ]
      )

    relation_id
  end

  defp insert_relation_evidence(relation_id, evidence_id, role) do
    repo().query!(
      """
      INSERT INTO bpm_memory_relation_evidence (relation_id, evidence_id, role)
      VALUES ($1, $2, $3)
      """,
      [relation_id, Ecto.UUID.dump!(evidence_id), role]
    )
  end

  defp remember(content, key) do
    Memories.remember(content,
      agent_id: "agent",
      host_id: "host",
      scope: "scope",
      idempotency_scope: "test",
      idempotency_key: key
    )
  end
end
