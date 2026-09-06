defmodule Backplane.Memory.LessonsAdminTest do
  use Backplane.Memory.DataCase, async: true

  alias Backplane.Memory.Lessons

  @partition %{
    memory_space_id: "35c891b1-c374-d7b7-5cdf-3e0470362ba4",
    host_id: "lesson-admin-host",
    client_id: "lesson-admin-client",
    source_client_id: "lesson-admin-client",
    scope: "team",
    namespace: "private"
  }
  @audit %{
    actor: "admin_ui:backplane_admin",
    request_id: "lesson-admin-request",
    correlation_id: "lesson-admin-correlation"
  }

  setup do
    assert Backplane.Memory.IngestFixtures.ensure_memory_space!(@partition.host_id) ==
             @partition.memory_space_id

    :ok
  end

  test "list_admin is exact-partition, filterable, and bounded" do
    {:ok, first} = lesson_fixture("First admin rule", "alpha")
    {:ok, _second} = lesson_fixture("Second admin rule", "beta")

    {:ok, _foreign} = lesson_fixture("Foreign rule", "alpha", foreign_partition())

    assert {:ok, %{entries: [entry], page: 1, per_page: 1, total: 1, total_pages: 1}} =
             Lessons.list_admin(@partition,
               status: "active",
               project: "alpha",
               page: 1,
               per_page: 1
             )

    assert entry.lesson.memory_id == first.memory_id
    assert entry.memory.content == "First admin rule"
    assert entry.project == "alpha"
    assert is_list(entry.evidence)

    assert {:error, :unauthorized} = Lessons.list_admin(Map.delete(@partition, :namespace))
    assert {:error, :invalid_arguments} = Lessons.list_admin(@partition, per_page: 101)
  end

  test "get_admin returns source and evidence only inside the exact partition" do
    {:ok, lesson} = lesson_fixture("Inspect admin rule", "console")

    assert {:ok, detail} = Lessons.get_admin(lesson.memory_id, @partition)
    assert detail.lesson.memory_id == lesson.memory_id
    assert detail.memory.content == "Inspect admin rule"
    assert detail.project == "console"
    assert detail.source == "manual"
    assert [%{evidence_kind: "supports", session_id: "session-console"}] = detail.evidence

    assert {:error, :not_found} =
             Lessons.get_admin(lesson.memory_id, foreign_partition())
  end

  defp lesson_fixture(rule, project, partition \\ @partition) do
    Lessons.save(
      %{
        "rule" => rule,
        "context" => "Admin lesson context",
        "project" => project,
        "session_id" => "session-#{project}",
        "idempotency_key" => "admin-#{rule}"
      },
      partition,
      @audit
    )
  end

  defp foreign_partition do
    canonical_partition("other-lesson-admin-host",
      client_id: "other-client",
      scope: @partition.scope,
      namespace: @partition.namespace
    )
  end
end
