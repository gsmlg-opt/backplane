defmodule Backplane.Memory.CrystalActionChainTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Config, Crystals, Memories}
  alias Backplane.Memory.Coordination.Action
  alias Backplane.Memory.Crystals.{Crystal, LessonLink, SourceAction}
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.{Evidence, Memory}

  @partition %{
    host_id: "host-crystal-action",
    client_id: "client-crystal-action",
    scope: "team",
    namespace: "project"
  }

  setup do
    previous_client = Application.get_env(:backplane_memory, :llm_client)
    Application.put_env(:backplane_memory, :llm_client, __MODULE__)

    keys =
      ~w(memory.crystals_enabled memory.crystal_action_enabled memory.crystal_session_enabled)

    snapshot = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})
    Enum.each(keys, &:ets.delete(:backplane_settings, &1))

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:backplane_memory, :llm_client, previous_client),
        else: Application.delete_env(:backplane_memory, :llm_client)

      Enum.each(snapshot, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        if rows != [], do: :ets.insert(:backplane_settings, rows)
      end)
    end)

    :ok
  end

  test "connected terminal action chain produces one immutable typed crystal without changing history" do
    {:ok, first} = create_action("Implement", "done")
    {:ok, second} = create_action("Verify", "cancelled")
    insert_edge(first.id, second.id)
    before_rows = action_history()

    results =
      1..4
      |> Enum.map(fn _ ->
        Task.async(fn -> Crystals.build_action_chain(first.id, @partition) end)
      end)
      |> Task.await_many(10_000)

    assert [crystal_id] = results |> Enum.map(fn {:ok, c} -> c.id end) |> Enum.uniq()
    assert action_history() == before_rows
    assert repo().aggregate(Crystal, :count) == 1
    assert repo().aggregate(SourceAction, :count) == 2
    assert {:ok, %{source_action_ids: ids}} = Crystals.get(crystal_id, @partition)
    assert Enum.sort(ids) == Enum.sort([first.id, second.id])

    assert_raise Ecto.ConstraintError, fn ->
      repo().delete!(repo().one!(from link in SourceAction, limit: 1))
    end

    error =
      assert_raise Postgrex.Error, fn ->
        repo().transaction(fn ->
          repo().query!("UPDATE memory_actions SET status = 'pending' WHERE id = $1", [
            Ecto.UUID.dump!(first.id)
          ])

          repo().query!("SET CONSTRAINTS ALL IMMEDIATE")
        end)
      end

    assert error.postgres.constraint == "memory_crystal_action_source_check"
  end

  test "nonterminal chain requires an explicit authorized override" do
    {:ok, action} = create_action("Still running", "in_progress")

    assert {:error, {:nonterminal_actions, [id]}} =
             Crystals.build_action_chain(action.id, @partition)

    assert id == action.id

    assert {:error, :override_forbidden} =
             Crystals.build_action_chain(action.id, @partition, allow_nonterminal: true)

    assert {:ok, crystal} =
             Crystals.build_action_chain(action.id, @partition,
               allow_nonterminal: true,
               authorized_override: true
             )

    assert %SourceAction{terminal_override: true} =
             repo().one!(from l in SourceAction, where: l.crystal_id == ^crystal.id)
  end

  test "action-chain crystal persists and indexes only privacy-filtered structured fields" do
    private_marker = "crystalprivateleak"
    secret_marker = "crystalsecretleak"

    {:ok, done} =
      create_action(
        "Deliver <private>#{private_marker}</private> password=#{secret_marker}",
        "done",
        "Notes <private>#{private_marker}</private> token=#{secret_marker}"
      )

    {:ok, cancelled} =
      create_action(
        "Cancel <private>#{private_marker}</private> password=#{secret_marker}",
        "cancelled",
        nil
      )

    insert_edge(done.id, cancelled.id)

    assert {:ok, crystal} = Crystals.build_action_chain(done.id, @partition)
    assert %Memory{content: indexed_content} = repo().get!(Memory, crystal.memory_id)

    persisted =
      Jason.encode!(%{
        title: crystal.title,
        narrative: crystal.narrative,
        outcomes: crystal.key_outcomes,
        unresolved: crystal.unresolved_items,
        indexed_content: indexed_content
      })

    refute persisted =~ private_marker
    refute persisted =~ secret_marker
    refute persisted =~ "<private>"
    assert persisted =~ "[REDACTED]"
    assert {:ok, []} = Crystals.search(private_marker, @partition)
    assert {:ok, []} = Crystals.search(secret_marker, @partition)
  end

  @tag timeout: 5_000
  test "dense connected action graph terminates within a bounded statement and stays partitioned" do
    action_ids = insert_actions(36, @partition)

    action_ids
    |> Enum.with_index()
    |> Enum.flat_map(fn {source, index} ->
      action_ids
      |> Enum.drop(index + 1)
      |> Enum.map(&{source, &1})
    end)
    |> insert_edges()

    foreign_partition = Map.put(@partition, :host_id, "foreign-dense-host")
    [foreign_id] = insert_actions(1, foreign_partition)
    insert_edge(List.first(action_ids), foreign_id)

    repo().query!("SET LOCAL statement_timeout = '1500ms'")

    assert {:ok, crystal} = Crystals.build_action_chain(List.first(action_ids), @partition)
    assert {:ok, %{source_action_ids: source_ids}} = Crystals.get(crystal.id, @partition)
    assert Enum.sort(source_ids) == Enum.sort(action_ids)
    refute foreign_id in source_ids
  end

  @tag timeout: 5_000
  test "action traversal stops after the authorized limit in a much larger component" do
    action_ids = insert_actions(4_000, @partition)

    action_ids
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [source, target] -> {source, target} end)
    |> insert_edges()

    repo().query!("SET LOCAL statement_timeout = '1500ms'")

    assert {:error, :action_chain_too_large} =
             Crystals.build_action_chain(List.first(action_ids), @partition, limit: 10)
  end

  test "crystal lesson candidate uses an exact typed crystal ID and remains candidate" do
    {:ok, action} = create_action("Learn", "done")

    assert {:ok, crystal} =
             Crystals.build_action_chain(action.id, @partition,
               lesson_candidates: [
                 %{rule: "Always verify migrations", context: "Database changes"}
               ]
             )

    assert %Lesson{status: "candidate"} = lesson = repo().one!(Lesson)

    assert %Evidence{source_crystal_id: crystal_id} =
             repo().one!(
               from e in Evidence,
                 where: e.memory_id == ^lesson.memory_id and not is_nil(e.source_crystal_id)
             )

    assert crystal_id == crystal.id

    assert %LessonLink{lesson_memory_id: lesson_id, relation_type: "extracted"} =
             repo().one!(LessonLink)

    assert lesson_id == lesson.memory_id
  end

  test "a later crystal reinforces an existing lesson through the typed join" do
    {:ok, first} = create_action("Discover", "done")

    assert {:ok, first_crystal} =
             Crystals.build_action_chain(first.id, @partition,
               lesson_candidates: [%{rule: "Verify before handoff", context: "Completion"}]
             )

    assert %Lesson{} = lesson = repo().one!(Lesson)
    {:ok, second} = create_action("Apply", "done")

    assert {:ok, second_crystal} =
             Crystals.build_action_chain(second.id, @partition,
               lesson_candidates: [%{lesson_memory_id: lesson.memory_id}]
             )

    assert second_crystal.id != first_crystal.id
    assert repo().get!(Lesson, lesson.memory_id).reinforcement_count == 1

    assert %LessonLink{relation_type: "reinforced"} =
             repo().one!(
               from link in LessonLink,
                 where:
                   link.crystal_id == ^second_crystal.id and
                     link.lesson_memory_id == ^lesson.memory_id
             )
  end

  test "coordinated crystal and parent mutation cannot orphan lesson links" do
    {:ok, action} = create_action("Linked lesson", "done")

    assert {:ok, crystal} =
             Crystals.build_action_chain(action.id, @partition,
               lesson_candidates: [%{rule: "Keep partitions exact", context: "Crystals"}]
             )

    error = assert_partition_move_rejected(crystal, action, "memory_crystal_lesson_link_check")
    assert error.postgres.constraint == "memory_crystal_lesson_link_check"
  end

  test "coordinated crystal and parent mutation cannot orphan typed crystal evidence" do
    {:ok, action} = create_action("Evidence source", "done")
    assert {:ok, crystal} = Crystals.build_action_chain(action.id, @partition)

    assert {:ok, _memory} =
             Memories.remember("Crystal evidence without lesson join",
               type: "procedural",
               agent_id: "tester",
               host_id: @partition.host_id,
               client_id: @partition.client_id,
               scope: @partition.scope,
               namespace: @partition.namespace,
               evidence: [
                 %{
                   source_crystal_id: crystal.id,
                   host_id: @partition.host_id,
                   evidence_kind: "derives",
                   support_score: 1.0
                 }
               ]
             )

    error = assert_partition_move_rejected(crystal, action, "memory_crystal_evidence_check")
    assert error.postgres.constraint == "memory_crystal_evidence_check"
  end

  test "master and child flags are strict, LLM-aware gates" do
    assert Config.crystals_enabled?()
    assert Config.crystal_session_enabled?()
    assert Config.crystal_action_enabled?()
    put_setting("memory.crystals_enabled", "true")
    assert Backplane.Settings.get("memory.crystals_enabled") == "true"
    assert Config.crystals_enabled?()
    put_setting("memory.crystals_enabled", false)
    refute Config.crystals_enabled?()
    put_setting("memory.crystals_enabled", true)
    put_setting("memory.crystal_action_enabled", false)
    refute Config.crystal_action_enabled?()
    {:ok, action} = create_action("Done", "done")
    assert {:error, :crystal_action_disabled} = Crystals.build_action_chain(action.id, @partition)
  end

  defp create_action(title, status, description \\ nil),
    do:
      Action.create(
        %{
          "title" => title,
          "description" => description,
          "status" => status,
          "created_by" => "tester",
          "project" => "memory-v2"
        },
        [],
        @partition
      )

  defp insert_edge(source, target),
    do:
      repo().insert_all("memory_action_edges", [
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          source_id: Ecto.UUID.dump!(source),
          target_id: Ecto.UUID.dump!(target),
          edge_type: "requires"
        }
      ])

  defp insert_edges(edges) do
    repo().insert_all(
      "memory_action_edges",
      Enum.map(edges, fn {source, target} ->
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          source_id: Ecto.UUID.dump!(source),
          target_id: Ecto.UUID.dump!(target),
          edge_type: "requires"
        }
      end)
    )
  end

  defp insert_actions(count, partition) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(1..count, fn index ->
        %{
          id: Ecto.UUID.generate(),
          host_id: partition.host_id,
          client_id: partition.client_id,
          scope: partition.scope,
          namespace: partition.namespace,
          title: "Dense action #{index}",
          status: "done",
          priority: 0,
          created_by: "tester",
          project: "memory-v2",
          tags: [],
          source_observation_ids: [],
          source_memory_ids: [],
          created_at: now,
          updated_at: now
        }
      end)

    {^count, inserted} = repo().insert_all(Action, rows, returning: [:id])
    Enum.map(inserted, & &1.id)
  end

  defp action_history,
    do: repo().all(from a in Action, order_by: a.id, select: {a.id, a.status, a.updated_at})

  defp assert_partition_move_rejected(crystal, action, expected_constraint) do
    # Flush valid fixture events before transactional DDL. PostgreSQL rejects
    # ALTER TABLE while deferred trigger events are still pending.
    repo().query!("SET CONSTRAINTS ALL IMMEDIATE")
    repo().query!("SET CONSTRAINTS ALL DEFERRED")

    error =
      assert_raise Postgrex.Error, fn ->
        repo().transaction(fn ->
          # Isolate the crystal-side reciprocal trigger under test. The DDL is
          # transactional and rolls back with the expected constraint error.
          repo().query!(
            "ALTER TABLE bpm_memories DISABLE TRIGGER memory_crystal_memory_parent_check"
          )

          repo().query!("ALTER TABLE memory_crystals DISABLE TRIGGER memory_crystal_parent_check")

          for {table, id} <- [
                {"memory_actions", action.id},
                {"bpm_memories", crystal.memory_id},
                {"memory_crystals", crystal.id}
              ] do
            repo().query!("UPDATE #{table} SET namespace = 'moved' WHERE id = $1", [
              Ecto.UUID.dump!(id)
            ])
          end

          # Re-arm evaluation inside the savepoint so the deferred reciprocal
          # event is checked before the sandbox rolls the outer transaction back.
          repo().query!("SET CONSTRAINTS ALL IMMEDIATE")
        end)
      end

    assert error.postgres.constraint == expected_constraint
    error
  end

  defp put_setting(key, value), do: :ets.insert(:backplane_settings, {key, value})
end
