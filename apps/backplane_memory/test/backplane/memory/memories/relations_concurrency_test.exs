defmodule Backplane.Memory.Memories.RelationsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Memories.{Relation, RelationEvidence, Relations}
  alias Ecto.Adapters.SQL.Sandbox

  @timeout 30_000

  test "concurrent candidate creation and confirmation commit one durable transition" do
    prefix = "relation-concurrency-#{System.unique_integer([:positive, :monotonic])}"

    {first, second} =
      unboxed(fn ->
        {:ok, first} = Memories.remember("#{prefix}-first", direct_opts("#{prefix}-first"))
        {:ok, second} = Memories.remember("#{prefix}-second", direct_opts("#{prefix}-second"))
        {first, second}
      end)

    on_exit(fn -> cleanup([first.id, second.id]) end)

    attrs =
      unboxed(fn ->
        %{
          classification: "contradiction",
          confidence: 0.9,
          classifier_model: "test-model",
          classifier_version: "v1",
          input_revision: prefix,
          source_evidence_ids: Enum.map(Memories.list_evidence(first.id), & &1.id),
          target_evidence_ids: Enum.map(Memories.list_evidence(second.id), & &1.id)
        }
      end)

    create_results =
      concurrently(fn -> Relations.create_candidate(first.id, second.id, attrs) end)

    assert Enum.all?(create_results, &match?({:ok, {:ok, %Relation{}}}, &1))
    relation_ids = Enum.map(create_results, fn {:ok, {:ok, relation}} -> relation.id end)
    assert [relation_id] = Enum.uniq(relation_ids)

    resolve_results = concurrently(fn -> Relations.resolve_candidate(relation_id, :confirmed) end)
    assert Enum.all?(resolve_results, &match?({:ok, {:ok, %Relation{status: "confirmed"}}}, &1))

    unboxed(fn ->
      assert repo().aggregate(from(r in Relation, where: r.id == ^relation_id), :count) == 1

      assert repo().aggregate(
               from(join in RelationEvidence, where: join.relation_id == ^relation_id),
               :count
             ) == 2

      assert audit_count(first.id, "memory_relation.candidate") == 1
      assert audit_count(first.id, "memory_relation.resolve") == 1
    end)
  end

  test "concurrent replacements confirm exactly one successor for a source" do
    prefix = "supersession-concurrency-#{System.unique_integer([:positive, :monotonic])}"

    {old, next, newest} =
      unboxed(fn ->
        {:ok, old} =
          Memories.remember(
            "#{prefix}-old",
            direct_opts("#{prefix}-old") ++ [metadata: %{"valid_from" => "2023-01-01T00:00:00Z"}]
          )

        {:ok, next} =
          Memories.remember(
            "#{prefix}-next",
            direct_opts("#{prefix}-next") ++ [metadata: %{"valid_from" => "2024-01-01T00:00:00Z"}]
          )

        {:ok, newest} =
          Memories.remember(
            "#{prefix}-newest",
            direct_opts("#{prefix}-newest") ++
              [metadata: %{"valid_from" => "2025-01-01T00:00:00Z"}]
          )

        {old, next, newest}
      end)

    on_exit(fn -> cleanup([old.id, next.id, newest.id]) end)

    {first, second} =
      unboxed(fn ->
        {:ok, first} =
          Relations.create_candidate(
            old.id,
            next.id,
            relation_attrs("temporal_replacement", "#{prefix}-first", old, next)
          )

        {:ok, second} =
          Relations.create_candidate(
            old.id,
            newest.id,
            relation_attrs("temporal_replacement", "#{prefix}-second", old, newest)
          )

        {first, second}
      end)

    parent = self()

    tasks =
      Enum.map([first, second], fn relation ->
        Task.async(fn ->
          send(parent, {:resolver_ready, self()})

          receive do
            :resolve -> unboxed(fn -> Relations.resolve_candidate(relation.id, :confirmed) end)
          end
        end)
      end)

    pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:resolver_ready, pid}, @timeout
        pid
      end)

    Enum.each(pids, &send(&1, :resolve))
    results = Enum.map(tasks, &Task.await(&1, @timeout))

    assert Enum.count(results, &match?({:ok, %Relation{status: "confirmed"}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :conflicting_supersession})) == 1
  end

  test "candidate creation racing soft forget never validates an unlocked stale endpoint" do
    prefix = "relation-forget-race-#{System.unique_integer([:positive, :monotonic])}"

    {first, second, attrs} =
      unboxed(fn ->
        {:ok, first} = Memories.remember("#{prefix}-first", direct_opts("#{prefix}-first"))
        {:ok, second} = Memories.remember("#{prefix}-second", direct_opts("#{prefix}-second"))
        {first, second, relation_attrs("extension", prefix, first, second)}
      end)

    on_exit(fn -> cleanup([first.id, second.id]) end)
    parent = self()

    create =
      Task.async(fn ->
        send(parent, {:race_ready, self()})

        receive do: (:race ->
                       unboxed(fn -> Relations.create_candidate(first.id, second.id, attrs) end))
      end)

    forget =
      Task.async(fn ->
        send(parent, {:race_ready, self()})
        receive do: (:race -> unboxed(fn -> Memories.trusted_forget(second.id) end))
      end)

    pids =
      Enum.map([create, forget], fn _ ->
        assert_receive {:race_ready, pid}, @timeout
        pid
      end)

    Enum.each(pids, &send(&1, :race))

    create_result = Task.await(create, @timeout)
    assert :ok = Task.await(forget, @timeout)
    assert match?({:ok, %Relation{}}, create_result) or create_result == {:error, :not_found}

    case create_result do
      {:ok, relation} ->
        assert {:error, :not_found} =
                 unboxed(fn -> Relations.resolve_candidate(relation.id, :confirmed) end)

      {:error, :not_found} ->
        :ok
    end
  end

  defp concurrently(fun) do
    1..8
    |> Task.async_stream(fn _ -> unboxed(fun) end,
      max_concurrency: 8,
      timeout: @timeout,
      on_timeout: :kill_task
    )
    |> Enum.to_list()
  end

  defp audit_count(memory_id, operation) do
    %{rows: [[count]]} =
      repo().query!(
        "SELECT count(*) FROM memory_audit_log WHERE operation = $1 AND target_ids::text LIKE $2",
        [operation, "%#{memory_id}%"]
      )

    count
  end

  defp cleanup(memory_ids) do
    unboxed(fn ->
      memory_db_ids = Enum.map(memory_ids, &Ecto.UUID.dump!/1)

      tables = [
        "bpm_memory_relation_evidence",
        "bpm_memory_relations",
        "memory_audit_log",
        "bpm_memory_evidence",
        "bpm_memory_remember_requests"
      ]

      Enum.each(tables, &repo().query!("ALTER TABLE #{&1} DISABLE TRIGGER USER"))

      try do
        repo().query!(
          "DELETE FROM memory_audit_log WHERE target_ids::text ~ $1",
          [Enum.join(memory_ids, "|")]
        )

        repo().query!(
          "DELETE FROM bpm_memory_relation_evidence WHERE relation_id IN (SELECT id FROM bpm_memory_relations WHERE source_memory_id = ANY($1) OR target_memory_id = ANY($1))",
          [memory_db_ids]
        )

        repo().query!(
          "DELETE FROM bpm_memory_relations WHERE source_memory_id = ANY($1) OR target_memory_id = ANY($1)",
          [memory_db_ids]
        )

        repo().query!("DELETE FROM bpm_memory_evidence WHERE memory_id = ANY($1)", [memory_db_ids])

        repo().query!(
          "DELETE FROM bpm_memory_remember_requests WHERE memory_id = ANY($1)",
          [memory_db_ids]
        )

        repo().query!("DELETE FROM bpm_memories WHERE id = ANY($1)", [memory_db_ids])
      after
        Enum.each(Enum.reverse(tables), &repo().query!("ALTER TABLE #{&1} ENABLE TRIGGER USER"))
      end
    end)
  end

  defp unboxed(fun) do
    :ok = Sandbox.checkout(repo(), sandbox: false)

    try do
      fun.()
    after
      :ok = Sandbox.checkin(repo())
    end
  end

  defp direct_opts(key) do
    [
      agent_id: "agent",
      host_id: "host",
      scope: "scope",
      idempotency_scope: "test",
      idempotency_key: key
    ]
  end

  defp relation_attrs(classification, revision, source, target) do
    %{
      classification: classification,
      confidence: 0.9,
      classifier_model: "test-model",
      classifier_version: "v1",
      input_revision: revision,
      source_evidence_ids: Enum.map(Memories.list_evidence(source.id), & &1.id),
      target_evidence_ids: Enum.map(Memories.list_evidence(target.id), & &1.id)
    }
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
