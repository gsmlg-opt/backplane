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

  defmodule EmptyMirror do
    def offer(opts) do
      send(Keyword.fetch!(opts, :owner), :offer)
      {:ok, %{"offers" => ["host_memory.v2"], "partitions" => []}}
    end
  end

  defmodule FailingChannel do
    def push(channel, "memory_next", payload, _timeout) do
      send(channel, {:memory_next, payload})
      {:error, :timeout}
    end
  end

  defmodule InteractiveChannel do
    def push(channel, "memory_next", payload, _timeout) do
      send(channel, {:memory_next, self(), payload})

      receive do
        {:memory_next_reply, reply} -> reply
      end
    end

    def push(channel, "memory_ack", payload, _timeout) do
      send(channel, {:memory_ack, payload})
      {:ok, %{"status" => "advanced"}}
    end
  end

  defmodule WrongPartitionChannel do
    def push(channel, "memory_next", payload, _timeout) do
      send(channel, {:memory_next, payload})

      {:ok,
       %{
         "protocol" => "host_memory.v2",
         "status" => "batch",
         "kind" => "delta",
         "batch_id" => "wrong-partition",
         "partition" => %{
           "memory_space_id" => "space-2",
           "scope" => "private",
           "namespace" => "default"
         },
         "from_revision" => 5,
         "to_revision" => 5,
         "changes" => []
       }}
    end

    def push(channel, "memory_ack", payload, _timeout) do
      send(channel, {:unexpected_ack, payload})
      {:ok, %{}}
    end
  end

  defmodule PartitionCheckingMirror do
    def offer(opts), do: Mirror.offer(opts)

    def apply_delivery(delivery, opts) do
      expected = Keyword.get(opts, :partition)
      send(Keyword.fetch!(opts, :owner), {:apply_delivery, expected, delivery["partition"]})

      if delivery["partition"] == expected do
        {:ok,
         %{"batch_id" => delivery["batch_id"], "applied_revision" => delivery["to_revision"]}}
      else
        {:error, :partition_mismatch}
      end
    end
  end

  test "pulls a delivery, durably applies it, then acknowledges it" do
    syncer =
      start_syncer(
        name: nil,
        channel: self(),
        channel_module: Channel,
        mirror_module: Mirror,
        mirror_opts: [owner: self()],
        selected: "host_memory.v2",
        poll_interval_ms: 60_000
      )

    assert_receive :offer
    trigger_poll(syncer)
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
    syncer =
      start_syncer(
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
    syncer =
      start_syncer(
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
    syncer =
      start_syncer(
        name: nil,
        channel: self(),
        channel_module: CurrentChannel,
        mirror_module: Mirror,
        mirror_opts: [owner: self()],
        selected: "host_memory.v2",
        poll_interval_ms: 60_000
      )

    assert_receive :offer
    trigger_poll(syncer)
    assert_receive {:memory_next, _}
    refute_receive {:apply_delivery, _}
    refute_receive {:unexpected_ack, _}
  end

  test "continues an interrupted snapshot with its durable progress cursor" do
    syncer =
      start_syncer(
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
    trigger_poll(syncer)

    assert_receive {:memory_next,
                    %{
                      "protocol" => "host_memory.v2",
                      "partition" => %{"memory_space_id" => "space-1"},
                      "applied_revision" => 0,
                      "snapshot_id" => "snapshot-1",
                      "next_chunk_index" => 3
                    }}
  end

  test "bootstraps an empty mirror from negotiated partition inventory" do
    partition = %{
      "memory_space_id" => "space-3",
      "scope" => "private",
      "namespace" => "default",
      "applied_revision" => 0
    }

    syncer =
      start_syncer(
        name: nil,
        channel: self(),
        channel_module: CurrentChannel,
        mirror_module: EmptyMirror,
        mirror_opts: [owner: self()],
        selected: "host_memory.v2",
        partitions: [partition],
        poll_interval_ms: 60_000
      )

    assert_receive :offer
    trigger_poll(syncer)

    assert_receive {:memory_next,
                    %{"partition" => %{"memory_space_id" => "space-3"}, "applied_revision" => 0}}
  end

  test "round robins a staging snapshot and another entitled partition" do
    syncer =
      start_syncer(
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
    trigger_poll(syncer)
    assert_receive {:memory_next, %{"partition" => %{"memory_space_id" => "space-1"}}}
    trigger_poll(syncer)
    assert_receive {:memory_next, %{"partition" => %{"memory_space_id" => "space-2"}}}
  end

  test "failed edge polls schedule a bounded retry without a connection retry" do
    syncer =
      start_syncer(
        name: nil,
        channel: self(),
        channel_module: FailingChannel,
        mirror_module: Mirror,
        mirror_opts: [owner: self()],
        selected: "host_memory.v2",
        retry_backoff_ms: 10,
        poll_interval_ms: 60_000
      )

    assert_receive :offer
    trigger_poll(syncer)
    assert_receive {:memory_next, _}
    assert %{edge_retry_ref: ref, current_retry_backoff_ms: 20} = Syncer.status(syncer)
    assert is_reference(ref)
  end

  test "does not poll a durable partition revoked from the negotiated inventory" do
    entitled = %{
      "memory_space_id" => "space-9",
      "scope" => "private",
      "namespace" => "default",
      "applied_revision" => 0
    }

    syncer =
      start_syncer(
        name: nil,
        channel: self(),
        channel_module: CurrentChannel,
        mirror_module: Mirror,
        mirror_opts: [owner: self()],
        selected: "host_memory.v2",
        partitions: [entitled],
        poll_interval_ms: 60_000
      )

    assert_receive :offer
    trigger_poll(syncer)
    assert_receive {:memory_next, %{"partition" => %{"memory_space_id" => "space-9"}}}
    refute_received {:memory_next, %{"partition" => %{"memory_space_id" => "space-1"}}}
  end

  test "binds a delivery to the requested partition and does not acknowledge a mismatch" do
    _syncer =
      start_syncer(
        channel: self(),
        channel_module: WrongPartitionChannel,
        mirror_module: PartitionCheckingMirror,
        mirror_opts: [owner: self()],
        selected: "host_memory.v2",
        poll_interval_ms: 60_000
      )

    assert_receive :offer
    assert_receive {:memory_next, %{"partition" => requested}}

    assert requested == %{
             "memory_space_id" => "space-1",
             "scope" => "private",
             "namespace" => "default"
           }

    assert_receive {:apply_delivery, ^requested,
                    %{"memory_space_id" => "space-2", "scope" => "private"}}

    refute_receive {:unexpected_ack, _}
  end

  test "memory_available invalidates a failed poll retry and its stale message" do
    syncer = start_interactive_syncer()
    old_retry_token = fail_initial_poll_and_retry(syncer)

    Syncer.memory_available(syncer, %{"current_revision" => 1})
    assert_receive {:memory_next, caller, _}
    send(caller, {:memory_next_reply, {:ok, %{"status" => "current"}}})
    assert_eventually(fn -> Syncer.status(syncer).edge_retry_token == nil end)

    send(syncer, {:edge_retry, old_retry_token})
    refute_receive {:memory_next, _, _}, 50
  end

  test "string-key reconnect invalidates a failed poll retry and its stale message" do
    syncer = start_interactive_syncer()
    old_retry_token = fail_initial_poll_and_retry(syncer)

    Syncer.set_connection(syncer, %{
      channel: self(),
      memory: %{
        "selected" => "host_memory.v2",
        "partitions" => [
          %{
            "memory_space_id" => "space-1",
            "scope" => "private",
            "namespace" => "default",
            "applied_revision" => 0
          }
        ]
      }
    })

    assert_receive {:memory_next, caller, _}
    send(caller, {:memory_next_reply, {:ok, %{"status" => "current"}}})
    assert_eventually(fn -> Syncer.status(syncer).edge_retry_token == nil end)

    send(syncer, {:edge_retry, old_retry_token})
    refute_receive {:memory_next, _, _}, 50
  end

  test "atom-key reconnect invalidates a failed poll retry and its stale message" do
    syncer = start_interactive_syncer()
    old_retry_token = fail_initial_poll_and_retry(syncer)

    Syncer.set_connection(syncer, %{
      channel: self(),
      memory: %{selected: "host_memory.v2"}
    })

    assert_receive {:memory_next, caller, _}
    send(caller, {:memory_next_reply, {:ok, %{"status" => "current"}}})
    assert_eventually(fn -> Syncer.status(syncer).edge_retry_token == nil end)

    send(syncer, {:edge_retry, old_retry_token})
    refute_receive {:memory_next, _, _}, 50
  end

  test "rescheduling a poll invalidates its stale token" do
    syncer = start_interactive_syncer()
    assert_receive {:memory_next, caller, _}
    send(caller, {:memory_next_reply, {:ok, %{"status" => "current"}}})
    assert_eventually(fn -> is_reference(Syncer.status(syncer).poll_token) end)
    old_poll_token = Syncer.status(syncer).poll_token

    Syncer.memory_available(syncer, %{"current_revision" => 2})
    assert_receive {:memory_next, caller, _}
    send(caller, {:memory_next_reply, {:ok, %{"status" => "current"}}})
    assert_eventually(fn -> Syncer.status(syncer).poll_token != old_poll_token end)

    send(syncer, {:poll, old_poll_token})
    refute_receive {:memory_next, _, _}, 50
  end

  defp start_interactive_syncer do
    start_syncer(
      channel: self(),
      channel_module: InteractiveChannel,
      mirror_module: Mirror,
      mirror_opts: [owner: self()],
      selected: "host_memory.v2",
      retry_backoff_ms: 60_000,
      poll_interval_ms: 60_000
    )
  end

  defp fail_initial_poll_and_retry(syncer) do
    assert_receive {:memory_next, caller, _}
    send(caller, {:memory_next_reply, {:error, :timeout}})
    assert_eventually(fn -> is_reference(Syncer.status(syncer).edge_retry_token) end)
    Syncer.status(syncer).edge_retry_token
  end

  defp start_syncer(opts) do
    {:ok, syncer} = Syncer.start_link(Keyword.put(opts, :name, nil))

    on_exit(fn ->
      if Process.alive?(syncer), do: Syncer.stop(syncer)
    end)

    syncer
  end

  defp trigger_poll(syncer) do
    send(syncer, {:poll, Syncer.status(syncer).poll_token})
  end

  defp assert_eventually(fun, attempts \\ 20)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      assert true
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end
end
