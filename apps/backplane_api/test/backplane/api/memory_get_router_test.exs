defmodule Backplane.Api.MemoryGetRouterTest do
  use Backplane.Api.ConnCase, async: false

  alias Backplane.{Clients, MemorySpaces, Repo}
  alias Backplane.Memory.{Memories, Service}
  alias Backplane.Memory.Memories.Memory
  alias Backplane.Skills.Host

  setup do
    host =
      Repo.insert!(
        Host.changeset(%Host{}, %{
          name: "exact-rest-#{System.unique_integer([:positive])}",
          memory_scope: "exact_rest"
        })
      )

    {:ok, partition} = MemorySpaces.provision_private_host(host.id, host.memory_scope)

    {:ok, client, token} =
      Clients.issue_client(%{
        name: "exact REST client",
        scopes: ["memory.read"],
        active: true,
        metadata: %{"memory_partition_id" => "host:" <> host.id}
      })

    auth = %{
      kind: :client_token,
      client_id: client.id,
      scopes: ["memory.read"],
      principal_metadata: %{"memory_partition_id" => "host:" <> host.id}
    }

    %{host: host, partition: partition, token: token, auth: auth}
  end

  test "HTTP point reads use the same canonical Service result", c do
    memory =
      seed!(c, %{
        content: String.duplicate("complete REST record ", 100),
        metadata: %{"project" => "backplane"}
      })

    assert {:ok, canonical} =
             Service.call("memory::get", %{"id" => memory.id, "project" => "backplane"}, c.auth)

    conn =
      c.conn
      |> put_req_header("authorization", "Bearer #{c.token}")
      |> get("/api/memory/memories/#{memory.id}?project=backplane")

    assert json_response(conn, 200) == canonical |> Jason.encode!() |> Jason.decode!()
    assert json_response(conn, 200)["record"]["content"] == memory.content
  end

  test "project mismatch, expiry and deleted records return not_found", c do
    memory = seed!(c, %{metadata: %{"project" => "other"}})
    expired = seed!(c, %{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})
    deleted = seed!(c, %{deleted_at: DateTime.utc_now(), lifecycle_state: "tombstoned"})

    for path <- [
          "/api/memory/memories/#{memory.id}?project=backplane",
          "/api/memory/memories/#{expired.id}",
          "/api/memory/memories/#{deleted.id}"
        ] do
      conn = c.conn |> put_req_header("authorization", "Bearer #{c.token}") |> get(path)
      assert json_response(conn, 404) == %{"error" => "not_found"}
    end
  end

  test "unpublished filters are rejected and get rechecks deletion after discovery", c do
    memory = seed!(c)
    base = put_req_header(c.conn, "authorization", "Bearer #{c.token}")

    assert json_response(get(base, "/api/memory/memories/#{memory.id}?facets=ignored"), 400) == %{
             "error" => "invalid_arguments"
           }

    assert {:ok, _} = Service.call("memory::get", %{"id" => memory.id}, c.auth)
    assert :ok = Memories.forget(memory.id, c.partition)

    assert json_response(get(base, "/api/memory/memories/#{memory.id}"), 404) == %{
             "error" => "not_found"
           }
  end

  test "oversize canonical record returns payload_too_large without truncation", c do
    memory = seed!(c, %{content: String.duplicate("x", 524_288)})

    conn =
      c.conn
      |> put_req_header("authorization", "Bearer #{c.token}")
      |> get("/api/memory/memories/#{memory.id}")

    assert json_response(conn, 413) == %{"error" => "payload_too_large"}
  end

  defp seed!(c, attrs \\ %{}) do
    values =
      c.partition
      |> Map.merge(%{
        host_id: c.host.id,
        client_id: "host:" <> c.host.id,
        agent_id: "source-agent",
        content: "record #{Ecto.UUID.generate()}"
      })
      |> Map.merge(attrs)
      |> then(&Map.put(&1, :content_hash, :crypto.hash(:sha256, &1.content)))

    %Memory{} |> Ecto.Changeset.change(values) |> Repo.insert!()
  end
end
