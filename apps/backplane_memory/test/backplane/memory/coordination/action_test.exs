defmodule Backplane.Memory.Coordination.ActionTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Audit, Coordination.Action, Coordination.Lease}

  defp build_attrs(overrides \\ %{}) do
    Map.merge(%{"title" => "Do something important"}, overrides)
  end

  describe "create/2" do
    test "inserts action with correct defaults" do
      assert {:ok, action} = Action.create(build_attrs())
      assert action.id != nil
      assert action.title == "Do something important"
      assert action.status == "pending"
      assert action.priority == 0
      assert action.tags == []

      assert [%{operation: "coordination.action.create", target_ids: [action_id]}] =
               Audit.list(operation: "coordination.action.create")

      assert action_id == action.id
    end

    test "accepts custom fields" do
      attrs = build_attrs(%{"priority" => 5, "project" => "proj-x", "created_by" => "agent-1"})
      assert {:ok, action} = Action.create(attrs)
      assert action.priority == 5
      assert action.project == "proj-x"
      assert action.created_by == "agent-1"
    end

    test "preserves every supported provenance origin" do
      observation_id = Ecto.UUID.generate()
      memory_id = Ecto.UUID.generate()
      lesson_id = Ecto.UUID.generate()
      crystal_id = Ecto.UUID.generate()

      assert {:ok, action} =
               Action.create(
                 build_attrs(%{
                   "source_observation_ids" => [observation_id],
                   "source_memory_ids" => [memory_id],
                   "source_session_ids" => ["session-a"],
                   "source_lesson_ids" => [lesson_id],
                   "source_crystal_ids" => [crystal_id]
                 })
               )

      assert action.source_observation_ids == [observation_id]
      assert action.source_memory_ids == [memory_id]
      assert action.source_session_ids == ["session-a"]
      assert action.source_lesson_ids == [lesson_id]
      assert action.source_crystal_ids == [crystal_id]
    end

    test "title is required" do
      assert {:error, %Ecto.Changeset{errors: errors}} = Action.create(%{})
      assert Keyword.has_key?(errors, :title)
    end

    test "invalid status is rejected" do
      assert {:error, %Ecto.Changeset{errors: errors}} =
               Action.create(build_attrs(%{"status" => "unknown"}))

      assert Keyword.has_key?(errors, :status)
    end
  end

  describe "update_status/2" do
    test "changes status successfully" do
      {:ok, action} = Action.create(build_attrs())
      assert :ok = Action.update_status(action.id, "in_progress")

      updated = repo().get(Action, action.id)
      assert updated.status == "in_progress"

      assert [%{operation: "coordination.action.status", target_ids: [action_id]}] =
               Audit.list(operation: "coordination.action.status")

      assert action_id == action.id
    end

    test "returns not_found for unknown id" do
      assert {:error, :not_found} = Action.update_status(Ecto.UUID.generate(), "done")
    end

    test "returns error for invalid status" do
      {:ok, action} = Action.create(build_attrs())
      assert {:error, {:invalid_status, "flying"}} = Action.update_status(action.id, "flying")
    end
  end

  describe "frontier/1" do
    test "returns pending and in_progress actions" do
      {:ok, a1} = Action.create(build_attrs(%{"title" => "A", "priority" => 1}))

      {:ok, a2} =
        Action.create(build_attrs(%{"title" => "B", "status" => "in_progress", "priority" => 2}))

      {:ok, _} = Action.create(build_attrs(%{"title" => "C", "status" => "done"}))

      frontier_ids = Action.frontier() |> Enum.map(& &1.id)
      assert a1.id in frontier_ids
      assert a2.id in frontier_ids
    end

    test "excludes actions with a pending requires prerequisite" do
      {:ok, prereq} = Action.create(build_attrs(%{"title" => "Prereq", "priority" => 10}))
      {:ok, dependent} = Action.create(build_attrs(%{"title" => "Dependent", "priority" => 5}))

      repo().insert_all("memory_action_edges", [
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          source_id: Ecto.UUID.dump!(prereq.id),
          target_id: Ecto.UUID.dump!(dependent.id),
          edge_type: "requires"
        }
      ])

      frontier_ids = Action.frontier() |> Enum.map(& &1.id)
      assert prereq.id in frontier_ids
      refute dependent.id in frontier_ids
    end

    test "includes dependent once prerequisite is done" do
      {:ok, prereq} = Action.create(build_attrs(%{"title" => "Prereq"}))
      {:ok, dependent} = Action.create(build_attrs(%{"title" => "Dependent"}))

      repo().insert_all("memory_action_edges", [
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          source_id: Ecto.UUID.dump!(prereq.id),
          target_id: Ecto.UUID.dump!(dependent.id),
          edge_type: "requires"
        }
      ])

      Action.update_status(prereq.id, "done")

      frontier_ids = Action.frontier() |> Enum.map(& &1.id)
      assert dependent.id in frontier_ids
    end

    test "project filter scopes results" do
      {:ok, a1} = Action.create(build_attrs(%{"title" => "In proj", "project" => "proj-x"}))
      {:ok, _a2} = Action.create(build_attrs(%{"title" => "Other proj", "project" => "proj-y"}))

      frontier_ids = Action.frontier("proj-x") |> Enum.map(& &1.id)
      assert frontier_ids == [a1.id]
    end
  end

  describe "next/1" do
    test "returns highest-priority unblocked action" do
      {:ok, low} = Action.create(build_attrs(%{"title" => "Low", "priority" => 1}))
      {:ok, high} = Action.create(build_attrs(%{"title" => "High", "priority" => 10}))

      assert Action.next().id == high.id
      refute Action.next().id == low.id
    end

    test "returns nil when no actions available" do
      assert Action.next() == nil
    end

    test "project filter scopes next result" do
      {:ok, a} =
        Action.create(build_attrs(%{"title" => "A", "project" => "proj-x", "priority" => 5}))

      {:ok, _b} =
        Action.create(build_attrs(%{"title" => "B", "project" => "proj-y", "priority" => 99}))

      assert Action.next("proj-x").id == a.id
    end
  end

  describe "list/2" do
    test "returns a bounded all-status page from only the exact partition" do
      partition = %{
        host_id: "host-a",
        client_id: "client-a",
        scope: "scope-a",
        namespace: "private"
      }

      foreign = %{partition | client_id: "client-b"}

      assert {:ok, pending} =
               Action.create(
                 build_attrs(%{"title" => "Pending", "project" => "alpha"}),
                 [],
                 partition
               )

      assert {:ok, done} =
               Action.create(
                 build_attrs(%{"title" => "Done", "status" => "done", "project" => "alpha"}),
                 [],
                 partition
               )

      assert {:ok, _foreign} = Action.create(build_attrs(%{"title" => "Foreign"}), [], foreign)

      assert {:ok, %{entries: [first], next_offset: 1}} =
               Action.list(partition, limit: 1, offset: 0, project: "alpha")

      assert first.id in [pending.id, done.id]

      assert {:ok, %{entries: [second], next_offset: nil}} =
               Action.list(partition, limit: 1, offset: 1, project: "alpha")

      assert Enum.sort([first.id, second.id]) == Enum.sort([pending.id, done.id])
    end

    test "rejects missing partitions and unbounded options" do
      partition = %{
        host_id: "host-a",
        client_id: "client-a",
        scope: "scope-a",
        namespace: "private"
      }

      assert {:error, :partition_required} = Action.list(nil, [])
      assert {:error, :invalid_options} = Action.list(partition, limit: 101)
      assert {:error, :invalid_options} = Action.list(partition, offset: 10_001)
    end
  end

  describe "detail/2" do
    test "returns the exact-partition action with its active lease" do
      partition = %{
        host_id: "host-a",
        client_id: "client-a",
        scope: "scope-a",
        namespace: "private"
      }

      assert {:ok, action} =
               Action.create(
                 build_attrs(%{"source_session_ids" => ["session-a"]}),
                 [],
                 partition
               )

      assert {:ok, lease_id} = Lease.acquire(action.id, "agent-a", 300, partition)

      assert {:ok, %{action: selected, lease: lease}} = Action.detail(action.id, partition)
      assert selected.id == action.id
      assert selected.source_session_ids == ["session-a"]
      assert lease.id == lease_id
      assert lease.holder_agent_id == "agent-a"

      assert {:error, :not_found} =
               Action.detail(action.id, %{partition | client_id: "client-b"})
    end
  end
end
