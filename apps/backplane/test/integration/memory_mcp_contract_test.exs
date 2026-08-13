defmodule Backplane.Integration.MemoryMcpContractTest do
  use Backplane.ConnCase, async: false

  alias Backplane.Memory.Service
  alias Backplane.Memory.Facets.Facet
  alias Backplane.Memory.Memories
  alias Backplane.Memory.Memories.Memory, as: MemorySchema
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Repo
  alias Backplane.Skills.Hosts

  setup do
    tool_rows = :ets.tab2list(:backplane_tools)

    setting_rows =
      Map.new(["memory.tools", "services.memory.enabled"], fn key ->
        {key, :ets.lookup(:backplane_settings, key)}
      end)

    :ets.insert(:backplane_settings, {"memory.tools", "core"})
    :ets.insert(:backplane_settings, {"services.memory.enabled", false})
    ToolRegistry.deregister_managed(Service.prefix())
    ToolRegistry.register_managed(Service.prefix(), Service.tools())

    {:ok, host, _host_token, _plaintext} =
      Hosts.create_agent_with_token(%{
        "name" => "memory-mcp-contract-#{System.unique_integer([:positive])}",
        "memory_scope" => "global"
      })

    {_client, auth_token} =
      Backplane.Fixtures.insert_client(
        name: "memory-mcp-contract",
        scopes: ["memory::*"],
        metadata: %{"memory_partition_id" => "host:#{host.id}"}
      )

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_tools)
      :ets.insert(:backplane_tools, tool_rows)

      Enum.each(setting_rows, fn
        {key, []} -> :ets.delete(:backplane_settings, key)
        {_key, rows} -> :ets.insert(:backplane_settings, rows)
      end)
    end)

    %{auth_token: auth_token, host: host}
  end

  test "tools/list exposes the authenticated core catalog without caller ownership arguments", %{
    auth_token: auth_token
  } do
    response = mcp_request("tools/list", nil, auth_token: auth_token)

    memory_tools =
      response["result"]["tools"]
      |> Enum.filter(&String.starts_with?(&1["name"], "memory::"))

    expected_core_names = Service.tools() |> Enum.map(& &1.name) |> MapSet.new()
    assert memory_tools |> Enum.map(& &1["name"]) |> MapSet.new() == expected_core_names

    assert %{permission: "memory.write"} =
             Enum.find(Service.tools(), &(&1.name == "memory::apply"))

    assert %{
             "name" => "memory::apply",
             "inputSchema" => %{
               "required" => ["memory_id", "application_id", "applied_by"]
             }
           } = Enum.find(memory_tools, &(&1["name"] == "memory::apply"))

    assert %{
             "name" => "memory::remember",
             "inputSchema" => %{
               "type" => "object",
               "properties" => properties,
               "required" => ["content", "agent_id"],
               "additionalProperties" => false
             }
           } = Enum.find(memory_tools, &(&1["name"] == "memory::remember"))

    assert properties["type"]["default"] == "semantic"
    assert properties["scope"]["default"] == "global"

    for tool <- memory_tools do
      refute Map.has_key?(tool, "outputSchema")
      refute Map.has_key?(tool, "output_schema")
      refute Map.has_key?(tool, "structuredContent")
    end
  end

  test "memory::apply is hidden from read-only clients and callable by writers", %{
    host: host
  } do
    assert {:ok, memory} =
             Memories.remember("apply transport procedure",
               type: "procedural",
               scope: host.memory_scope,
               agent_id: "contract-agent",
               host_id: host.id,
               client_id: "host:#{host.id}",
               namespace: "private"
             )

    {_reader, read_token} =
      Backplane.Fixtures.insert_client(
        name: "memory-apply-reader",
        scopes: ["memory.read"],
        metadata: %{"memory_partition_id" => "host:#{host.id}"}
      )

    {_writer, write_token} =
      Backplane.Fixtures.insert_client(
        name: "memory-apply-writer",
        scopes: ["memory.write"],
        metadata: %{"memory_partition_id" => "host:#{host.id}"}
      )

    read_names =
      mcp_request("tools/list", nil, auth_token: read_token)["result"]["tools"]
      |> Enum.map(& &1["name"])

    refute "memory::apply" in read_names

    denied =
      mcp_request(
        "tools/call",
        %{
          "name" => "memory::apply",
          "arguments" => %{
            "memory_id" => memory.id,
            "application_id" => "transport-application",
            "applied_by" => "contract-agent"
          }
        },
        auth_token: read_token
      )

    assert %{"error" => %{"code" => -32_001}} = denied

    allowed =
      mcp_request(
        "tools/call",
        %{
          "name" => "memory::apply",
          "arguments" => %{
            "memory_id" => memory.id,
            "application_id" => "transport-application",
            "applied_by" => "contract-agent"
          }
        },
        auth_token: write_token
      )

    assert %{"result" => %{"content" => [%{"text" => encoded}]}} = allowed

    assert %{
             "application_count" => 1,
             "applied" => true,
             "memory_id" => applied_memory_id
           } = Jason.decode!(encoded)

    assert applied_memory_id == memory.id
  end

  test "M14 compatibility derives host ownership from authenticated client metadata", %{
    auth_token: auth_token,
    host: host
  } do
    refute Service.enabled?()

    response =
      mcp_request(
        "tools/call",
        %{
          "name" => "memory::remember",
          "arguments" => %{
            "content" => "transport contract",
            "agent_id" => "contract-agent"
          }
        },
        auth_token: auth_token
      )

    assert %{
             "result" =>
               %{
                 "content" => [%{"type" => "text", "text" => encoded}]
               } = result
           } = response

    refute Map.has_key?(result, "isError")
    refute Map.has_key?(result, "structuredContent")

    assert {:ok, %{"id" => id, "scope" => "global", "memory_type" => "semantic"}} =
             Jason.decode(encoded)

    assert is_binary(id)

    assert %MemorySchema{
             id: ^id,
             host_id: host_id,
             client_id: partition_id,
             namespace: "private",
             scope: "global"
           } = Repo.get!(MemorySchema, id)

    assert host_id == host.id
    assert partition_id == "host:#{host.id}"
  end

  test "authenticated remember persists facets in the derived host partition", %{
    auth_token: auth_token,
    host: host
  } do
    response =
      mcp_request(
        "tools/call",
        %{
          "name" => "memory::remember",
          "arguments" => %{
            "content" => "faceted transport contract",
            "agent_id" => "contract-agent",
            "facets" => [%{"dimension" => "project", "value" => "backplane"}]
          }
        },
        auth_token: auth_token
      )

    assert %{"result" => %{"content" => [%{"text" => encoded}]}} = response
    assert {:ok, %{"id" => id}} = Jason.decode(encoded)

    assert %MemorySchema{host_id: host_id, client_id: partition_id} = Repo.get!(MemorySchema, id)
    assert host_id == host.id
    assert partition_id == "host:#{host.id}"

    assert %Facet{memory_id: ^id, dimension: "project", value: "backplane"} =
             Repo.one!(Facet)
  end

  test "tools/call still validates genuinely required Memory arguments", %{
    auth_token: auth_token
  } do
    for arguments <- [
          %{"agent_id" => "contract-agent"},
          %{"content" => "missing agent"}
        ] do
      response =
        mcp_request(
          "tools/call",
          %{"name" => "memory::remember", "arguments" => arguments},
          auth_token: auth_token
        )

      assert %{"error" => %{"code" => -32_602, "message" => message}} = response
      assert message =~ "Missing required arguments"
    end
  end

  test "forged ownership arguments fail schema validation before the handler", %{
    auth_token: auth_token
  } do
    for ownership <- [
          %{"host_id" => Ecto.UUID.generate()},
          %{"client_id" => "host:attacker"},
          %{"namespace" => "shared"}
        ] do
      response =
        mcp_request(
          "tools/call",
          %{
            "name" => "memory::remember",
            "arguments" =>
              Map.merge(
                %{"content" => "forged", "agent_id" => "contract-agent"},
                ownership
              )
          },
          auth_token: auth_token
        )

      assert %{"error" => %{"code" => -32_602}} = response
    end

    assert Repo.aggregate(MemorySchema, :count) == 0
  end

  test "managed handler failures use text content and isError true", %{auth_token: auth_token} do
    response =
      mcp_request(
        "tools/call",
        %{
          "name" => "memory::forget",
          "arguments" => %{"id" => Ecto.UUID.generate()}
        },
        auth_token: auth_token
      )

    assert %{
             "result" =>
               %{
                 "content" => [%{"type" => "text", "text" => message}],
                 "isError" => true
               } = result
           } = response

    assert message =~ "memory not found"
    refute Map.has_key?(result, "structuredContent")
  end

  test "tasks/create cannot bypass canonical Memory permissions", %{host: host} do
    {_client, read_token} =
      Backplane.Fixtures.insert_client(
        name: "memory-task-read-only",
        scopes: ["memory.read"],
        metadata: %{"memory_partition_id" => "host:#{host.id}"}
      )

    response =
      mcp_request(
        "tasks/create",
        %{
          "name" => "memory::remember",
          "arguments" => %{"content" => "task bypass", "agent_id" => "agent"}
        },
        auth_token: read_token
      )

    assert %{"error" => %{"code" => -32_001}} = response
    assert Repo.aggregate(MemorySchema, :count) == 0
  end

  test "authorized tasks carry auth and remain owner-bound", %{host: host} do
    {writer, write_token} =
      Backplane.Fixtures.insert_client(
        name: "memory-task-writer",
        scopes: ["memory.write"],
        metadata: %{"memory_partition_id" => "host:#{host.id}"}
      )

    {_reader, read_token} =
      Backplane.Fixtures.insert_client(
        name: "memory-task-other",
        scopes: ["memory.read"],
        metadata: %{"memory_partition_id" => "host:#{host.id}"}
      )

    created =
      mcp_request(
        "tasks/create",
        %{
          "name" => "memory::remember",
          "arguments" => %{"content" => "authorized task", "agent_id" => "agent"}
        },
        auth_token: write_token
      )

    assert %{"result" => %{"id" => task_id}} = created

    hidden = mcp_request("tasks/get", %{"id" => task_id}, auth_token: read_token)
    assert %{"error" => %{"code" => -32_602, "message" => "Task not found"}} = hidden

    {:ok, reassigned_host, _token, _plaintext} =
      Hosts.create_agent_with_token(%{
        "name" => "memory-task-reassigned-#{System.unique_integer([:positive])}",
        "memory_scope" => host.memory_scope
      })

    writer
    |> Backplane.Clients.Client.changeset(%{
      metadata: %{"memory_partition_id" => "host:#{reassigned_host.id}"}
    })
    |> Repo.update!()

    :ok = Backplane.Clients.refresh_cache()

    for method <- ["tasks/get", "tasks/result", "tasks/cancel"] do
      hidden_after_reassignment =
        mcp_request(method, %{"id" => task_id}, auth_token: write_token)

      assert %{"error" => %{"code" => -32_602, "message" => "Task not found"}} =
               hidden_after_reassignment
    end

    writer
    |> Repo.reload!()
    |> Backplane.Clients.Client.changeset(%{
      metadata: %{"memory_partition_id" => "host:#{host.id}"}
    })
    |> Repo.update!()

    :ok = Backplane.Clients.refresh_cache()

    assert [{^task_id, %{owner: stored_owner}}] = :ets.lookup(:backplane_mcp_tasks, task_id)

    assert stored_owner ==
             {:client_token, writer.id, nil,
              {host.id, "host:#{host.id}", host.memory_scope, "private"}}

    assert Repo.get!(Backplane.Clients.Client, writer.id).metadata == %{
             "memory_partition_id" => "host:#{host.id}"
           }

    assert eventually(fn ->
             result = mcp_request("tasks/result", %{"id" => task_id}, auth_token: write_token)
             match?(%{"result" => %{"id" => _id}}, result)
           end)

    assert %MemorySchema{host_id: host_id, client_id: partition_id} = Repo.one!(MemorySchema)
    assert host_id == host.id
    assert partition_id == "host:#{host.id}"
  end

  test "memory.read list is confined to the authenticated host partition", %{host: host} do
    {:ok, other_host, _token, _plaintext} =
      Hosts.create_agent_with_token(%{
        "name" => "memory-list-decoy-#{System.unique_integer([:positive])}",
        "memory_scope" => "global"
      })

    assert {:ok, own} =
             Memories.remember("own partition fact",
               scope: "global",
               agent_id: "agent",
               host_id: host.id,
               client_id: "host:#{host.id}",
               namespace: "private"
             )

    assert {:ok, _decoy} =
             Memories.remember("foreign partition secret",
               scope: "global",
               agent_id: "agent",
               host_id: other_host.id,
               client_id: "host:#{other_host.id}",
               namespace: "private"
             )

    {_reader, read_token} =
      Backplane.Fixtures.insert_client(
        name: "memory-list-reader",
        scopes: ["memory.read"],
        metadata: %{"memory_partition_id" => "host:#{host.id}"}
      )

    response =
      mcp_request(
        "tools/call",
        %{"name" => "memory::list", "arguments" => %{}},
        auth_token: read_token
      )

    assert %{"result" => %{"content" => [%{"text" => encoded}]}} = response
    assert %{"results" => results} = Jason.decode!(encoded)
    assert Enum.map(results, & &1["id"]) == [own.id]
    refute encoded =~ "foreign partition secret"
  end

  test "deregistered Memory tools are absent and calls return unknown-tool errors", %{
    auth_token: auth_token
  } do
    :ok = ToolRegistry.deregister_managed(Service.prefix())

    listed_names =
      mcp_request("tools/list", nil, auth_token: auth_token)["result"]["tools"]
      |> Enum.map(& &1["name"])

    refute Enum.any?(listed_names, &String.starts_with?(&1, "memory::"))

    response =
      mcp_request(
        "tools/call",
        %{
          "name" => "memory::remember",
          "arguments" => %{
            "content" => "disabled",
            "agent_id" => "contract-agent"
          }
        },
        auth_token: auth_token
      )

    assert %{
             "result" => %{
               "content" => [%{"type" => "text", "text" => message}],
               "isError" => true
             }
           } = response

    assert message =~ "Unknown tool: memory::remember"
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
