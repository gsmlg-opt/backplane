defmodule Backplane.Memory.Projections.ActivityStoreTest do
  use Backplane.Memory.DataCase, async: false

  import Ecto.Query
  alias Backplane.Memory.Events.Store

  alias Backplane.Memory.Projections.{
    ActivityContribution,
    ActivityDaily,
    ActivityStore,
    Rebuild
  }

  test "rebuild is direct-event equivalent and retry idempotent" do
    suffix = unique()
    host = "activity-host-#{suffix}"
    session = "activity-session-#{suffix}"
    project = "activity-project-#{suffix}"

    append!(
      event(host, session, project, 1, "agent.session.started", "2026-01-02T01:00:00.000000Z")
    )

    append!(event(host, session, project, 2, "memory.recalled", "2026-01-02T01:01:00.000000Z"))
    append!(event(host, session, project, 3, "agent.tool.failed", "2026-01-02T01:02:00.000000Z"))

    assert {:ok, first} = Rebuild.session(host, session)
    assert {:ok, second} = Rebuild.session(host, session)
    assert first.input_revision == second.input_revision

    rows = activity(project)
    assert Enum.sum(Enum.map(rows, & &1.event_count)) == 3
    assert Enum.sum(Enum.map(rows, & &1.session_count)) == 3
    assert Enum.sum(Enum.map(rows, & &1.recall_count)) == 1
    assert Enum.sum(Enum.map(rows, & &1.error_count)) == 1

    assert repo().aggregate(
             from(c in ActivityContribution, where: c.subject_id == ^first.subject_id),
             :count
           ) == 3
  end

  test "revision replacement removes obsolete keys and moves all counters atomically" do
    subject = "activity-subject-#{unique()}"
    partition = canonical_partition("host", client_id: "client", scope: "scope")
    initial = [row("2026-02-01", "old", "memory.recalled", 2, %{recall_count: 2})]
    moved = [row("2026-02-02", "new", "task.completed", 3, %{action_count: 3})]

    assert {:ok, :ok} =
             repo().transaction(fn ->
               ActivityStore.replace_subject!(subject, "r1", partition, initial)
             end)

    assert [%ActivityDaily{project: "old", recall_count: 2}] = activity("old")

    assert {:ok, :ok} =
             repo().transaction(fn ->
               ActivityStore.replace_subject!(subject, "r2", partition, moved)
             end)

    assert activity("old") == []

    assert [%ActivityDaily{date: ~D[2026-02-02], project: "new", action_count: 3}] =
             activity("new")

    assert {:error, :rollback} =
             repo().transaction(fn ->
               ActivityStore.replace_subject!(subject, "r3", partition, initial)
               repo().rollback(:rollback)
             end)

    assert activity("old") == []
    assert [%ActivityDaily{project: "new", action_count: 3}] = activity("new")
  end

  test "concurrent different subjects sharing an aggregate key never lose or double count" do
    suffix = unique()
    host = "activity-shared-host-#{suffix}"
    project = "activity-shared-project-#{suffix}"

    for {session, sequence} <- [{"a-#{suffix}", 1}, {"b-#{suffix}", 1}] do
      append!(
        event(host, session, project, sequence, "memory.recalled", "2026-03-01T01:00:00.000000Z")
      )
    end

    assert [result_a, result_b] =
             ["a-#{suffix}", "b-#{suffix}"]
             |> Enum.map(&Task.async(fn -> Rebuild.session(host, &1) end))
             |> Task.await_many(10_000)

    assert match?({:ok, _}, result_a)
    assert match?({:ok, _}, result_b)
    assert [%ActivityDaily{event_count: 2, session_count: 2, recall_count: 2}] = activity(project)
  end

  test "namespace remains an aggregate partition" do
    suffix = unique()
    host = "activity-partition-host-#{suffix}"
    project = "activity-partition-project-#{suffix}"

    for namespace <- ["private", "team"] do
      session = "#{namespace}-#{suffix}"

      append!(
        event(host, session, project, 1, "memory.recalled", "2026-04-01T01:00:00.000000Z")
        |> Map.put(:namespace, namespace)
      )

      assert {:ok, _result} = Rebuild.session(host, session)
    end

    assert [private, team] = activity(project)
    assert MapSet.new([private.namespace, team.namespace]) == MapSet.new(["private", "team"])
    assert private.event_count == 1
    assert team.event_count == 1
  end

  test "canonical memory spaces remain separate when legacy dimensions collide" do
    project = "activity-space-isolation-#{unique()}"
    shared_row = row("2026-05-01", project, "memory.recalled", 1, %{recall_count: 1})
    partition_a = canonical_partition("space-a", client_id: "client", scope: "scope")
    partition_b = canonical_partition("space-b", client_id: "client", scope: "scope")

    for {subject, partition} <- [{"subject-a", partition_a}, {"subject-b", partition_b}] do
      assert {:ok, :ok} =
               repo().transaction(fn ->
                 ActivityStore.replace_subject!("#{subject}-#{project}", "r1", partition, [
                   shared_row
                 ])
               end)
    end

    assert rows = activity(project)
    assert length(rows) == 2

    assert MapSet.new(Enum.map(rows, & &1.memory_space_id)) ==
             MapSet.new([partition_a.memory_space_id, partition_b.memory_space_id])

    assert Enum.all?(rows, &(&1.event_count == 1))
  end

  defp row(date, project, event_type, count, overrides) do
    Map.merge(
      %{
        "date" => date,
        "project" => project,
        "agent_id" => "agent",
        "host_id" => "host",
        "client_id" => "client",
        "scope" => "scope",
        "namespace" => "private",
        "event_type" => event_type,
        "event_count" => count,
        "session_count" => count,
        "memory_count" => 0,
        "lesson_count" => 0,
        "crystal_count" => 0,
        "recall_count" => 0,
        "action_count" => 0,
        "error_count" => 0
      },
      Map.new(overrides, fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end

  defp event(host, session, project, sequence, event_type, occurred_at) do
    memory_space_id = Backplane.Memory.IngestFixtures.ensure_memory_space!(host)

    %{
      id: Ecto.UUID.generate(),
      stream_id: "capture:#{host}:#{session}",
      memory_space_id: memory_space_id,
      host_id: host,
      client_id: "client-activity",
      source_client_id: "client-activity",
      scope: "scope:activity",
      namespace: "private",
      session_id: session,
      project: project,
      agent_id: "agent-activity",
      source_sequence: sequence,
      event_type: event_type,
      occurred_at: occurred_at,
      idempotency_key: "#{host}:#{session}:#{sequence}:#{event_type}",
      payload: %{},
      payload_hash: "sha256:#{sequence}",
      schema_version: 1
    }
  end

  defp append!(event) do
    assert {:ok, {:inserted, _stored}} = Store.append_tagged(event)
  end

  defp activity(project) do
    repo().all(
      from(a in ActivityDaily,
        where: a.project == ^project,
        order_by: [asc: a.namespace, asc: a.date, asc: a.event_type]
      )
    )
  end

  defp unique, do: System.unique_integer([:positive]) |> Integer.to_string()
end
