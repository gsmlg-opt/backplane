defmodule Backplane.HostAgent.MemoryTestFixtures do
  @moduledoc false

  alias Backplane.HostAgent.Memory
  alias Backplane.HostAgent.Memory.{Access, Edge, Migrator, Mirror, Store}

  @access_id "11111111-1111-4111-8111-111111111111"
  @canonical_id "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @partition %{
    "memory_space_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "scope" => "proj_local",
    "namespace" => "private"
  }
  @edge_config %{enabled: true, development_plaintext: true}

  def start!(dir, opts \\ []) do
    store =
      ExUnit.Callbacks.start_supervised!(
        {Store, database: Path.join(dir, "commands.db"), pool_size: 1}
      )

    :ok = Migrator.migrate(store)

    edge =
      ExUnit.Callbacks.start_supervised!(
        {Edge.Store, database: Path.join(dir, "edge.db"), config: @edge_config}
      )

    :ok = Edge.Migrator.migrate(edge)

    owner =
      ExUnit.Callbacks.start_supervised!(
        {Access,
         name: Keyword.get(opts, :owner_name),
         store: store,
         edge_store: edge,
         edge_config: @edge_config}
      )

    fixture = %{
      store: store,
      edge: edge,
      owner: owner,
      config: @edge_config,
      canonical_id: @canonical_id,
      partition: @partition,
      inventory: inventory()
    }

    if Keyword.get(opts, :install?, true) do
      :ok =
        Access.install_inventory(
          %{
            id: System.unique_integer([:monotonic, :positive]),
            sent_at_ms: System.monotonic_time(:millisecond)
          },
          fixture.inventory,
          owner
        )

      populate!(fixture)
    else
      fixture
    end
  end

  def inventory do
    %{
      "selected" => "host_memory.v2",
      "partitions" => [],
      "extensions" => ~w(memory_access.v1 memory_commands.v2),
      "default_access_id" => @access_id,
      "accesses" => [
        %{
          "access_id" => @access_id,
          "authority_version" => 1,
          "status" => "active",
          "partition" => @partition,
          "capabilities" => ~w(read deliver remember forget),
          "offline_read_lease_seconds" => 300
        }
      ]
    }
  end

  def populate!(fixture) do
    {:ok, target, ticket} = Access.begin_request(:default, :deliver, fixture.owner)

    items = [
      %{
        "canonical_id" => @canonical_id,
        "memory_type" => "semantic",
        "content" => "protected mirror memory",
        "content_hash" => "fixture-content-hash",
        "confidence" => 1.0,
        "edge_priority" => 1.0,
        "lifecycle_state" => "active",
        "tags" => [],
        "metadata" => %{},
        "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
      }
    ]

    chunk_hash = Mirror.Store.hash(%{"items" => items})

    frame = %{
      "protocol" => "host_memory.v2",
      "status" => "batch",
      "kind" => "snapshot_chunk",
      "batch_id" => Backplane.HostAgent.Memory.UUID7.generate(),
      "partition" => @partition,
      "access" => Access.claim(target),
      "snapshot_id" => Backplane.HostAgent.Memory.UUID7.generate(),
      "chunk_index" => 0,
      "chunk_count" => 1,
      "item_count" => 1,
      "base_revision" => 0,
      "to_revision" => 1,
      "chunk_hash" => chunk_hash,
      "integrity_hash" =>
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, chunk_hash), case: :lower),
      "items" => items
    }

    {:ok, permitted, _} = Access.finish_request(ticket, {:ok, frame}, fixture.owner)

    {:ok, _} =
      Access.run_local(
        permitted,
        :deliver,
        fn _ -> Mirror.apply_delivery(frame, store: fixture.edge, config: @edge_config) end,
        fixture.owner
      )

    {:ok, target, _} = Access.begin_request(:default, :remember, fixture.owner)

    {:ok, receipt} =
      Access.run_local(
        target,
        :remember,
        &Memory.shared_enqueue(
          &1,
          "remember",
          %{"content" => "protected pending memory"},
          "codex"
        ),
        fixture.owner
      )

    Map.put(fixture, :pending_id, receipt["command_id"])
  end

  def context(fixture), do: %{agent_id: "codex", access_server: fixture.owner}
end
