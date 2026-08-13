defmodule Backplane.Api.MemoryCrystalsRouterTest do
  use Backplane.Api.ConnCase, async: false

  alias Backplane.Clients
  alias Backplane.Memory.Audit
  alias Backplane.Memory.Coordination.Action
  alias Backplane.Skills.Host

  setup do
    previous_tools = :ets.lookup(:backplane_settings, "memory.tools")
    previous_llm = Application.get_env(:backplane_memory, :llm_client)
    :ets.insert(:backplane_settings, {"memory.tools", "all"})
    Application.put_env(:backplane_memory, :llm_client, __MODULE__)

    on_exit(fn ->
      :ets.delete(:backplane_settings, "memory.tools")
      if previous_tools != [], do: :ets.insert(:backplane_settings, previous_tools)

      if previous_llm,
        do: Application.put_env(:backplane_memory, :llm_client, previous_llm),
        else: Application.delete_env(:backplane_memory, :llm_client)
    end)

    {host, token, partition} = client_partition("crystal-rest", ["memory.read", "memory.admin"])
    %{host: host, token: token, partition: partition}
  end

  test "REST crystallize, get, list, and search share the canonical partition boundary", %{
    conn: conn,
    token: token,
    partition: partition
  } do
    assert {:ok, action} =
             Action.create(
               %{
                 "title" => "Verify crystal REST parity",
                 "status" => "done",
                 "created_by" => "rest-agent",
                 "project" => "backplane"
               },
               [],
               partition
             )

    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    created =
      post(conn, "/api/memory/crystals/crystallize", %{
        "source_kind" => "action_chain",
        "root_action_id" => action.id
      })

    assert %{"crystal_id" => crystal_id, "source_kind" => "action_chain"} =
             json_response(created, 200)

    assert %{"crystal_id" => ^crystal_id, "source_action_ids" => [action_id]} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get("/api/memory/crystals/#{crystal_id}")
             |> json_response(200)

    assert action_id == action.id

    assert %{"results" => [%{"crystal_id" => ^crystal_id}], "next_cursor" => nil} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get("/api/memory/crystals?limit=10")
             |> json_response(200)

    assert %{"results" => [%{"crystal_id" => ^crystal_id}]} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> post("/api/memory/crystals/search", %{"query" => "REST parity"})
             |> json_response(200)

    assert [%{metadata: %{"result" => "complete"}}] =
             Audit.list(partition, operation: "crystal.crystallize")
  end

  test "foreign partitions receive 404 and read-only clients cannot crystallize", %{
    conn: conn,
    token: token,
    partition: partition
  } do
    assert {:ok, action} =
             Action.create(
               %{"title" => "Private crystal", "status" => "done", "created_by" => "rest"},
               [],
               partition
             )

    authorized = put_req_header(conn, "authorization", "Bearer #{token}")

    assert %{"crystal_id" => crystal_id} =
             authorized
             |> post("/api/memory/crystals/crystallize", %{
               "source_kind" => "action_chain",
               "root_action_id" => action.id
             })
             |> json_response(200)

    {_foreign_host, foreign_token, _foreign_partition} =
      client_partition("crystal-rest-foreign", ["memory.read", "memory.admin"])

    foreign =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{foreign_token}")
      |> get("/api/memory/crystals/#{crystal_id}")

    assert %{"error" => "not found"} = json_response(foreign, 404)

    {_read_host, read_token, _read_partition} =
      client_partition("crystal-rest-read", ["memory.read"])

    forbidden =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{read_token}")
      |> post("/api/memory/crystals/crystallize", %{
        "source_kind" => "action_chain",
        "root_action_id" => action.id
      })

    assert %{"error" => "Forbidden"} = json_response(forbidden, 403)
  end

  defp client_partition(prefix, scopes) do
    host =
      Backplane.Repo.insert!(
        Host.changeset(%Host{}, %{
          name: "#{prefix}-#{System.unique_integer([:positive])}",
          memory_scope: "scope:#{prefix}"
        })
      )

    token = "#{prefix}-#{System.unique_integer([:positive])}"
    client_id = "host:#{host.id}"

    {:ok, _client} =
      Clients.create_client(%{
        name: "#{prefix} client",
        token: token,
        scopes: scopes,
        active: true,
        metadata: %{"memory_partition_id" => client_id}
      })

    partition = %{
      host_id: host.id,
      client_id: client_id,
      scope: host.memory_scope,
      namespace: "private"
    }

    {host, token, partition}
  end
end
