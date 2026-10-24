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

  test "detail precedes inventory and a failed refresh removes stale governance controls", %{
    conn: conn,
    partition: partition
  } do
    {:ok, lesson} = candidate_lesson(partition, "Stale governed lesson")
    path = lesson_path(lesson.memory_id, partition)
    {:ok, view, html} = live(conn, path)
    {detail_position, _} = :binary.match(html, "lesson-detail-title")
    {table_position, _} = :binary.match(html, "memory-lessons-table")
    assert detail_position < table_position
    assert has_element?(view, "#lesson-action-form")

    original_repo = Application.fetch_env!(:backplane_memory, :repo)
    Backplane.Admin.MemoryFixtures.fail_memory_reads!()
    send(view.pid, :refresh_memory_operator)
    assert has_element?(view, "#lesson-query-error")
    refute has_element?(view, "#lesson-action-form")
    refute has_element?(view, "#memory-lessons-table")
    refute render(view) =~ "Stale governed lesson"

    Application.put_env(:backplane_memory, :repo, original_repo)
    render_patch(view, path)
    assert has_element?(view, "#lesson-action-form")
    refute has_element?(view, "#lesson-query-error")
  end

  test "opens directly and supports optional legacy lesson filters", %{
    conn: conn,
    partition: partition
  } do
    {:ok, view, html} = live(conn, "/memory/lessons")
    refute html =~ "Select an exact partition"
    refute has_element?(view, "#memory-lessons-table")
    refute has_element?(view, "#memory-source-filters")

    {:ok, lesson} = active_lesson(partition, "Render lesson", "backplane")

    {:ok, _foreign} =
      active_lesson(partition_fixture("other-lessons"), "Foreign lesson", "backplane")

    render_patch(view, "/memory/lessons?status=invalid")
    assert has_element?(view, "#lesson-query-error")

    render_patch(view, "/memory/lessons")
    refute has_element?(view, "#lesson-query-error")
    assert has_element?(view, "#memory-lessons-table", "Render lesson")
    assert has_element?(view, "#memory-lessons-table", "Foreign lesson")

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
          "Source host / repository",
          "State",
          "Confidence",
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
    assert has_element?(view, "#lesson-row-state-#{candidate.memory_id}", "active")

    assert [%{actor: "admin_ui:backplane_admin", metadata: metadata}] =
             Audit.list(partition, operation: "lesson.transition")

    assert metadata["reason"] == "Reviewed by operator"

    assert [%{action: "memory_lesson.govern", target_id: target_id} = event] =
             Backplane.Admin.Audit.list()

    assert target_id == candidate.memory_id
    refute inspect(event) =~ "Reviewed by operator"

    view
    |> form("#lesson-action-form",
      governance: %{"action" => "archive", "reason" => "No longer applicable"}
    )
    |> render_submit()

    assert has_element?(view, "#lesson-state", "archived")
    assert has_element?(view, "#lesson-row-state-#{candidate.memory_id}", "archived")
    assert has_element?(view, "#lesson-action-reactivate")

    assert [%{action: "memory_lesson.govern"}, %{action: "memory_lesson.govern"}] =
             Backplane.Admin.Audit.list()
  end

  test "governance refreshes filtered inventory totals while retaining page and sources", %{
    conn: conn,
    partition: partition
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    [newest, selected, oldest] =
      for index <- 1..3 do
        {:ok, lesson} = active_lesson(partition, "Filtered rule #{index}", "filtered-project")

        lesson
        |> Ecto.Changeset.change(updated_at: DateTime.add(now, -index))
        |> Backplane.Repo.update!()
      end

    {:ok, _other_project} = active_lesson(partition, "Another project", "other-project")

    {:ok, _foreign} =
      active_lesson(partition_fixture("foreign-governance"), "Foreign rule", "filtered-project")

    query = %{
      "status" => "active",
      "project" => "filtered-project",
      "page" => "2",
      "per_page" => "1"
    }

    inventory_path = lessons_path(partition, query)
    detail_query = URI.parse(inventory_path).query

    {:ok, view, _html} =
      live(conn, "/memory/lessons/#{selected.memory_id}?" <> detail_query)

    assert has_element?(view, "#lesson-row-state-#{selected.memory_id}", "active")
    assert has_element?(view, "nav[aria-label='Lesson pagination']", "Page 2 of 3")

    view
    |> form("#lesson-action-form",
      governance: %{"action" => "archive", "reason" => "Retire filtered lesson"}
    )
    |> render_submit()

    assert has_element?(view, "#lesson-state", "archived")
    refute has_element?(view, "#lesson-row-state-#{selected.memory_id}")
    assert has_element?(view, "#lesson-row-state-#{oldest.memory_id}", "active")
    refute has_element?(view, "#lesson-row-state-#{newest.memory_id}")
    assert has_element?(view, "nav[aria-label='Lesson pagination']", "Page 2 of 2")
    refute has_element?(view, "#lessons-next-page")
    refute render(view) =~ "Another project"
    refute render(view) =~ "Foreign rule"

    view |> element("#lesson-close-detail") |> render_click()
    assert_patch(view, inventory_path)
    assert has_element?(view, "#lesson-row-state-#{oldest.memory_id}", "active")
  end

  test "a rejected governance change clears stale inventory and controls", %{
    conn: conn,
    partition: partition
  } do
    {:ok, lesson} = candidate_lesson(partition, "Concurrently changed rule")
    {:ok, view, _html} = live(conn, lesson_path(lesson.memory_id, partition))

    assert {:ok, _lesson} =
             Lessons.transition(
               lesson.memory_id,
               "archived",
               "Retired by another operator",
               Ecto.UUID.generate(),
               partition,
               @audit
             )

    view
    |> form("#lesson-action-form",
      governance: %{"action" => "promote", "reason" => "Submitted from stale detail"}
    )
    |> render_submit()

    assert has_element?(view, "#lesson-query-error")
    refute has_element?(view, "#lesson-action-form")
    refute has_element?(view, "#memory-lessons-table")
    refute has_element?(view, "#lesson-state")
  end

  @tag :provenance_navigation
  test "evidence links retain exact partition and target the session detail", %{
    conn: conn,
    partition: partition
  } do
    {:ok, lesson} = active_lesson(partition, "Provenance lesson", "backplane")

    event =
      Backplane.Admin.MemoryFixtures.event_fixture(
        Map.merge(partition, %{session_id: "session-ui"})
      )

    Backplane.Repo.insert!(%Backplane.Memory.Memories.Evidence{
      memory_id: lesson.memory_id,
      source_event_id: event.id,
      host_id: partition.host_id,
      session_id: "session-ui",
      evidence_kind: "derives",
      support_score: 1.0
    })

    {:ok, view, _} = live(conn, lesson_path(lesson.memory_id, partition))

    assert has_element?(
             view,
             ~s(#lesson-evidence a[href="/memory/events/#{event.id}?#{partition_query(partition)}"])
           )

    assert has_element?(
             view,
             ~s(#lesson-evidence a[href="/memory/sessions/session-ui?#{partition_query(partition)}"])
           )

    refute has_element?(view, ~s(#lesson-evidence a[href^="/memory/streams"]))
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
