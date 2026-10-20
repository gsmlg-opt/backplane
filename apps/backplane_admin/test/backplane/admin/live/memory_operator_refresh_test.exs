defmodule Backplane.Admin.MemoryOperatorRefreshTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Memory.IngestFixtures
  alias Backplane.Memory.{Ingest, Graph}
  alias Backplane.Memory.Projections.Rebuild

  @partition %{
    "memory_space_id" => "20000000-0000-0000-0000-000000000041",
    "host" => "live-refresh-host",
    "client" => "host:live-refresh-host",
    "scope" => "refresh-scope",
    "namespace" => "private"
  }

  setup do
    %Backplane.MemorySpaces.MemorySpace{}
    |> Backplane.MemorySpaces.MemorySpace.changeset(%{
      id: @partition["memory_space_id"],
      kind: "private",
      status: "active"
    })
    |> Backplane.Repo.insert!()

    snapshot = :ets.tab2list(:backplane_settings)

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_settings)
      :ets.insert(:backplane_settings, snapshot)
    end)

    :ok
  end

  test "sidebar carries exact selection and session summary opens detail", %{conn: conn} do
    {:ok, view, _} = live(conn, "/memory/sessions?" <> URI.encode_query(@partition))
    html = view |> element("#admin-sidebar") |> render()
    assert html =~ "memory_space_id="
    assert html =~ "live-refresh-host"
  end

  test "stored graph remains inspectable when generation and model are disabled", %{conn: conn} do
    partition = atom_partition()

    assert {:ok, _node} =
             Graph.upsert_node(
               %{name: "Persisted acceptance concept", type: "Concept"},
               partition
             )

    :ets.insert(:backplane_settings, {"memory.pipeline.enabled", false})
    :ets.insert(:backplane_settings, {"memory.llm_model", nil})
    {:ok, view, _} = live(conn, "/memory/graph?" <> URI.encode_query(@partition))
    assert has_element?(view, "#graph-disabled")
    assert has_element?(view, "#graph-node-counts", "Concept")
  end

  test "refresh preserves exact session selection and lists a newly projected session", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/memory/sessions?" <> URI.encode_query(@partition))
    assert has_element?(view, "#sessions-empty")

    event =
      valid_event(%{
        "event_type" => "agent.session.started",
        "session_id" => "refresh-session",
        "host_id" => @partition["host"],
        "client_id" => @partition["client"],
        "scope" => @partition["scope"]
      })

    auth =
      ingest_auth_context(@partition["host"], %{
        partition: %{
          memory_space_id: @partition["memory_space_id"],
          scope: @partition["scope"],
          namespace: @partition["namespace"]
        }
      })

    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(
               auth,
               %{
                 "batch_id" => Ecto.UUID.generate(),
                 "host_id" => @partition["host"],
                 "events" => [event]
               }
             )

    assert {:ok, _} = Rebuild.session(@partition["host"], "refresh-session")
    send(view.pid, :refresh_memory_operator)
    assert render(view) =~ "refresh-session"
    assert has_element?(view, "a[href*='/memory/sessions/refresh-session?']")
  end

  test "missing lesson and crystal keep the selected partition and readable error", %{conn: conn} do
    for path <- ~w(lessons crystals) do
      for id <- [Ecto.UUID.generate(), "invalid-id"] do
        html =
          recycle(conn)
          |> get("/memory/#{path}/#{id}?" <> URI.encode_query(@partition))
          |> html_response(404)

        assert html =~ "memory-missing-detail"
        assert html =~ @partition["host"]
        assert html =~ "Return to Memory inventory"
      end
    end
  end

  defp atom_partition do
    %{
      memory_space_id: @partition["memory_space_id"],
      host_id: @partition["host"],
      client_id: @partition["client"],
      scope: @partition["scope"],
      namespace: @partition["namespace"]
    }
  end
end
