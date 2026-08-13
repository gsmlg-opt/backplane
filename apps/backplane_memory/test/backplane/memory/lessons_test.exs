defmodule Backplane.Memory.LessonsTest do
  use Backplane.Memory.DataCase, async: true

  alias Backplane.Memory.{Audit, Lessons}
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.{Evidence, Memory}
  alias Backplane.Memory.Recall.{Channels, QueryPlan}
  alias Backplane.Memory.Service
  alias Backplane.Skills.Hosts

  @partition %{
    host_id: "lesson-host",
    client_id: "host:lesson-host",
    scope: "personal",
    namespace: "private"
  }

  test "manual save atomically creates an active procedural lesson with evidence" do
    assert {:ok, lesson} =
             save(
               %{
                 rule: "Always verify the served artifact",
                 actor: "agent-1",
                 context: "release verification",
                 project: "backplane",
                 session_id: "session-1",
                 idempotency_key: "lesson-1"
               },
               @partition
             )

    assert lesson.status == "active"
    assert lesson.source_kind == "manual"
    assert lesson.context == "release verification"
    assert lesson.reinforcement_count == 0
    assert lesson.contradiction_count == 0

    assert %Memory{
             id: memory_id,
             memory_type: "procedural",
             content: "Always verify the served artifact",
             lifecycle_state: "active"
           } = repo().get!(Memory, lesson.memory_id)

    assert memory_id == lesson.memory_id
    assert repo().aggregate(from(e in Evidence, where: e.memory_id == ^memory_id), :count) >= 1

    assert [%{actor: "agent-1", target_ids: [^memory_id], metadata: metadata}] =
             Audit.list(@partition, operation: "lesson.save")

    assert metadata["memory_id"] == memory_id
    assert metadata["source_kind"] == "manual"
    refute Map.has_key?(metadata, "content")
    refute Map.has_key?(metadata, "rule")
  end

  test "manual save retry reuses one memory, lesson, evidence chain, and correlated audit" do
    attrs = save_attrs("retry-lesson", "Always use stable lesson idempotency")

    assert {:ok, first} = save(attrs, @partition)

    evidence_count =
      repo().aggregate(from(e in Evidence, where: e.memory_id == ^first.memory_id), :count)

    assert {:ok, second} = save(attrs, @partition)

    assert second.memory_id == first.memory_id

    assert repo().aggregate(from(l in Lesson, where: l.memory_id == ^first.memory_id), :count) ==
             1

    assert repo().aggregate(from(e in Evidence, where: e.memory_id == ^first.memory_id), :count) ==
             evidence_count

    assert length(Audit.list(@partition, operation: "lesson.save")) == 1
  end

  test "lesson schema closes states and source kinds and rejects negative counters" do
    memory_id = Ecto.UUID.generate()

    for attrs <- [
          %{memory_id: memory_id, status: "unknown", source_kind: "manual"},
          %{memory_id: memory_id, status: "active", source_kind: "unknown"},
          %{
            memory_id: memory_id,
            status: "active",
            source_kind: "manual",
            reinforcement_count: -1
          },
          %{
            memory_id: memory_id,
            status: "active",
            source_kind: "manual",
            contradiction_count: -1
          },
          %{memory_id: memory_id, status: "active", source_kind: "manual", decay_rate: -0.1}
        ] do
      refute Lesson.changeset(%Lesson{}, attrs).valid?
    end
  end

  test "database rejects committing an active lesson without evidence" do
    assert {:ok, memory} =
             repo().insert(
               Memory.changeset(%Memory{}, %{
                 content: "Unproven lesson",
                 memory_type: "procedural",
                 agent_id: "agent-1",
                 host_id: @partition.host_id,
                 client_id: @partition.client_id,
                 scope: @partition.scope,
                 namespace: @partition.namespace
               })
             )

    assert_raise Postgrex.Error, ~r/requires evidence/, fn ->
      repo().transaction(fn ->
        lesson =
          repo().insert!(
            Lesson.changeset(%Lesson{}, %{
              memory_id: memory.id,
              status: "active",
              source_kind: "manual"
            })
          )

        repo().query!("SET CONSTRAINTS memory_active_lesson_evidence_from_lesson IMMEDIATE")
        lesson
      end)
    end

    refute repo().get(Lesson, memory.id)
  end

  test "database rejects a lesson whose parent is semantic" do
    assert {:ok, memory} =
             repo().insert(
               Memory.changeset(%Memory{}, %{
                 content: "Semantic parent",
                 memory_type: "semantic",
                 agent_id: "agent-1",
                 host_id: @partition.host_id,
                 client_id: @partition.client_id,
                 scope: @partition.scope,
                 namespace: @partition.namespace
               })
             )

    assert_raise Postgrex.Error, ~r/requires procedural memory parent/, fn ->
      repo().transaction(fn ->
        repo().insert!(
          Lesson.changeset(%Lesson{}, %{
            memory_id: memory.id,
            status: "candidate",
            source_kind: "manual"
          })
        )

        repo().query!("SET CONSTRAINTS memory_lesson_procedural_from_lesson IMMEDIATE")
      end)
    end
  end

  test "lesson recall is typed, exact-partition, and does not reinforce on return" do
    assert {:ok, own} =
             save(
               save_attrs("own-lesson", "Always inspect the served manifest"),
               @partition
             )

    foreign = %{@partition | host_id: "foreign-host", client_id: "host:foreign-host"}

    assert {:ok, _foreign} =
             save(
               save_attrs("foreign-lesson", "Always inspect the served manifest"),
               foreign
             )

    evidence_count =
      repo().aggregate(from(e in Evidence, where: e.memory_id == ^own.memory_id), :count)

    assert {:ok, [candidate]} =
             Lessons.recall("served manifest", @partition, limit: 10, project: "backplane")

    assert candidate.id == own.memory_id
    assert candidate.kind == :lesson
    assert candidate.memory_type == :procedural
    assert candidate.lifecycle_state == :active

    assert candidate.evidence_ids ==
             repo().all(from(e in Evidence, where: e.memory_id == ^own.memory_id, select: e.id))

    reloaded = repo().get!(Lesson, own.memory_id)
    assert reloaded.reinforcement_count == 0
    assert reloaded.last_reinforced_at == nil
    assert reloaded.last_applied_at == nil

    assert %Memory{access_count: 0, application_count: 0} = repo().get!(Memory, own.memory_id)

    assert repo().aggregate(from(e in Evidence, where: e.memory_id == ^own.memory_id), :count) ==
             evidence_count
  end

  test "top lessons returns bounded active project lessons with typed provenance" do
    assert {:ok, own} =
             save(
               save_attrs("top-own", "Always inspect the exact served artifact"),
               @partition
             )

    assert {:ok, _other_project} =
             save(
               %{save_attrs("top-other-project", "Never mix project lessons") | project: "other"},
               @partition
             )

    foreign = %{@partition | client_id: "foreign-client"}

    assert {:ok, _foreign} =
             save(save_attrs("top-foreign", "Never leak this foreign lesson"), foreign)

    assert {:ok, [candidate]} = Lessons.top(@partition, project: "backplane", limit: 1)
    assert candidate.id == own.memory_id
    assert candidate.kind == :lesson
    assert candidate.lifecycle_state == :active
    assert candidate.project == "backplane"
    assert candidate.source_ids != []
    assert candidate.evidence_ids != []

    assert {:error, :invalid_arguments} = Lessons.top(@partition, limit: 101)
    assert {:error, :unauthorized} = Lessons.top(Map.delete(@partition, :host_id))
  end

  test "general Recall V2 includes an active lesson as a typed candidate" do
    assert {:ok, lesson} =
             save(
               save_attrs("general-recall", "Prefer exact partition retrieval"),
               @partition
             )

    assert {:ok, plan} =
             QueryPlan.new(
               Map.merge(@partition, %{query: "exact partition retrieval", project: "backplane"})
             )

    assert {:ok, rows} = Channels.fts(plan, 10)

    assert Enum.any?(rows, fn {candidate, _score} ->
             candidate.id == lesson.memory_id and candidate.kind == :lesson
           end)
  end

  test "manual save cannot bypass governed inactive lesson state" do
    assert {:ok, lesson} =
             save(save_attrs("reactivate-1", "Reactivate this exact lesson"), @partition)

    memory = repo().get!(Memory, lesson.memory_id)

    repo().update!(Memory.lifecycle_changeset(memory, %{lifecycle_state: "archived"}))
    repo().update!(Lesson.changeset(lesson, %{status: "archived"}))

    assert {:error, :governed_state_conflict} =
             save(save_attrs("reactivate-2", "Reactivate this exact lesson"), @partition)

    assert repo().get!(Lesson, lesson.memory_id).status == "archived"
    assert repo().get!(Memory, lesson.memory_id).lifecycle_state == "archived"
  end

  test "canonical lesson tools enforce write for save and read for recall" do
    {:ok, host, _token, _plaintext} =
      Hosts.create_agent_with_token(%{
        "name" => "lesson-tools-#{System.unique_integer([:positive])}",
        "memory_scope" => "lesson-tools"
      })

    writer = auth(host, ["memory.write"])
    reader = auth(host, ["memory.read"])

    args =
      save_attrs("service-save", "Always preserve exact ownership")
      |> Map.delete(:actor)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    assert %{permission: "memory.write"} =
             Enum.find(Service.tools(), &(&1.name == "memory::lesson_save"))

    assert %{permission: "memory.read"} =
             Enum.find(Service.tools(), &(&1.name == "memory::lesson_recall"))

    assert {:error, :unauthorized} = Service.call("memory::lesson_save", args, reader)

    assert {:error, :invalid_arguments} =
             Service.call("memory::lesson_save", Map.put(args, "actor", "forged"), writer)

    assert {:ok, %{memory_id: memory_id, status: "active", source_kind: "manual"}} =
             Service.call(
               "memory::lesson_save",
               Map.merge(args, %{
                 "request_id" => "request-lesson-save",
                 "correlation_id" => "corr-lesson-save"
               }),
               writer
             )

    assert [%{actor: "authenticated-lesson-agent", metadata: metadata}] =
             Audit.list(operation: "lesson.save", actor: "authenticated-lesson-agent")

    assert metadata["request_id"] == "request-lesson-save"
    assert metadata["correlation_id"] == "corr-lesson-save"

    assert {:error, :unauthorized} =
             Service.call("memory::lesson_recall", %{"query" => "exact ownership"}, writer)

    assert {:ok, %{results: [%{memory_id: ^memory_id, kind: :lesson, status: :active}]}} =
             Service.call(
               "memory::lesson_recall",
               %{"query" => "exact ownership", "project" => "backplane"},
               reader
             )
  end

  defp save_attrs(key, rule) do
    %{
      rule: rule,
      actor: "agent-1",
      context: "release verification",
      project: "backplane",
      session_id: "session-1",
      idempotency_key: key
    }
  end

  defp save(attrs, partition) do
    {actor, attrs} = Map.pop(attrs, :actor)

    Lessons.save(attrs, partition, %{
      actor: actor,
      request_id: Ecto.UUID.generate(),
      correlation_id: "corr-lessons-test"
    })
  end

  defp auth(host, scopes) do
    %{
      kind: :client_token,
      client_id: Ecto.UUID.generate(),
      subject: "authenticated-lesson-agent",
      scopes: scopes,
      principal_metadata: %{"memory_partition_id" => "host:#{host.id}"}
    }
  end
end
