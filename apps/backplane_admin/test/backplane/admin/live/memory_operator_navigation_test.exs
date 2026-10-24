defmodule Backplane.Admin.MemoryOperatorNavigationTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Admin.MemoryFixtures
  alias Backplane.Memory.Coordination.Action
  alias Backplane.Memory.Graph.Node
  alias Backplane.Memory.Profiles.Profile
  alias Backplane.Memory.Projections.{Snapshot, State}

  setup do
    partition = MemoryFixtures.canonical_event_attrs(%{host_id: "operator-navigation-host"})

    %{
      partition:
        Map.take(partition, [
          :memory_space_id,
          :host_id,
          :client_id,
          :source_client_id,
          :scope,
          :namespace
        ])
    }
  end

  test "profile inventory distinguishes selection, missing selection, and an empty inventory", %{
    conn: conn,
    partition: partition
  } do
    profile = profile_fixture(partition)
    path = scoped_path("profile", partition)
    {:ok, view, _} = live(conn, path)

    assert has_element?(view, "#memory-profiles-table", profile.project)
    assert has_element?(view, "#profile-select")
    refute has_element?(view, "#profile-pending")

    render_patch(view, path <> "&profile=" <> profile.id)
    assert has_element?(view, "#profile-complete", profile.summary)
    refute has_element?(view, "#profile-select")

    render_patch(view, path <> "&profile=" <> Ecto.UUID.generate())
    assert has_element?(view, "#profile-missing")
    refute has_element?(view, "#profile-complete")
    refute has_element?(view, "#profile-pending")

    render_patch(view, "/memory/profile?host=empty-profile-host")
    assert has_element?(view, "#profile-pending")
    refute has_element?(view, "#profile-missing")
  end

  test "session pagination retains the session and source filters", %{
    conn: conn,
    partition: partition
  } do
    for index <- 1..26, do: session_fixture(partition, "shared-session", index)
    session_fixture(partition, "unrelated-session", 27)
    path = scoped_path("sessions", partition) <> "&session=shared-session"
    {:ok, view, _} = live(conn, path)
    assert has_element?(view, "#sessions-count", "26 matching sessions")
    refute has_element?(view, "#memory-sessions-table", "unrelated-session")

    [next_path] =
      view
      |> element("#sessions-next")
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute("a", "href")

    assert URI.decode_query(URI.parse(next_path).query)["session"] == "shared-session"
    assert URI.decode_query(URI.parse(next_path).query)["host"] == partition.host_id
    view |> element("#sessions-next") |> render_click()
    assert has_element?(view, "#sessions-count", "26 matching sessions")
    assert has_element?(view, "#sessions-previous")
    refute has_element?(view, "#sessions-next")
    refute has_element?(view, "#memory-sessions-table", "unrelated-session")
  end

  test "action pagination can return from the second page", %{conn: conn, partition: partition} do
    for index <- 1..26 do
      %Action{}
      |> Action.changeset(Map.merge(partition, %{title: "Navigation action #{index}"}))
      |> Backplane.Repo.insert!()
    end

    {:ok, view, _} = live(conn, scoped_path("actions", partition))
    view |> element("#actions-next") |> render_click()
    assert has_element?(view, "#actions-previous")
    refute has_element?(view, "#actions-next")
    view |> element("#actions-previous") |> render_click()
    assert has_element?(view, "#actions-next")
    refute has_element?(view, "#actions-previous")
  end

  test "failed inventory patches clear previous data and pagination and recover", %{
    conn: conn,
    partition: partition
  } do
    profile = profile_fixture(partition)
    session_fixture(partition, "stale-session", 1)

    %Node{}
    |> Node.changeset(Map.merge(partition, %{name: "Stale concept", type: "Concept"}))
    |> Backplane.Repo.insert!()

    %Action{}
    |> Action.changeset(Map.merge(partition, %{title: "Stale action"}))
    |> Backplane.Repo.insert!()

    assert :ok = Backplane.Memory.Audit.log("memory.repair", "stale-audit-actor", %{}, partition)

    pages = [
      {"sessions", "sessions-error", "memory-sessions-table", scoped_path("sessions", partition)},
      {"profile", "profile-error", "profile-complete",
       scoped_path("profile", partition) <> "&profile=" <> profile.id},
      {"graph", "graph-error", "graph-node-counts", scoped_path("graph", partition)},
      {"actions", "actions-error", "memory-actions-table", scoped_path("actions", partition)},
      {"audit", "audit-error", "memory-audit-table", "/memory/audit?actor=stale-audit-actor"}
    ]

    views =
      for {page, error_id, data_id, path} <- pages do
        {:ok, view, _} = live(recycle(conn), path)
        assert has_element?(view, "##{data_id}")
        {view, page, error_id, data_id, path}
      end

    original_repo = Application.fetch_env!(:backplane_memory, :repo)
    MemoryFixtures.fail_memory_reads!()

    for {view, page, error_id, data_id, path} <- views do
      render_patch(view, path <> "&offset=25")
      assert has_element?(view, "##{error_id}")
      refute has_element?(view, "##{data_id}")
      refute has_element?(view, "##{page}-next")
      refute has_element?(view, "##{page}-previous")
      count_id = if page == "profile", do: "profiles-count", else: "#{page}-count"
      refute has_element?(view, "##{count_id}")
      refute has_element?(view, "#memory-profiles-table")
    end

    Application.put_env(:backplane_memory, :repo, original_repo)

    for {view, _page, error_id, data_id, path} <- views do
      render_patch(view, path)
      refute has_element?(view, "##{error_id}")
      assert has_element?(view, "##{data_id}")
    end
  end

  defp profile_fixture(partition) do
    %Profile{}
    |> Profile.changeset(
      Map.merge(partition, %{
        project: "Navigation profile",
        summary: "Completed project profile",
        updated_at: DateTime.utc_now()
      })
    )
    |> Backplane.Repo.insert!()
  end

  defp session_fixture(partition, session, index) do
    attrs =
      Map.merge(partition, %{
        projector: "session",
        subject_type: "captured_session",
        subject_id: "navigation-session-#{index}",
        input_revision: String.duplicate("a", 64),
        output_revision: String.duplicate("b", 64)
      })

    read_model = %{
      host_id: partition.host_id,
      client_id: "navigation-client-#{index}",
      scope: partition.scope,
      namespace: partition.namespace,
      session_id: session,
      status: "completed",
      started_at: "2026-10-24T00:00:00Z"
    }

    %Snapshot{}
    |> Snapshot.changeset(Map.put(attrs, :read_model, read_model))
    |> Backplane.Repo.insert!()

    %State{}
    |> State.changeset(Map.merge(attrs, %{processing_version: "session-v1", status: "complete"}))
    |> Backplane.Repo.insert!()
  end

  defp scoped_path(page, partition) do
    query =
      partition
      |> Map.take([:memory_space_id, :host_id, :scope, :namespace])
      |> Map.new(fn
        {:host_id, value} -> {"host", value}
        {key, value} -> {to_string(key), value}
      end)
      |> URI.encode_query()

    "/memory/#{page}?#{query}"
  end
end
