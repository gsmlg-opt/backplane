defmodule Backplane.HostAgent.Memory.Edge.SyncerTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.Edge.Syncer

  defmodule Mirror do
    def offer(opts) do
      send(Keyword.fetch!(opts, :owner), :offer)

      {:ok,
       %{
         "offers" => ["host_memory.v2"],
         "partitions" => [
           %{
             "memory_space_id" => "space-1",
             "scope" => "private",
             "namespace" => "default",
             "applied_revision" => 0,
             "snapshot" => Keyword.get(opts, :snapshot)
           },
           %{
             "memory_space_id" => "space-2",
             "scope" => "private",
             "namespace" => "default",
             "applied_revision" => 4
           }
         ]
       }}
    end

    def apply_delivery(delivery, opts) do
      send(Keyword.fetch!(opts, :owner), {:apply_delivery, delivery})
      {:ok, %{"batch_id" => delivery["batch_id"], "applied_revision" => delivery["to_revision"]}}
    end
  end

  defmodule Channel do
    def push(channel, "memory_next", payload, _timeout) do
      send(channel, {:memory_next, payload})
      {:ok, delivery()}
    end

    def push(channel, "memory_ack", payload, _timeout) do
      send(channel, {:memory_ack, payload})
      {:ok, %{"status" => "advanced"}}
    end

    defp delivery do
      %{
        "protocol" => "host_memory.v2",
        "status" => "batch",
        "kind" => "delta",
        "batch_id" => "batch-1",
        "partition" => %{
          "memory_space_id" => "space-1",
          "scope" => "private",
          "namespace" => "default"
        },
        "from_revision" => 1,
        "to_revision" => 1,
        "changes" => [
          %{
            "revision" => 1,
            "op" => "upsert",
            "memory_id" => "memory-1",
            "payload" => %{
              "canonical_id" => "memory-1",
              "memory_type" => "semantic",
              "content" => "edge fact",
              "content_hash" => "hash",
              "confidence" => 1.0,
              "lifecycle_state" => "active",
              "tags" => [],
              "metadata" => %{},
              "expires_at" => nil
            }
          }
        ]
      }
    end
  end

  defmodule CurrentChannel do
    def push(channel, "memory_next", payload, _timeout) do
      send(channel, {:memory_next, payload})
      {:ok, %{"protocol" => "host_memory.v2", "status" => "current"}}
    end

    def push(channel, "memory_ack", payload, _timeout) do
      send(channel, {:unexpected_ack, payload})
      {:ok, %{}}
    end
  end

  test "pulls a delivery, durably applies it, then acknowledges it" do
    {:ok, syncer} =
      Syncer.start_link(
        name: nil,
        channel: self(),
        channel_module: Channel,
        mirror_module: Mirror,
        mirror_opts: [owner: self()],
        selected: "host_memory.v2",
        poll_interval_ms: 60_000
      )

    assert_receive :offer
    send(syncer, :poll)
    assert_receive {:memory_next, next}

    assert next == %{
             "protocol" => "host_memory.v2",
             "partition" => %{
               "memory_space_id" => "space-1",
               "scope" => "private",
               "namespace" => "default"
             },
             "applied_revision" => 0
           }

    assert_receive {:apply_delivery, delivery}
    assert_receive {:memory_ack, %{"batch_id" => "batch-1"}}
    assert delivery["batch_id"] == "batch-1"
  end

  test "memory_available wakes the polling loop without reconnecting" do
    {:ok, syncer} =
      Syncer.start_link(
        name: nil,
        channel: self(),
        channel_module: Channel,
        mirror_module: Mirror,
        mirror_opts: [owner: self()],
        selected: "host_memory.v2",
        poll_interval_ms: 60_000
      )

    assert_receive :offer
    Syncer.memory_available(syncer, %{"current_revision" => 1})
    assert_receive {:memory_next, _}
  end

  test "uses a bounded edge retry independently of connection retry state" do
    {:ok, syncer} =
      Syncer.start_link(
        name: nil,
        channel: self(),
        channel_module: Channel,
        mirror_module: Mirror,
        mirror_opts: [owner: self()],
        selected: "host_memory.v2",
        poll_interval_ms: 60_000,
        retry_backoff_ms: 10
      )

    assert_receive :offer
    assert %{edge_retry_ref: nil} = Syncer.status(syncer)
  end

  test "does not apply or acknowledge an already current partition" do
    {:ok, syncer} =
      Syncer.start_link(
        name: nil,
        channel: self(),
        channel_module: CurrentChannel,
        mirror_module: Mirror,
        mirror_opts: [owner: self()],
        selected: "host_memory.v2",
        poll_interval_ms: 60_000
      )

    assert_receive :offer
    send(syncer, :poll)
    assert_receive {:memory_next, _}
    refute_receive {:apply_delivery, _}
    refute_receive {:unexpected_ack, _}
  end

  test "continues an interrupted snapshot with its durable progress cursor" do
    {:ok, syncer} =
      Syncer.start_link(
        name: nil,
        channel: self(),
        channel_module: CurrentChannel,
        mirror_module: Mirror,
        mirror_opts: [
          owner: self(),
          snapshot: %{"snapshot_id" => "snapshot-1", "next_chunk_index" => 3}
        ],
        selected: "host_memory.v2",
        poll_interval_ms: 60_000
      )

    assert_receive :offer
    send(syncer, :poll)

    assert_receive {:memory_next,
                    %{
                      "protocol" => "host_memory.v2",
                      "partition" => %{"memory_space_id" => "space-1"},
                      "applied_revision" => 0,
                      "snapshot_id" => "snapshot-1",
                      "next_chunk_index" => 3
                    }}
  end
end
