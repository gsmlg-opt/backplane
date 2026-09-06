defmodule Backplane.Admin.MemoryLessonsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Memory.{Audit, Lessons}
  alias Backplane.MemorySpaces
  alias Backplane.Skills.Host

  @audit %{
    actor: "fixture-agent",
    request_id: "lessons-ui-request",
    correlation_id: "lessons-ui-correlation"
  }

  setup do
    %{partition: partition_fixture("lessons-ui")}
  end

  test "requires an exact partition and renders bounded lesson fields", %{
    conn: conn,
    partition: partition
  } do
    {:ok, view, html} = live(conn, "/memory/lessons")
    assert html =~ "Select an exact partition"
    refute has_element?(view, "#memory-lessons-table")
    assert has_element?(view, "#lesson-memory-space[required]")

    {:ok, lesson} = active_lesson(partition, "Render lesson", "backplane")

    {:ok, _foreign} =
      active_lesson(partition_fixture("other-lessons"), "Foreign lesson", "backplane")

    {:ok, view, _html} =
      live(
        recycle(conn),
        lessons_path(partition, %{"status" => "active", "project" => "backplane"})
      )

    assert has_element?(view, "#memory-lessons-table")

    assert has_element?(
             view,
             ~s|a[href^="/memory/lessons/#{lesson.memory_id}?"]|,
             "Render lesson"
           )

    refute render(view) =~ "Foreign lesson"

    for label <- [
          "Rule",
          "State",
          "Confidence",
          "Reinforcement",
          "Contradictions",
          "Scope / Project",
          "Source",
          "Last use",
          "Evidence"
        ] do
      assert has_element?(view, "#memory-lessons-table th", label)
    end
  end

  test "filters and paginates without losing exact partition", %{
    conn: conn,
    partition: partition
  } do
    for index <- 1..26, do: active_lesson(partition, "Paged rule #{index}", "pagination")

    {:ok, view, _html} =
      live(conn, lessons_path(partition, %{"project" => "pagination", "per_page" => "25"}))

    assert has_element?(view, "#lessons-next-page")

    view
    |> form("#lesson-filters", filters: %{"status" => "active", "project" => " pagination "})
    |> render_change()

    patched = assert_patch(view)
    query = patched |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert Map.take(query, [
             "memory_space_id",
             "host",
             "client",
             "scope",
             "namespace",
             "status",
             "project"
           ]) == %{
             "memory_space_id" => partition.memory_space_id,
             "host" => partition.host_id,
             "client" => partition.client_id,
             "scope" => partition.scope,
             "namespace" => partition.namespace,
             "status" => "active",
             "project" => "pagination"
           }
  end

  test "detail exposes evidence and governed actions with audited actor and reason", %{
    conn: conn,
    partition: partition
  } do
    {:ok, candidate} = candidate_lesson(partition, "Governed UI lesson")
    path = lesson_path(candidate.memory_id, partition)

    {:ok, view, html} = live(conn, path)
    assert html =~ "Governed UI lesson"
    assert has_element?(view, "#lesson-evidence")
    assert has_element?(view, "#lesson-action-promote")

    view
    |> form("#lesson-action-form",
      governance: %{"action" => "promote", "reason" => "Reviewed by operator"}
    )
    |> render_submit()

    assert has_element?(view, "#lesson-state", "active")

    assert [%{actor: "admin_ui:backplane_admin", metadata: metadata}] =
             Audit.list(partition, operation: "lesson.transition")

    assert metadata["reason"] == "Reviewed by operator"

    view
    |> form("#lesson-action-form",
      governance: %{"action" => "archive", "reason" => "No longer applicable"}
    )
    |> render_submit()

    assert has_element?(view, "#lesson-state", "archived")
    assert has_element?(view, "#lesson-action-reactivate")
  end

  defp active_lesson(partition, rule, project) do
    Lessons.save(
      %{
        rule: rule,
        context: "LiveView lesson",
        project: project,
        session_id: "session-ui",
        idempotency_key: "lesson-ui-#{rule}"
      },
      partition,
      @audit
    )
  end

  defp candidate_lesson(partition, rule) do
    Lessons.create_candidate(
      %{
        rule: rule,
        context: "Governance candidate",
        project: "backplane",
        source_kind: "correction",
        confidence: 0.9,
        idempotency_key: "candidate-ui-#{rule}"
      },
      partition,
      @audit
    )
  end

  defp lessons_path(partition, extra) do
    query =
      %{
        "memory_space_id" => partition.memory_space_id,
        "host" => partition.host_id,
        "client" => partition.client_id,
        "scope" => partition.scope,
        "namespace" => partition.namespace
      }
      |> Map.merge(extra)
      |> URI.encode_query()

    "/memory/lessons?#{query}"
  end

  defp lesson_path(id, partition), do: "/memory/lessons/#{id}?#{partition_query(partition)}"

  defp partition_query(partition) do
    %{
      "memory_space_id" => partition.memory_space_id,
      "host" => partition.host_id,
      "client" => partition.client_id,
      "scope" => partition.scope,
      "namespace" => partition.namespace
    }
    |> URI.encode_query()
  end

  defp partition_fixture(prefix) do
    host =
      Backplane.Repo.insert!(
        Host.changeset(%Host{}, %{
          name: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}",
          memory_scope: "team"
        })
      )

    assert {:ok, canonical} = MemorySpaces.provision_private_host(host.id, host.memory_scope)
    source_client_id = "host:#{host.id}"

    Map.merge(canonical, %{
      host_id: host.id,
      client_id: source_client_id,
      source_client_id: source_client_id
    })
  end
end
