defmodule Backplane.Admin.MemoryCrystalsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Memory.{Audit, Crystals}
  alias Backplane.Memory.Coordination.Action
  alias Backplane.Memory.Crystals.SourceSummary
  alias Backplane.Memory.Projections.ProjectedSession
  alias Backplane.Memory.Summaries.Summary
  alias Backplane.MemorySpaces
  alias Backplane.Skills.Host

  setup do
    previous_llm = Application.get_env(:backplane_memory, :llm_client)
    Application.put_env(:backplane_memory, :llm_client, __MODULE__)
    partition = partition_fixture("crystals-ui")

    on_exit(fn ->
      if previous_llm,
        do: Application.put_env(:backplane_memory, :llm_client, previous_llm),
        else: Application.delete_env(:backplane_memory, :llm_client)
    end)

    %{partition: partition}
  end

  test "requires an exact partition and lists only its crystals", %{
    conn: conn,
    partition: partition
  } do
    {:ok, view, html} = live(conn, "/memory/crystals")
    assert html =~ "Select an exact partition"
    refute has_element?(view, "#memory-crystals-table")
    assert has_element?(view, "#crystal-memory-space[required]")

    crystal = crystal("Visible crystal", partition)
    _foreign = crystal("Foreign crystal", partition_fixture("other-crystal"))

    {:ok, view, html} = live(recycle(conn), crystal_path(partition))
    assert html =~ "Visible crystal"
    refute html =~ "Foreign crystal"
    assert has_element?(view, ~s(a[href^="/memory/crystals/#{crystal.id}?"]))

    for label <- ["Title", "Source", "Project", "State", "Model / Version", "Completed"] do
      assert has_element?(view, "#memory-crystals-table th", label)
    end
  end

  test "detail exposes structured output, provenance, versions, and audited rerun", %{
    conn: conn,
    partition: partition
  } do
    crystal = crystal("Crystal detail", partition)

    %{action_id: action_id, summary_id: summary_id, session_id: session_id} =
      attach_source_details(crystal, partition)

    {:ok, view, html} = live(conn, crystal_detail_path(crystal.id, partition))

    assert html =~ "Crystal detail"
    assert has_element?(view, "#crystal-outcomes", "Crystal detail")
    assert has_element?(view, "#crystal-decisions")
    assert has_element?(view, "#crystal-files")
    assert has_element?(view, "#crystal-unresolved")
    assert has_element?(view, "#crystal-evidence")
    assert has_element?(view, "#crystal-detail", "crystal-action-v1")
    assert has_element?(view, "#crystal-rerun")
    assert has_element?(view, ~s(a[href*="/sources/actions/#{action_id}"]))
    assert has_element?(view, ~s(a[href*="/sources/summaries/#{summary_id}"]))
    assert has_element?(view, ~s(a[href*="/sources/sessions/#{session_id}"]))

    for {kind, id, expected} <- [
          {"actions", action_id, "Crystal detail"},
          {"summaries", summary_id, "Summary source content"},
          {"sessions", session_id, session_id}
        ] do
      {:ok, source_view, source_html} =
        live(recycle(conn), source_detail_path(crystal.id, kind, id, partition))

      assert source_html =~ expected
      assert has_element?(source_view, "#crystal-source-detail")
    end

    view |> element("#crystal-rerun") |> render_click()
    assert render(view) =~ "queued or confirmed idempotently"

    assert [%{actor: "admin_ui:backplane_admin", target_ids: targets, metadata: metadata}] =
             Audit.list(partition, operation: "crystal.crystallize")

    assert targets["crystal_id"] == crystal.id
    assert metadata["source_kind"] == "action_chain"
    assert metadata["result"] == "complete"
    assert metadata["correlation_id"] == metadata["request_id"]
  end

  test "foreign partition detail is literal not found", %{conn: conn, partition: partition} do
    crystal = crystal("Private detail", partition)
    foreign = partition_fixture("foreign-crystal-detail")

    path =
      "/memory/crystals/#{crystal.id}?" <>
        URI.encode_query(%{
          "memory_space_id" => foreign.memory_space_id,
          "host" => foreign.host_id,
          "client" => foreign.client_id,
          "scope" => foreign.scope,
          "namespace" => foreign.namespace
        })

    assert conn |> get(path) |> response(404) == "not found"
  end

  test "source detail rejects an unlinked or foreign source", %{
    conn: conn,
    partition: partition
  } do
    crystal = crystal("Owned source", partition)
    foreign_partition = partition_fixture("foreign-crystal-source")
    foreign = crystal("Foreign source", foreign_partition)

    {:ok, %{source_action_ids: [foreign_action_id]}} =
      Crystals.get(foreign.id, foreign_partition)

    assert conn
           |> get(source_detail_path(crystal.id, "actions", foreign_action_id, partition))
           |> response(404) == "not found"

    foreign_partition_path =
      "/memory/crystals/#{crystal.id}/sources/actions/#{foreign_action_id}?" <>
        partition_query(foreign_partition)

    assert conn |> recycle() |> get(foreign_partition_path) |> response(404) == "not found"
  end

  defp crystal(title, partition) do
    {:ok, action} =
      Action.create(
        %{
          "title" => title,
          "description" => "#{title} narrative",
          "status" => "done",
          "created_by" => "ui-agent",
          "project" => "backplane"
        },
        [],
        partition
      )

    {:ok, crystal} = Crystals.build_action_chain(action.id, partition)
    crystal
  end

  defp attach_source_details(crystal, partition) do
    {:ok, %{source_action_ids: [action_id]}} = Crystals.get(crystal.id, partition)

    summary =
      Backplane.Repo.insert!(
        Summary.changeset(%Summary{}, %{
          session_id: crystal.source_session_id,
          project: "backplane",
          content: "Summary source content",
          subject_id: "crystal-ui-summary:#{crystal.id}",
          memory_space_id: partition.memory_space_id,
          host_id: partition.host_id,
          source_client_id: partition.source_client_id,
          scope: partition.scope,
          namespace: partition.namespace,
          agent_id: "ui-agent",
          processing_version: "summary-v1",
          input_revision: String.duplicate("a", 64),
          output_revision: String.duplicate("b", 64)
        })
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Backplane.Repo.insert_all(SourceSummary, [
      %{crystal_id: crystal.id, summary_id: summary.id, inserted_at: now}
    ])

    Backplane.Repo.insert!(%ProjectedSession{
      subject_id: "crystal-ui-session:#{crystal.id}",
      memory_space_id: partition.memory_space_id,
      host_id: partition.host_id,
      client_id: partition.client_id,
      source_client_id: partition.source_client_id,
      scope: partition.scope,
      namespace: partition.namespace,
      session_id: crystal.source_session_id,
      project: "backplane",
      agent_id: "ui-agent",
      status: "completed",
      started_at: now,
      ended_at: now,
      last_event_at: now,
      source_sequence_max: 1,
      gap_count: 0,
      processing_version: "session-v1",
      input_revision: String.duplicate("c", 64),
      inserted_at: now,
      updated_at: now
    })

    %{action_id: action_id, summary_id: summary.id, session_id: crystal.source_session_id}
  end

  defp crystal_path(partition), do: "/memory/crystals?#{partition_query(partition)}"

  defp crystal_detail_path(id, partition),
    do: "/memory/crystals/#{id}?#{partition_query(partition)}"

  defp source_detail_path(crystal_id, kind, source_id, partition),
    do:
      "/memory/crystals/#{crystal_id}/sources/#{kind}/#{source_id}?#{partition_query(partition)}"

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
