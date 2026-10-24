defmodule Backplane.HostAgent.MemoryRecordReadTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.{MemoryFacade, MemoryProxy}
  alias Backplane.HostAgent.Memory.{Access, Migrator, Store}

  @moduletag :tmp_dir
  @id "11111111-1111-4111-8111-111111111111"
  @access "22222222-2222-4222-8222-222222222222"
  @partition %{
    "memory_space_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "scope" => "shared",
    "namespace" => "private"
  }

  defmodule Remote do
    def call(method, args, opts) do
      send(self(), {:remote_read, method, args, opts})
      if callback = Process.get(:before_get_reply), do: callback.()

      case Process.get(:get_reply) do
        {:ok, result} when is_map(result) ->
          if opts[:access] do
            {:ok,
             %{
               "access" => opts[:access],
               "partition" => Process.get(:get_partition),
               "result" => result
             }}
          else
            {:ok, result}
          end

        other ->
          other
      end
    end
  end

  defmodule ForbiddenLocal do
    def pending_overlay(_, _), do: raise("exact get read provisional data")
    def offline_read(_, _, _), do: raise("exact get read a mirror")
    def call_tool(_, _), do: raise("exact get called the HubProxy")
  end

  setup %{tmp_dir: dir} do
    MemoryProxy.set_channel(nil)
    name = :"record_read_store_#{System.unique_integer([:positive])}"
    start_supervised!({Store, database: Path.join(dir, "commands.db"), name: name, pool_size: 1})
    :ok = Migrator.migrate(name)
    owner = start_supervised!({Access, name: nil, store: name, recall_cache: nil})
    Process.put(:get_reply, {:ok, result()})
    Process.put(:get_partition, @partition)

    on_exit(fn -> MemoryProxy.set_channel(nil) end)

    %{
      owner: owner,
      context: %{
        agent_id: "requesting-agent",
        access_server: owner,
        remote_adapter: Remote,
        local_adapter: ForbiddenLocal,
        edge_adapter: ForbiddenLocal,
        hub_adapter: ForbiddenLocal
      }
    }
  end

  test "private exact reads return full canonical records without overlays", c do
    assert {:ok, reply} = MemoryFacade.call("get", %{"id" => @id}, c.context)
    assert reply == result()
    assert_received {:remote_read, "get", %{"id" => @id}, opts}
    assert opts[:inject_agent_id] == false
    refute opts[:access]
    assert reply["record"]["provenance"]["source_host_id"] == "creator-host"
  end

  test "transport failures stay canonical unavailable without any local reads", c do
    for reason <- [:not_connected, :timeout, {:transport, :econnrefused}] do
      Process.put(:get_reply, {:error, reason})

      assert {:error, :canonical_unavailable} =
               MemoryFacade.call("get", %{"id" => @id}, c.context)
    end

    for reason <- [:unauthorized, :not_found, :invalid_arguments, {:protocol, :invalid_json}] do
      Process.put(:get_reply, {:error, reason})
      assert {:error, ^reason} = MemoryFacade.call("get", %{"id" => @id}, c.context)
    end
  end

  test "only recognized unknown operation errors map to unsupported operation", c do
    for reason <- [
          {:unknown_method, "get"},
          {:unknown_tool, "memory::get"},
          %{"code" => "unknown_method", "method" => "get"},
          %{"code" => "unsupported_operation"}
        ] do
      Process.put(:get_reply, {:error, reason})

      assert {:error, :unsupported_operation} =
               MemoryFacade.call("get", %{"id" => @id}, c.context)
    end

    reason = "unrecognized protocol error mentioning unknown method"
    Process.put(:get_reply, {:error, reason})
    assert {:error, ^reason} = MemoryFacade.call("get", %{"id" => @id}, c.context)
  end

  test "raw authority and unknown get constraints never reach the adapter", c do
    for args <- [
          %{"id" => @id, "scope" => "shared"},
          %{"id" => @id, "host_id" => "other"},
          %{"id" => @id, "facets" => []},
          %{"id" => "not-a-uuid"}
        ] do
      assert {:error, :invalid_arguments} = MemoryFacade.call("get", args, c.context)
      refute_received {:remote_read, _, _, _}
    end
  end

  test "shared and designated default reads use access tickets and omit raw selectors", c do
    assert :ok = install(c.owner, 1)

    for args <- [%{"id" => @id, "memory_access_id" => @access}, %{"id" => @id}] do
      assert {:ok, reply} = MemoryFacade.call("get", args, c.context)
      assert reply == result()
      assert_received {:remote_read, "get", %{"id" => @id}, opts}
      assert opts[:access] == %{"access_id" => @access, "authority_version" => 1}
      assert opts[:connection_generation] == 1
    end
  end

  test "revocation while canonical get is in flight prevents content release", c do
    assert :ok = install(c.owner, 1)

    Process.put(:before_get_reply, fn ->
      assert :ok = Access.fence({:access_id, @access}, :unauthorized, 1, c.owner)
    end)

    assert {:error, :stale_request} =
             MemoryFacade.call("get", %{"id" => @id, "memory_access_id" => @access}, c.context)
  end

  test "old connection replies do not release content or fence the new connection", c do
    assert :ok = install(c.owner, 1)
    Process.put(:before_get_reply, fn -> assert :ok = install(c.owner, 2) end)

    assert {:error, :stale_request} =
             MemoryFacade.call("get", %{"id" => @id, "memory_access_id" => @access}, c.context)

    Process.delete(:before_get_reply)
    assert {:ok, _} = MemoryFacade.call("get", %{"id" => @id}, c.context)
  end

  test "oversized encoded shared reply fails before Access can fence the grant", c do
    assert :ok = install(c.owner, 1)

    Process.put(
      :get_reply,
      {:ok, put_in(result(), ["record", "content"], String.duplicate("x", 524_000))}
    )

    assert {:error, :payload_too_large} =
             MemoryFacade.call("get", %{"id" => @id, "memory_access_id" => @access}, c.context)

    assert [%{status: status}] = Access.status(c.owner).accesses
    refute status == "fenced"
    Process.put(:get_reply, {:ok, result()})
    assert {:ok, _} = MemoryFacade.call("get", %{"id" => @id}, c.context)
  end

  defp install(owner, generation) do
    Access.install_inventory(
      %{id: generation, sent_at_ms: System.monotonic_time(:millisecond)},
      %{
        "extensions" => ["memory_access.v1"],
        "default_access_id" => @access,
        "accesses" => [
          %{
            "access_id" => @access,
            "authority_version" => 1,
            "status" => "active",
            "partition" => @partition,
            "capabilities" => ["read"],
            "offline_read_lease_seconds" => 0
          }
        ]
      },
      owner
    )
  end

  defp result do
    %{
      "record" => %{
        "id" => @id,
        "canonical_id" => @id,
        "kind" => "memory",
        "content" => String.duplicate("complete content ", 50),
        "provenance" => %{"source_host_id" => "creator-host"}
      },
      "mode" => "online",
      "authority" => "canonical",
      "consistency" => "canonical",
      "stale" => false,
      "history_available" => true
    }
  end
end
