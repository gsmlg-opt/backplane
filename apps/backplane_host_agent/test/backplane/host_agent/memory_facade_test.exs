defmodule Backplane.HostAgent.MemoryFacadeTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.MemoryFacade

  defmodule RemoteOK do
    def call("recall", args, opts) do
      send(self(), {:remote_call, "recall", args, opts})

      {:ok,
       %{
         "status" => "ok",
         "recall_run_id" => "run-1",
         "token_count" => 42,
         "provenance" => %{"strategy" => "rrf"},
         "results" => [
           %{
             "id" => "canonical-1",
             "content" => "canonical",
             "score" => 0.9,
             "source" => "vector"
           }
         ]
       }}
    end

    def call("list", args, opts) do
      send(self(), {:remote_call, "list", args, opts})

      {:ok,
       %{
         "status" => "ok",
         "cursor" => "next-1",
         "results" => [%{"id" => "canonical-1", "content" => "canonical"}]
       }}
    end

    def call("stats", args, opts) do
      send(self(), {:remote_call, "stats", args, opts})
      {:ok, %{"status" => "ok", "total" => 7}}
    end
  end

  defmodule RemoteManyList do
    def call("list", _args, _opts) do
      {:ok,
       %{
         "results" =>
           Enum.map(1..12, fn index ->
             %{"id" => "canonical-#{index}", "content" => "canonical #{index}"}
           end)
       }}
    end
  end

  defmodule EmptyOverlay do
    def pending_overlay(args, opts) do
      send(self(), {:pending_overlay, args, opts})
      {:ok, %{"upserts" => [], "delete_ids" => [], "pending_operations" => 0}}
    end

    def recall(_args, _opts), do: send(self(), :unexpected_local_recall)
    def facts(_args, _opts), do: send(self(), :unexpected_local_facts)
  end

  defmodule PendingOnly do
    def pending_overlay(_args, _opts) do
      send(self(), :pending_overlay)

      {:ok,
       %{
         "upserts" => [
           %{"id" => "local-1", "content" => "pending local command", "provisional" => true}
         ],
         "delete_ids" => [],
         "pending_operations" => 1
       }}
    end

    def recall(_args, _opts), do: send(self(), :unexpected_local_recall)
    def facts(_args, _opts), do: send(self(), :unexpected_local_facts)
  end

  defmodule PendingRemember do
    def pending_overlay(_args, _opts) do
      {:ok,
       %{
         "upserts" => [
           %{
             "id" => "local-1",
             "canonical_id" => nil,
             "content" => "pending insight",
             "origin" => "host_command",
             "authority" => "provisional",
             "provisional" => true
           }
         ],
         "delete_ids" => [],
         "pending_operations" => 1
       }}
    end
  end

  defmodule PendingForget do
    def pending_overlay(_args, _opts) do
      {:ok, %{"upserts" => [], "delete_ids" => ["canonical-1"], "pending_operations" => 1}}
    end
  end

  defmodule AcknowledgedRemember do
    def pending_overlay(_args, _opts) do
      {:ok,
       %{
         "upserts" => [
           %{
             "id" => "local-1",
             "canonical_id" => "canonical-1",
             "content" => "provisional duplicate",
             "provisional" => true
           }
         ],
         "delete_ids" => [],
         "pending_operations" => 1
       }}
    end
  end

  defmodule MultiplePending do
    def pending_overlay(_args, _opts) do
      {:ok,
       %{
         "upserts" => [
           %{"id" => "local-1", "content" => "first pending", "provisional" => true},
           %{"id" => "local-2", "content" => "second pending", "provisional" => true}
         ],
         "delete_ids" => [],
         "pending_operations" => 2
       }}
    end
  end

  defmodule OverlayFailure do
    def pending_overlay(_args, _opts), do: {:error, {:storage_error, :overlay_unavailable}}
  end

  defmodule LocalCommands do
    def remember(args, opts) do
      send(self(), {:local_call, "remember", args, opts})
      {:ok, %{"id" => "local-1", "status" => "pending"}}
    end

    def forget(args, opts) do
      send(self(), {:local_call, "forget", args, opts})
      {:ok, %{"id" => args["id"], "status" => "pending"}}
    end
  end

  defmodule RemoteNotConnected do
    def call(_method, _args, _opts), do: {:error, :not_connected}
  end

  defmodule RemoteTimeout do
    def call(_method, _args, _opts), do: {:error, :timeout}
  end

  defmodule RemoteConnectionRefused do
    def call(_method, _args, _opts), do: {:error, :econnrefused}
  end

  defmodule RemoteSocketClosed do
    def call(_method, _args, _opts), do: {:error, {:socket_closed, :normal}}
  end

  defmodule RemoteNestedTransport do
    def call(_method, %{"reason" => reason}, _opts), do: {:error, reason}
  end

  defmodule RemoteUnauthorized do
    def call(_method, _args, _opts), do: {:error, "unauthorized"}
  end

  defmodule RemotePartitionMismatch do
    def call(_method, _args, _opts), do: {:error, "partition_mismatch"}
  end

  defmodule RemoteInvalid do
    def call(_method, _args, _opts), do: {:error, "invalid_arguments"}
  end

  defmodule RemoteNotFound do
    def call(_method, _args, _opts), do: {:error, "memory not found"}
  end

  defmodule RemoteUnknownError do
    def call(_method, _args, _opts), do: {:error, :canonical_store_unavailable}
  end

  defmodule RemoteUnexpectedReply do
    def call(_method, _args, _opts), do: {:error, {:unexpected_reply, %{"ok" => false}}}
  end

  test "healthy recall preserves canonical metadata and adds the hits alias" do
    assert {:ok,
            %{
              "mode" => "online",
              "authority" => "canonical",
              "consistency" => "canonical",
              "stale" => false,
              "as_of" => nil,
              "partition_revision" => nil,
              "last_sync_age_seconds" => nil,
              "pending_operations" => 0,
              "history_available" => true,
              "status" => "ok",
              "recall_run_id" => "run-1",
              "token_count" => 42,
              "provenance" => %{"strategy" => "rrf"},
              "results" => [%{"id" => "canonical-1", "score" => 0.9}],
              "hits" => [%{"id" => "canonical-1", "score" => 0.9}]
            }} =
             MemoryFacade.call(
               "recall",
               %{"query" => "canonical"},
               %{agent_id: "codex", remote_adapter: RemoteOK, local_adapter: EmptyOverlay}
             )

    assert_received {:remote_call, "recall", %{"query" => "canonical"}, remote_opts}
    assert remote_opts[:agent_id] == "codex"
    assert remote_opts[:inject_agent_id] == false
    assert_received {:pending_overlay, %{"query" => "canonical"}, local_opts}
    assert local_opts[:agent_id] == "codex"
    refute_received :unexpected_local_recall
    refute_received :unexpected_local_facts
  end

  test "healthy list preserves canonical fields and adds the items alias" do
    assert {:ok,
            %{
              "mode" => "online",
              "authority" => "canonical",
              "consistency" => "canonical",
              "cursor" => "next-1",
              "results" => [%{"id" => "canonical-1"}],
              "items" => [%{"id" => "canonical-1"}]
            }} =
             MemoryFacade.call(
               "list",
               %{"limit" => 10},
               %{agent_id: "codex", remote_adapter: RemoteOK, local_adapter: EmptyOverlay}
             )
  end

  test "list without an explicit limit preserves all canonical results" do
    assert {:ok, %{"results" => results, "items" => items}} =
             MemoryFacade.call(
               "list",
               %{},
               %{agent_id: "codex", remote_adapter: RemoteManyList, local_adapter: EmptyOverlay}
             )

    assert length(results) == 12
    assert items == results
  end

  test "list reapplies an explicit string or atom limit after merging pending upserts" do
    for args <- [%{"limit" => 1}, %{limit: 1}] do
      assert {:ok, %{"results" => results, "items" => items}} =
               MemoryFacade.call(
                 "list",
                 args,
                 %{agent_id: "codex", remote_adapter: RemoteOK, local_adapter: PendingRemember}
               )

      assert Enum.map(results, & &1["id"]) == ["local-1"]
      assert items == results
    end
  end

  test "healthy stats preserves canonical fields and receives consistency metadata" do
    assert {:ok,
            %{
              "mode" => "online",
              "authority" => "canonical",
              "consistency" => "canonical",
              "stale" => false,
              "history_available" => true,
              "pending_operations" => 0,
              "total" => 7
            }} =
             MemoryFacade.call(
               "stats",
               %{},
               %{agent_id: "codex", remote_adapter: RemoteOK, local_adapter: EmptyOverlay}
             )
  end

  test "non-empty pending state decorates an online result as read-your-writes" do
    assert {:ok,
            %{
              "mode" => "online",
              "authority" => "canonical_with_provisional",
              "consistency" => "read_your_writes",
              "pending_operations" => 1,
              "history_available" => true
            }} =
             MemoryFacade.call(
               "recall",
               %{"query" => "canonical"},
               %{agent_id: "codex", remote_adapter: RemoteOK, local_adapter: PendingOnly}
             )
  end

  test "online recall includes an unmatched pending remember exactly once" do
    assert {:ok, %{"results" => results, "hits" => hits}} =
             MemoryFacade.call(
               "recall",
               %{"query" => "insight"},
               %{agent_id: "codex", remote_adapter: RemoteOK, local_adapter: PendingRemember}
             )

    assert results == hits
    assert Enum.count(results, &(&1["id"] == "local-1")) == 1
    assert Enum.any?(results, &(&1["id"] == "canonical-1"))
  end

  test "pending forget suppresses the matching canonical result" do
    assert {:ok,
            %{
              "results" => [],
              "hits" => [],
              "authority" => "canonical_with_provisional",
              "consistency" => "read_your_writes"
            }} =
             MemoryFacade.call(
               "recall",
               %{"query" => "canonical"},
               %{agent_id: "codex", remote_adapter: RemoteOK, local_adapter: PendingForget}
             )
  end

  test "canonical result wins after the pending remember maps a remote id" do
    assert {:ok, %{"results" => [result], "hits" => [result]}} =
             MemoryFacade.call(
               "recall",
               %{"query" => "canonical"},
               %{
                 agent_id: "codex",
                 remote_adapter: RemoteOK,
                 local_adapter: AcknowledgedRemember
               }
             )

    assert result["id"] == "canonical-1"
    assert result["content"] == "canonical"
    refute result["provisional"]
  end

  test "recall reapplies the requested limit after merging the overlay" do
    assert {:ok, %{"results" => results, "hits" => hits}} =
             MemoryFacade.call(
               "recall",
               %{"query" => "pending", "limit" => 2},
               %{agent_id: "codex", remote_adapter: RemoteOK, local_adapter: MultiplePending}
             )

    assert results == hits
    assert Enum.map(results, & &1["id"]) == ["local-1", "local-2"]
  end

  test "overlay read failure fails the canonical read" do
    assert {:error, {:storage_error, :overlay_unavailable}} =
             MemoryFacade.call(
               "recall",
               %{"query" => "canonical"},
               %{agent_id: "codex", remote_adapter: RemoteOK, local_adapter: OverlayFailure}
             )
  end

  test "facade read options omit path-agent filtering and retain injected timeout" do
    store = make_ref()
    config = %{default_scope: "project"}

    assert {:ok, _result} =
             MemoryFacade.call(
               "recall",
               %{"query" => "canonical"},
               %{
                 agent_id: "codex",
                 remote_adapter: RemoteOK,
                 local_adapter: EmptyOverlay,
                 timeout: 321,
                 store: store,
                 config: config
               }
             )

    assert_received {:remote_call, "recall", _args, remote_opts}
    assert remote_opts[:agent_id] == "codex"
    assert remote_opts[:timeout] == 321
    assert remote_opts[:inject_agent_id] == false
    assert_received {:pending_overlay, _args, local_opts}
    assert local_opts[:agent_id] == "codex"
    assert local_opts[:store] == store
    assert local_opts[:config] == config
  end

  test "remember uses the local transaction and marks the result pending canonical acknowledgement" do
    store = make_ref()
    config = %{default_scope: "project"}

    assert {:ok,
            %{
              "id" => "local-1",
              "status" => "pending",
              "authority" => "provisional",
              "consistency" => "pending_canonical_ack"
            } = result} =
             MemoryFacade.call(
               "remember",
               %{"content" => "pending insight"},
               %{agent_id: "codex", local_adapter: LocalCommands, store: store, config: config}
             )

    refute Map.has_key?(result, "mode")

    assert_received {:local_call, "remember", %{"content" => "pending insight"}, opts}
    assert opts[:agent_id] == "codex"
    assert opts[:store] == store
    assert opts[:config] == config
  end

  test "forget uses the local transaction and marks the result pending canonical acknowledgement" do
    assert {:ok,
            %{
              "id" => "local-1",
              "authority" => "provisional",
              "consistency" => "pending_canonical_ack"
            } = result} =
             MemoryFacade.call(
               "forget",
               %{"id" => "local-1"},
               %{agent_id: "codex", local_adapter: LocalCommands}
             )

    refute Map.has_key?(result, "mode")
    assert_received {:local_call, "forget", %{"id" => "local-1"}, opts}
    assert opts[:agent_id] == "codex"
  end

  test "not_connected returns pending commands only and reports canonical history unavailable" do
    assert_offline_pending(RemoteNotConnected)
  end

  test "timeout returns pending commands only and reports canonical history unavailable" do
    assert_offline_pending(RemoteTimeout)
  end

  test "connection refused returns pending commands only and reports canonical history unavailable" do
    assert_offline_pending(RemoteConnectionRefused)
  end

  test "a normal socket close returns pending commands only" do
    assert_offline_pending(RemoteSocketClosed)
  end

  test "recognized nested transport, socket, reconnect, and channel exits enter offline mode" do
    reasons = [
      {:transport, :econnreset},
      {:transport_error, :enetdown},
      {:socket, :enetunreach},
      {:socket_error, :nxdomain},
      {:reconnect_failed, :hub_down},
      {:reconnect_failed, {:transport_error, :econnrefused}},
      {:reconnect_lock_failed, {:timeout, :global_lock}},
      {:socket, {:socket_closed, :econnreset}},
      {:channel_exit, {:shutdown, :closed}},
      {:channel_exit, {:closed, "socket"}},
      {:channel_exit, {:noproc, {GenServer, :call, []}}}
    ]

    for reason <- reasons do
      assert {:ok,
              %{
                "mode" => "offline",
                "authority" => "provisional",
                "consistency" => "provisional_only",
                "pending_operations" => 1
              }} =
               MemoryFacade.call(
                 "recall",
                 %{"reason" => reason},
                 %{
                   agent_id: "codex",
                   remote_adapter: RemoteNestedTransport,
                   local_adapter: PendingOnly
                 }
               )

      assert_received :pending_overlay
    end
  end

  test "all direct transport atoms are explicitly allowlisted" do
    for reason <- [
          :not_connected,
          :timeout,
          :econnrefused,
          :econnreset,
          :enetdown,
          :enetunreach,
          :nxdomain,
          :hub_down,
          :closed,
          :disconnected
        ] do
      assert {:ok, %{"mode" => "offline"}} =
               MemoryFacade.call(
                 "recall",
                 %{"reason" => reason},
                 %{
                   agent_id: "codex",
                   remote_adapter: RemoteNestedTransport,
                   local_adapter: PendingOnly
                 }
               )

      assert_received :pending_overlay
    end
  end

  test "unauthorized is a canonical error and never reads the pending overlay" do
    assert_canonical_error(RemoteUnauthorized, "unauthorized")
  end

  test "partition mismatch is a canonical error and never reads the pending overlay" do
    assert_canonical_error(RemotePartitionMismatch, "partition_mismatch")
  end

  test "invalid arguments is a canonical error and never reads the pending overlay" do
    assert_canonical_error(RemoteInvalid, "invalid_arguments")
  end

  test "not found is a canonical error and never reads the pending overlay" do
    assert_canonical_error(RemoteNotFound, "memory not found")
  end

  test "an unknown error never enters offline mode or reads the pending overlay" do
    assert_canonical_error(RemoteUnknownError, :canonical_store_unavailable)
  end

  test "an unexpected reply error never enters offline mode or reads the pending overlay" do
    reason = {:unexpected_reply, %{"ok" => false}}
    assert_canonical_error(RemoteUnexpectedReply, reason)
  end

  test "known methods require an agent identity in the context" do
    assert_raise KeyError, fn ->
      MemoryFacade.call(
        "recall",
        %{"query" => "canonical"},
        %{remote_adapter: RemoteOK, local_adapter: EmptyOverlay}
      )
    end
  end

  test "unknown methods are rejected without invoking either adapter" do
    assert {:error, {:unknown_method, "replay"}} = MemoryFacade.call("replay", %{}, %{})
    refute_received {:remote_call, _, _, _}
    refute_received {:local_call, _, _, _}
  end

  defp assert_offline_pending(remote_adapter) do
    assert {:ok,
            %{
              "mode" => "offline",
              "authority" => "provisional",
              "consistency" => "provisional_only",
              "stale" => true,
              "as_of" => nil,
              "partition_revision" => nil,
              "last_sync_age_seconds" => nil,
              "history_available" => false,
              "pending_operations" => 1,
              "upserts" => [%{"id" => "local-1", "provisional" => true}],
              "delete_ids" => [],
              "results" => [%{"id" => "local-1", "provisional" => true}],
              "hits" => [%{"id" => "local-1", "provisional" => true}]
            }} =
             MemoryFacade.call(
               "recall",
               %{"query" => "pending"},
               %{agent_id: "codex", remote_adapter: remote_adapter, local_adapter: PendingOnly}
             )

    assert_received :pending_overlay
    refute_received :unexpected_local_recall
    refute_received :unexpected_local_facts
  end

  defp assert_canonical_error(remote_adapter, reason) do
    assert {:error, ^reason} =
             MemoryFacade.call(
               "recall",
               %{"query" => "canonical"},
               %{agent_id: "codex", remote_adapter: remote_adapter, local_adapter: PendingOnly}
             )

    refute_received :pending_overlay
    refute_received :unexpected_local_recall
    refute_received :unexpected_local_facts
  end
end
