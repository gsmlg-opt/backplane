defmodule Backplane.Memory.Operations.InventoryTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.Operations.Inventory
  alias Backplane.Memory.Projections.ActivityContribution

  test "trusted inventory globally orders, counts and pages across spaces without host registration" do
    a = canonical_partition("inventory-offline-a")
    b = canonical_partition("inventory-removed-b")
    older = memory(a, "shared older", ~U[2026-01-01 00:00:00.000000Z])
    newest = memory(b, "shared newest", ~U[2026-01-03 00:00:00.000000Z])
    middle = memory(a, "shared middle", ~U[2026-01-02 00:00:00.000000Z])
    memory(b, "unmatched", ~U[2026-01-04 00:00:00.000000Z])

    assert {:ok, %{entries: [first, second], total: 3, next_offset: 2}} =
             Inventory.memories(%{}, q: "shared", limit: 2)

    assert [first.id, second.id] == [newest.id, middle.id]

    assert {:ok, %{entries: [last], total: 3, next_offset: nil}} =
             Inventory.memories(%{}, q: "shared", limit: 2, offset: 2)

    assert last.id == older.id
    assert {:ok, identity} = Inventory.identity(:memory, newest.id)
    assert identity.memory_space_id == b.memory_space_id
    assert identity.host_id == b.host_id

    assert {:ok, %{entries: [oldest, next], total: 3}} =
             Inventory.memories(%{}, q: "shared", sort: "oldest", limit: 2)

    assert [oldest.id, next.id] == [older.id, middle.id]
  end

  test "optional source and repository predicates apply before pagination and count" do
    a = canonical_partition("inventory-source-a")
    b = canonical_partition("inventory-source-b")
    one = memory(a, "source one", ~U[2026-01-01 00:00:00.000000Z], "github.com/example/one")
    memory(b, "source two", ~U[2026-01-02 00:00:00.000000Z], "github.com/example/two")
    memory(a, "legacy unknown repository", ~U[2026-01-03 00:00:00.000000Z])

    assert {:ok, %{entries: [found], total: 1}} =
             Inventory.memories(%{repository: "github.com/example/one"}, limit: 1)

    assert found.id == one.id
    assert {:ok, %{total: 2}} = Inventory.memories(%{host_id: a.host_id})

    assert {:ok, %{total: 1}} =
             Inventory.memories(Map.take(b, [:memory_space_id, :scope, :namespace]))

    assert {:ok, %{entries: [], total: 0}} = Inventory.memories(%{host_id: "missing"})
  end

  test "empty unregistered installations are a successful bounded inventory" do
    assert {:ok, %{entries: [], total: 0, next_offset: nil}} = Inventory.memories(%{})
    assert {:error, :invalid_options} = Inventory.memories(%{}, limit: 101)
    assert {:error, :not_found} = Inventory.identity(:memory, "invalid")
  end

  test "audit target predicates and counts precede global pagination" do
    a = canonical_partition("inventory-audit-a")
    b = canonical_partition("inventory-audit-b")
    id = Ecto.UUID.generate()

    Backplane.Memory.Audit.log(
      "remember",
      "operator",
      %{memory_id: id},
      Map.new(a, fn {k, v} -> {to_string(k), v} end)
    )

    Backplane.Memory.Audit.log(
      "remember",
      "operator",
      [Ecto.UUID.generate()],
      Map.new(b, fn {k, v} -> {to_string(k), v} end)
    )

    assert {:ok, %{entries: [row], total: 1}} = Inventory.audit(%{}, target: id, limit: 1)
    assert row.actor == "operator"
    assert {:ok, %{total: 1}} = Inventory.audit(%{host_id: a.host_id})
    assert {:ok, %{entries: [], total: 1}} = Inventory.audit(%{}, target: id, offset: 1)
  end

  test "audit can hide only confirmed empty system cleanup runs before counting and paging" do
    partition = canonical_partition("inventory-audit-empty-purges")
    foreign = canonical_partition("inventory-audit-foreign-purges")
    empty = %{daily_deleted: 0, contributions_deleted: 0}

    entries = [
      {"empty", "memory.activity.purge", "system", empty},
      {"daily", "memory.activity.purge", "system", %{empty | daily_deleted: 1}},
      {"contributions", "memory.activity.purge", "system", %{empty | contributions_deleted: 1}},
      {"unknown", "memory.activity.purge", "system", %{daily_deleted: 0}},
      {"null", "memory.activity.purge", "system", %{empty | daily_deleted: nil}},
      {"text", "memory.activity.purge", "system",
       %{daily_deleted: "0", contributions_deleted: "0"}},
      {"operation", "remember", "system", empty},
      {"actor", "memory.activity.purge", "operator", empty}
    ]

    for {target, operation, actor, metadata} <- entries do
      Backplane.Memory.Audit.log(operation, actor, [target], Map.merge(partition, metadata))
    end

    repo().insert_all("memory_audit_log", [
      %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        operation: "memory.activity.purge",
        actor: nil,
        target_ids: ["legacy-actor"],
        metadata: Map.merge(partition, empty),
        created_at: DateTime.utc_now()
      }
    ])

    Backplane.Memory.Audit.log(
      "memory.activity.purge",
      "system",
      ["foreign"],
      Map.merge(foreign, empty)
    )

    filters = %{host_id: partition.host_id}

    assert {:ok, %{total: 9, empty_purge_count: 1}} = Inventory.audit(filters)

    assert {:ok, %{total: 8, empty_purge_count: 1, next_offset: 2}} =
             Inventory.audit(filters, include_empty_runs: false, limit: 2)

    visible_targets =
      for offset <- [0, 2, 4, 6],
          {:ok, page} =
            Inventory.audit(filters, include_empty_runs: false, limit: 2, offset: offset),
          row <- page.entries,
          do: hd(row.target_ids)

    assert Enum.sort(visible_targets) ==
             Enum.sort(~w(daily contributions unknown null text operation actor legacy-actor))

    assert {:ok, %{total: 1, empty_purge_count: 0}} =
             Inventory.audit(filters, include_empty_runs: false, operation: "remember")

    assert {:ok, %{total: 1, empty_purge_count: 0}} =
             Inventory.audit(filters, include_empty_runs: false, target: "actor")
  end

  test "repository filtering follows profile source IDs rather than unrelated equal project paths" do
    alias Backplane.Memory.Profiles.Profile
    partition = canonical_partition("inventory-profile")

    source =
      memory(partition, "recorded source", ~U[2026-01-01 00:00:00.000000Z], "git.example/one")

    unrelated =
      memory(
        partition,
        "same path different source",
        ~U[2026-01-02 00:00:00.000000Z],
        "git.example/two"
      )

    for record <- [source, unrelated] do
      record
      |> Ecto.Changeset.change(metadata: Map.put(record.metadata, "project", "/same/path"))
      |> repo().update!()
    end

    profile =
      %Profile{}
      |> Profile.changeset(
        Map.merge(partition, %{
          project: "/same/path",
          updated_at: DateTime.utc_now(),
          source_records: %{"memory_ids" => [source.id]}
        })
      )
      |> repo().insert!()

    assert {:ok, %{entries: [found], total: 1}} =
             Inventory.profiles(%{repository: "git.example/one"})

    assert found.id == profile.id
    assert {:ok, %{entries: [], total: 0}} = Inventory.profiles(%{repository: "git.example/two"})
  end

  test "processing states use global count and SQL pagination without source selection" do
    alias Backplane.Memory.Projections.State
    partition = canonical_partition("inventory-stages")

    for index <- 1..51 do
      %State{}
      |> State.changeset(
        Map.merge(partition, %{
          projector: "test",
          subject_type: "memory",
          subject_id: "inventory-state-#{index}",
          processing_version: "1",
          status: "pending"
        })
      )
      |> repo().insert!()
    end

    assert {:ok, %{entries: rows, total: 51, next_offset: 50}} = Inventory.stages(%{})
    assert length(rows) == 50
    assert {:ok, %{entries: [_], total: 51, next_offset: nil}} = Inventory.stages(%{}, offset: 50)
  end

  test "activity starts at the first matching event date across years and retains gaps within bounds" do
    partition = canonical_partition("inventory-activity-dates")
    activity(partition, ~D[2025-12-28], 10)
    activity(partition, ~D[2025-12-29], 0)
    activity(partition, ~D[2025-12-31], 2)
    activity(partition, ~D[2026-01-02], 3)
    activity(partition, ~D[2026-01-05], 20)

    assert {:ok, report} =
             Inventory.activity(%{}, date_from: ~D[2025-12-29], date_to: ~D[2026-01-04])

    assert Enum.map(report.heatmap, & &1.date) ==
             Enum.to_list(Date.range(~D[2025-12-31], ~D[2026-01-04]))

    assert Enum.map(report.trends, & &1.event_count) == [2, 0, 3, 0, 0]
    assert report.heatmap == report.trends
    assert report.summary.date_from == ~D[2025-12-31]
    assert report.summary.date_to == ~D[2026-01-04]
    assert report.summary.event_count == 5
  end

  test "activity starts at the first date matching source and content filters" do
    partition = canonical_partition("inventory-activity-filters")
    foreign = canonical_partition("inventory-activity-foreign")
    activity(foreign, ~D[2026-06-01], 10)
    activity(partition, ~D[2026-06-02], 10, %{project: "other-project"})
    activity(partition, ~D[2026-06-03], 10, %{agent_id: "other-agent"})
    activity(partition, ~D[2026-06-04], 10, %{event_type: "task.completed"})
    activity(partition, ~D[2026-06-06], 1)

    assert {:ok, report} =
             Inventory.activity(%{host_id: partition.host_id},
               date_from: ~D[2026-06-01],
               date_to: ~D[2026-06-08],
               project: "inventory-project",
               agent_id: "inventory-agent",
               event_type: "memory.created"
             )

    assert report.summary.date_from == ~D[2026-06-06]
    assert report.summary.event_count == 1
    assert Enum.map(report.trends, & &1.event_count) == [1, 0, 0]
    assert [%{key: "inventory-project", event_count: 1}] = report.project_breakdown
  end

  test "activity without positive event contributions has no artificial date range" do
    opts = [date_from: ~D[2026-06-01], date_to: ~D[2026-06-08]]
    assert {:ok, empty} = Inventory.activity(%{}, opts)
    assert empty.heatmap == []
    assert empty.trends == []
    assert empty.summary.date_from == nil
    assert empty.summary.date_to == ~D[2026-06-08]
    assert empty.summary.event_count == 0

    activity(canonical_partition("inventory-activity-zero"), ~D[2026-06-01], 0)
    assert {:ok, zero} = Inventory.activity(%{}, opts)
    assert zero.heatmap == []
    assert zero.trends == []
    assert zero.summary.date_from == nil
    assert zero.summary.event_count == 0
  end

  defp activity(partition, date, count, overrides \\ %{}) do
    now = DateTime.utc_now()

    attrs =
      Map.merge(partition, %{
        date: date,
        subject_id: Ecto.UUID.generate(),
        project: "inventory-project",
        agent_id: "inventory-agent",
        event_type: "memory.created",
        event_count: count,
        session_count: 1,
        memory_count: count,
        lesson_count: 0,
        crystal_count: 0,
        recall_count: 0,
        action_count: 0,
        error_count: 0,
        processing_version: "activity-v1",
        input_revision: "revision",
        inserted_at: now,
        updated_at: now
      })

    repo().insert_all(ActivityContribution, [Map.merge(attrs, overrides)])
  end

  defp memory(partition, content, at, repository \\ nil) do
    metadata =
      if repository, do: %{"repository_sources" => [%{"repository_id" => repository}]}, else: %{}

    %Memory{}
    |> Memory.changeset(
      Map.merge(partition, %{
        content: content,
        memory_type: "semantic",
        agent_id: "inventory-test",
        metadata: metadata
      })
    )
    |> Ecto.Changeset.put_change(:inserted_at, at)
    |> repo().insert!()
  end
end
