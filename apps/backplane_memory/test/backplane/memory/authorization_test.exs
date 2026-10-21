defmodule Backplane.Memory.AuthorizationTest do
  use Backplane.Memory.DataCase, async: false
  alias Backplane.{MemorySpaces, Repo}
  alias Backplane.Memory.{Authorization, Service}

  test "default capability changes cannot be bypassed through private aliases or direct remember" do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO skill_hosts(id,name,memory_scope,inserted_at,updated_at) VALUES($1,$2,'private_test',now(),now())",
      [Ecto.UUID.dump!(id), id]
    )

    {:ok, _} = MemorySpaces.provision_private_host(id, "private_test")

    auth = %{
      kind: :client_token,
      client_id: "isolated-client",
      scopes: ~w(memory.read memory.write),
      principal_metadata: %{"memory_partition_id" => "host:" <> id}
    }

    assert {:ok, _, _} = Authorization.authorize_tool("memory::remember", %{}, auth)
    {:ok, access} = MemorySpaces.resolve_host_access(id, :default, :read)
    operator = %{kind: :trusted_operator, ref: nil, request_id: Ecto.UUID.generate()}

    assert {:ok, _} =
             MemorySpaces.change_host_access(
               operator,
               access.access_id,
               1,
               %{capabilities: [:read]},
               "withdraw writes"
             )

    assert {:error, :unauthorized} = Authorization.authorize_tool("memory::remember", %{}, auth)

    assert {:error, :unauthorized} =
             Service.handle_remember(%{"content" => "cannot bypass", "agent_id" => "test"}, auth)

    assert {:ok, _, _} = Authorization.authorize_tool("memory::list", %{}, auth)
  end

  test "private caller cannot activate an explicit selector even for an otherwise valid tool" do
    assert {:error, :unauthorized} =
             Authorization.authorize_tool(
               "memory::list",
               %{"memory_access_id" => Ecto.UUID.generate()},
               %{kind: :open, client_id: nil, scopes: ["memory.read"]}
             )
  end
end
