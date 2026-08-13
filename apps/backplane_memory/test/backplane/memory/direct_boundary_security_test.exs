defmodule Backplane.Memory.DirectBoundarySecurityTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Memories, Service}
  alias Backplane.Skills.Hosts

  setup do
    previous = :ets.lookup(:backplane_settings, "memory.tools")
    :ets.insert(:backplane_settings, {"memory.tools", "all"})

    on_exit(fn ->
      :ets.delete(:backplane_settings, "memory.tools")
      if previous != [], do: :ets.insert(:backplane_settings, previous)
    end)

    :ok
  end

  test "direct Service handlers fail closed and authenticated calls cannot cross partitions" do
    host_a = create_host!("a", "shared-scope")
    host_b = create_host!("b", "shared-scope")
    auth_a = memory_auth(host_a)
    auth_b = memory_auth(host_b)

    assert {:ok, %{id: memory_a}} =
             Service.handle_remember(%{"content" => "only a", "agent_id" => "agent-a"}, auth_a)

    assert {:ok, %{id: memory_b}} =
             Service.handle_remember(%{"content" => "only b", "agent_id" => "agent-b"}, auth_b)

    for {function, args} <- [
          {:handle_list, %{}},
          {:handle_verify, %{"memory_id" => memory_a}},
          {:handle_enrich, %{"memory_id" => memory_a}},
          {:handle_access_log, %{"memory_id" => memory_a}},
          {:handle_apply,
           %{
             "memory_id" => memory_a,
             "application_id" => "application-a",
             "applied_by" => "agent-a"
           }},
          {:handle_forget, %{"id" => memory_a}},
          {:handle_team_share, %{"memory_id" => memory_a, "team_id" => "red"}},
          {:handle_team_feed, %{"team_id" => "red"}},
          {:handle_facet_tag, %{"memory_id" => memory_a, "facets" => []}},
          {:handle_facet_query, %{"facets" => []}}
        ] do
      assert {:error, :unauthorized} = apply(Service, function, [args])
    end

    assert {:ok, %{results: [%{id: ^memory_a}]}} = Service.handle_list(%{}, auth_a)
    assert {:ok, %{results: [%{id: ^memory_b}]}} = Service.handle_list(%{}, auth_b)

    assert {:error, :invalid_arguments} =
             Service.call("memory::list", %{"__trusted_internal__" => true}, auth_a)

    for {function, args} <- [
          {:handle_verify, %{"memory_id" => memory_b}},
          {:handle_enrich, %{"memory_id" => memory_b, "tags" => ["stolen"]}},
          {:handle_access_log, %{"memory_id" => memory_b}},
          {:handle_apply,
           %{
             "memory_id" => memory_b,
             "application_id" => "application-b",
             "applied_by" => "agent-a"
           }},
          {:handle_forget, %{"id" => memory_b}},
          {:handle_team_share, %{"memory_id" => memory_b, "team_id" => "red"}},
          {:handle_facet_tag,
           %{
             "memory_id" => memory_b,
             "facets" => [%{"dimension" => "topic", "value" => "stolen"}]
           }}
        ] do
      assert {:error, "memory not found"} = apply(Service, function, [args, auth_a])
    end

    assert {:ok, %{memory_id: ^memory_a, tags: ["owned"]}} =
             Service.handle_enrich(%{"memory_id" => memory_a, "tags" => ["owned"]}, auth_a)

    assert {:ok, %{id: ^memory_a}} =
             Service.handle_access_log(%{"memory_id" => memory_a}, auth_a)

    assert {:ok, %{namespace: "team:red"}} =
             Service.handle_team_share(%{"memory_id" => memory_a, "team_id" => "red"}, auth_a)

    assert {:ok, %{results: [%{id: ^memory_a}]}} =
             Service.handle_team_feed(%{"team_id" => "red"}, auth_a)

    assert {:ok, %{results: []}} = Service.handle_team_feed(%{"team_id" => "red"}, auth_b)
  end

  test "authenticated apply records an idempotent successful procedural use" do
    host = create_host!("apply", "apply-scope")
    auth = memory_auth(host)

    assert {:ok, %{id: memory_id}} =
             Service.handle_remember(
               %{
                 "content" => "Run the focused verification before completion",
                 "agent_id" => "author",
                 "type" => "procedural"
               },
               auth
             )

    args = %{
      "memory_id" => memory_id,
      "application_id" => "tool-run-42",
      "applied_by" => "executor"
    }

    assert {:ok, %{memory_id: ^memory_id, application_count: 1, applied: true}} =
             Service.handle_apply(args, auth)

    assert {:ok, %{memory_id: ^memory_id, application_count: 1, applied: false}} =
             Service.handle_apply(args, auth)

    assert {:ok, %{application_count: 1}} =
             Service.handle_access_log(%{"memory_id" => memory_id}, auth)

    assert {:ok, %{application_count: 1}} =
             Service.handle_verify(%{"memory_id" => memory_id}, auth)
  end

  test "lower Memories APIs require an exact host client scope namespace partition" do
    partition_a = partition("host-a", "client-a", "scope-a", "private")
    partition_b = partition("host-b", "client-b", "scope-a", "private")
    other_namespace = %{partition_a | namespace: "team:red"}

    {:ok, memory} =
      Memories.remember("partitioned lower API",
        type: "semantic",
        agent_id: "agent",
        host_id: partition_a.host_id,
        client_id: partition_a.client_id,
        scope: partition_a.scope,
        namespace: partition_a.namespace
      )

    assert {:error, :unauthorized} = Memories.get(memory.id)
    assert {:error, :unauthorized} = Memories.verify(memory.id)
    assert {:error, :unauthorized} = Memories.forget(memory.id)
    assert [] = Memories.list()
    assert {:error, :unauthorized} = Memories.team_share(memory.id, "red")
    assert [] = Memories.team_feed("red")

    assert {:ok, %{id: id}} = Memories.get(memory.id, partition_a)
    assert id == memory.id
    assert {:error, :not_found} = Memories.get(memory.id, partition_b)
    assert {:error, :not_found} = Memories.get(memory.id, other_namespace)
    assert [%{id: ^id}] = Memories.list([], partition_a)
    assert [] = Memories.list([], partition_b)
    assert [] = Memories.list([], other_namespace)
    assert {:error, :not_found} = Memories.verify(memory.id, partition_b)
    assert {:error, :not_found} = Memories.forget(memory.id, partition_b)
    assert {:ok, %{id: ^id}} = Memories.get(memory.id, partition_a)
  end

  defp create_host!(suffix, scope) do
    {:ok, host, _token, _plaintext} =
      Hosts.create_agent_with_token(%{
        "name" => "direct-boundary-#{suffix}-#{System.unique_integer([:positive])}",
        "memory_scope" => scope
      })

    host
  end

  defp memory_auth(host) do
    %{
      kind: :client_token,
      client_id: Ecto.UUID.generate(),
      scopes: ["memory::*"],
      principal_metadata: %{"memory_partition_id" => "host:#{host.id}"}
    }
  end

  defp partition(host_id, client_id, scope, namespace) do
    %{host_id: host_id, client_id: client_id, scope: scope, namespace: namespace}
  end
end
