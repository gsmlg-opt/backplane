defmodule Backplane.HostAgent.Memory.AccessTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.{Memory, MemoryFacade, MemoryProxy}
  alias Backplane.HostAgent.Memory.{Access, Migrator, Store}
  alias Backplane.HostAgent.Memory.Edge
  alias Backplane.HostAgent.Memory.Mirror

  @moduletag :tmp_dir
  @id "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"
  @partition %{
    "memory_space_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "scope" => "shared",
    "namespace" => "private"
  }
  @config %{enabled: true, development_plaintext: true}

  defmodule Remote do
    def call(_method, args, opts) do
      send(self(), {:shared_remote, args, opts})

      {:ok,
       %{
         "access" => opts[:access],
         "partition" => partition(),
         "result" => %{
           "results" => [
             %{"id" => "canonical", "content" => "canonical", "source_host_id" => "author-a"}
           ]
         }
       }}
    end

    defp partition,
      do: %{
        "memory_space_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "scope" => "shared",
        "namespace" => "private"
      }
  end

  defmodule SharedChannel do
    def push(owner, "memory_sync", payload) do
      send(owner, {:command_batch, payload})

      case Process.get({__MODULE__, :mode}) do
        {:error, reason} ->
          {:error, reason}

        :timeout ->
          {:error, :timeout}

        :credential_denied ->
          {:error, %{"code" => "unauthorized", "retryable" => false}}

        :reject ->
          {:ok,
           %{
             "protocol" => "memory_commands.v2",
             "items" =>
               Enum.map(payload["items"], fn item ->
                 Map.take(item, ["command_id", "access", "partition"])
                 |> Map.merge(%{"status" => "rejected", "code" => "unauthorized"})
               end)
           }}

        _ ->
          if payload["protocol"] == "memory_commands.v2" do
            {:ok,
             %{
               "protocol" => "memory_commands.v2",
               "items" =>
                 Enum.map(payload["items"], fn item ->
                   Map.take(item, ["command_id", "access", "partition"])
                   |> Map.merge(%{
                     "status" => "duplicate",
                     "canonical_id" => "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                     "revision" => 1
                   })
                 end)
             }}
          else
            {:ok,
             %{
               "items" =>
                 Enum.map(
                   payload["items"],
                   &%{"id" => &1["id"], "status" => "ok", "canonical_id" => "private-canonical"}
                 )
             }}
          end
      end
    end
  end

  defmodule DeniedReadChannel do
    def push(_, "memory_call", _, _),
      do: {:error, %{"code" => "unauthorized", "retryable" => false}}
  end

  defmodule DiesOnPush do
    def push(channel, event, payload) do
      GenServer.stop(channel)
      Backplane.HostAgent.Channel.push(channel, event, payload)
    end
  end

  defmodule SourceChannel do
    def push(channel, event, payload) do
      send(self(), {:source_dispatch, channel, payload})

      if Process.alive?(channel) do
        {:ok,
         %{
           "protocol" => "memory_commands.v2",
           "items" =>
             Enum.map(payload["items"], fn item ->
               Map.take(item, ~w(command_id access partition))
               |> Map.put("status", "committed")
               |> Map.put("source_result", %{
                 "protocol" => "memory_sources.v1",
                 "event_id" => item["command_id"],
                 "status" => "committed",
                 "outcome" => "applied",
                 "canonical_id" => "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                 "revision" => 9,
                 "source_revision" => 1,
                 "authority" => "canonical",
                 "consistency" => "canonical"
               })
             end)
         }}
      else
        Backplane.HostAgent.Channel.push(channel, event, payload)
      end
    end
  end

  defmodule CallChannel do
    def push(channel, event, payload, _timeout),
      do: GenServer.call(channel, {event, payload}, 10)
  end

  defmodule FeedChannel do
    def push(channel, event, payload, _timeout) do
      Agent.get_and_update(channel, fn state ->
        send(state.owner, {:feed, event, payload})

        case event do
          "memory_next" ->
            version = payload["access"]["authority_version"]

            if MapSet.member?(state.sent, version) do
              {{:ok,
                Map.merge(Map.take(payload, ["access", "partition"]), %{
                  "protocol" => "host_memory.v2",
                  "status" => "current",
                  "revision" => 0
                })}, state}
            else
              frame =
                Backplane.HostAgent.Memory.AccessTest.snapshot(payload["access"])
                |> Map.put("partition", payload["partition"])

              frame =
                if state[:chunks] == 2 do
                  manifest =
                    "sha256:" <>
                      Base.encode16(
                        :crypto.hash(:sha256, [frame["chunk_hash"], frame["chunk_hash"]]),
                        case: :lower
                      )

                  Map.merge(frame, %{"chunk_count" => 2, "integrity_hash" => manifest})
                else
                  frame
                end

              {{:ok, frame}, %{state | sent: MapSet.put(state.sent, version)}}
            end

          "memory_ack" ->
            reply =
              if payload["status"] == "progress" do
                Map.put(payload, "status", "progress")
              else
                # Canonical completion clears its snapshot cursor, including for
                # the final snapshot ACK whose request still carries I+1.
                Map.merge(payload, %{"status" => "advanced", "next_chunk_index" => nil})
              end

            {{:ok, Map.merge(reply, state[:ack_changes] || %{})}, state}

          "memory_access_refresh" ->
            {{:ok, state.inventory}, state}
        end
      end)
    end
  end

  defmodule ExtendedConnector do
    def connect(config), do: {:ok, config.test_connection}
  end

  defmodule InventoryChannel do
    def push(observer, "memory_access_refresh", %{}, _timeout) do
      send(observer, {:inventory_request, self()})

      receive do
        {:inventory_reply, inventory} -> {:ok, inventory}
      after
        1_000 -> {:error, :timeout}
      end
    end
  end

  defmodule NoHttp do
    def child_spec(_config), do: nil
  end

  defmodule RouterFacade do
    def call(method, args, context),
      do: MemoryFacade.call(method, args, Map.put(context, :remote_adapter, Remote))
  end

  setup %{tmp_dir: dir} do
    MemoryProxy.set_channel(nil)
    {:ok, store} = Store.start_link(database: Path.join(dir, "commands.db"), pool_size: 1)
    Process.unlink(store)
    :ok = Migrator.migrate(store)
    {:ok, edge} = Edge.Store.start_link(database: Path.join(dir, "mirror.db"), config: @config)
    Process.unlink(edge)
    :ok = Edge.Migrator.migrate(edge)
    {:ok, clock} = Agent.start_link(fn -> 10_000 end)
    {:ok, cache} = Backplane.HostAgent.Memory.RecallCache.start_link(name: nil)

    opts = [
      name: nil,
      store: store,
      edge_store: edge,
      edge_config: @config,
      recall_cache: cache,
      now_fun: fn -> Agent.get(clock, & &1) end
    ]

    {:ok, owner} = Access.start_link(opts)
    Process.unlink(owner)

    on_exit(fn ->
      for pid <- [owner, edge, store, clock, cache], Process.alive?(pid), do: GenServer.stop(pid)
      MemoryProxy.set_channel(nil)
    end)

    %{store: store, edge: edge, owner: owner, clock: clock, cache: cache, opts: opts}
  end

  test "cold start is closed and a fresh authenticated inventory permits online reads without mirror",
       c do
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, c.owner)
    assert :ok = install(c)
    assert {:ok, target, ticket} = Access.begin_request({:access_id, @id}, :read, c.owner)
    assert target.status == "needs_sync"

    assert {:ok, permitted, %{"results" => []}} =
             Access.finish_request(ticket, read_reply(target), c.owner)

    assert {:ok, :online} =
             Access.run_local(permitted, :read, fn _ -> {:ok, :online} end, c.owner)

    assert {:error, :stale_request} =
             Access.run_local(permitted, :read, fn _ -> flunk("permit reused") end, c.owner)

    assert {:error, :stale_request} = Access.finish_request(ticket, read_reply(target), c.owner)
  end

  test "source capabilities separate local support from negotiated canonical readiness", c do
    alias Backplane.HostAgent.MemorySourceFacade, as: Sources
    context = %{access_server: c.owner, agent_id: "Rikka"}

    assert {:ok, %{"supported" => true, "ready" => false}} =
             Sources.call("source_capabilities", %{}, context)

    assert :ok = install(c)
    assert {:ok, %{"ready" => false}} = Sources.call("source_capabilities", %{}, context)

    assert {:error, :unsupported_capability} =
             Sources.call("source_mutate", source_mutation(), context)

    assert :ok = install_sources(c)

    assert {:ok, %{"ready" => true, "binding" => binding}} =
             Sources.call("source_capabilities", %{}, context)

    assert binding["partition"] == @partition
    assert :ok = install_sources(c, 2, ["remember"])
    assert {:error, :unauthorized} = Sources.call("source_mutate", source_mutation(), context)
  end

  test "OpenClaw support is separately negotiated and capture retains its authority fingerprint",
       c do
    alias Backplane.HostAgent.MemorySourceFacade, as: Sources
    alias Backplane.HostAgent.Memory.OpenClawBinding
    context = %{access_server: c.owner, agent_id: "Rikka", sync_opts: [channel: nil]}

    args =
      source_mutation()
      |> put_in(["source", "integration"], "openclaw")
      |> put_in(["source", "target"], "provider")

    assert :ok = install_sources(c)

    assert {:ok, %{"ready" => false, "capture_error" => "unsupported_capability"}} =
             Sources.call("source_capabilities", %{"integration" => "openclaw"}, context)

    assert {:error, :unsupported_capability} = Sources.call("source_mutate", args, context)

    extensions =
      ~w(memory_access.v1 memory_commands.v2 memory_sources.v1 hermes_capture.v1 openclaw_source.v1 openclaw_capture.v1)

    selected = inventory() |> Map.put("extensions", extensions)
    assert :ok = Access.install_inventory(%{id: 2, sent_at_ms: 10_000}, selected, c.owner)

    assert {:ok,
            %{"ready" => true, "contracts" => contracts, "binding_fingerprint" => fingerprint}} =
             Sources.call("source_capabilities", %{"integration" => "openclaw"}, context)

    assert "openclaw_source.v1" in contracts
    assert :ok = OpenClawBinding.validate(fingerprint, c.owner)

    assert {:ok, :accepted, %{}} =
             OpenClawBinding.admit(fingerprint, fn -> {:ok, :accepted, %{}} end, c.owner)

    assert {:ok, %{"status" => "pending"}} = Sources.call("source_mutate", args, context)

    assert :ok =
             Access.install_inventory(
               %{id: 2, sent_at_ms: 10_000},
               inventory(2) |> Map.put("extensions", extensions),
               c.owner
             )

    assert {:error, :authority_changed} = OpenClawBinding.validate(fingerprint, c.owner)

    assert {:error, :authority_changed} =
             OpenClawBinding.admit(
               fingerprint,
               fn -> flunk("stale capture admitted") end,
               c.owner
             )
  end

  test "OpenClaw HTTP capture durably pins original binding and uploader refuses relabeling", c do
    alias Backplane.HostAgent.Memory.{OpenClawBinding, CaptureUploader}
    alias Backplane.HostAgent.Memory.Spool.Turso, as: CaptureSpool

    extensions =
      ~w(memory_access.v1 memory_commands.v2 memory_sources.v1 openclaw_source.v1 openclaw_capture.v1)

    assert :ok =
             Access.install_inventory(
               %{id: 2, sent_at_ms: 10_000},
               inventory() |> Map.put("extensions", extensions),
               c.owner
             )

    {:ok, _, fingerprint} = OpenClawBinding.current(c.owner)

    spool =
      start_supervised!(
        {CaptureSpool,
         database: Path.join(c.tmp_dir, "openclaw-capture.db"), name: nil, id: make_ref()}
      )

    original_runtime = Application.get_env(:backplane_host_agent, :capture_runtime)

    Application.put_env(:backplane_host_agent, :capture_runtime, %{
      host_id: "host",
      spool: spool,
      access_server: c.owner,
      config: %{inject_context: false}
    })

    on_exit(fn ->
      if original_runtime,
        do: Application.put_env(:backplane_host_agent, :capture_runtime, original_runtime),
        else: Application.delete_env(:backplane_host_agent, :capture_runtime)
    end)

    body = openclaw_capture(fingerprint)

    post = fn path, args ->
      Plug.Test.conn(:post, path, Jason.encode!(args))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Backplane.HostAgent.MemoryRouter.call(Backplane.HostAgent.MemoryRouter.init([]))
    end

    path = "/capture/v1/hooks/openclaw/message"
    assert %{status: 202} = post.(path, body)
    assert %{status: 202} = post.(path, body)
    assert [event] = CaptureSpool.next_batch(spool, 10, 500_000)
    assert get_in(event, ["payload", "source", "source_sequence"]) == 20
    assert event["sequence"] == 1

    status =
      post.("/capture/v1/status", %{
        "event_ids" => [body["event_id"]],
        "protocol" => "openclaw_capture.v1"
      })

    assert %{
             "result" => %{
               "protocol" => "openclaw_capture.v1",
               "items" => [%{"status" => "host_accepted"}]
             }
           } = Jason.decode!(status.resp_body)

    assert :ok =
             Access.install_inventory(
               %{id: 2, sent_at_ms: 10_000},
               inventory(2) |> Map.put("extensions", extensions),
               c.owner
             )

    assert %{status: 403} = post.(path, body)

    assert {:ok, %{"dead_lettered" => 1}} =
             CaptureUploader.drain_once(
               spool: spool,
               host_id: "host",
               channel: self(),
               access_server: c.owner
             )

    assert {:ok, %{state: :dead_letter, reason: "authority_changed"}} =
             CaptureSpool.event_status(spool, body["event_id"])

    assert [] = CaptureSpool.next_batch(spool, 10, 500_000)
  end

  defp openclaw_capture(fingerprint) do
    content = "Retained actual turn evidence"

    %{
      "protocol" => "openclaw_capture.v1",
      "event_id" => Ecto.UUID.generate(),
      "installation_id" => Ecto.UUID.generate(),
      "profile_id" => "primary",
      "source_sequence" => 20,
      "session_id" => "real-session",
      "run_id" => "real-run",
      "agent_id" => "rikka",
      "occurrence_id" => "real-run:0",
      "binding_fingerprint" => fingerprint,
      "role" => "user",
      "content" => content,
      "occurred_at" => "2026-10-26T01:00:00Z",
      "captured_at" => "2026-10-26T01:00:00Z",
      "completeness" => %{
        "truncated" => false,
        "coverage" => "full",
        "original_length" => String.length(content),
        "original_sha256" => Base.encode16(:crypto.hash(:sha256, content), case: :lower)
      }
    }
  end

  test "source commands bypass local content dedup and preserve immutable provenance", c do
    alias Backplane.HostAgent.MemorySourceFacade, as: Sources
    assert :ok = install_sources(c)
    context = %{access_server: c.owner, agent_id: "Rikka", sync_opts: [channel: nil]}
    args = source_mutation()

    assert {:ok, %{"status" => "pending", "event_id" => id}} =
             Sources.call("source_mutate", args, context)

    assert {:ok, %{"status" => "pending", "event_id" => ^id}} =
             Sources.call("source_mutate", args, context)

    assert {:error, :idempotency_conflict} =
             Sources.call("source_mutate", Map.put(args, "content", "changed"), context)

    assert {:error, :idempotency_conflict} =
             Sources.call("source_mutate", args, %{context | agent_id: "other"})

    second =
      args
      |> Map.put("event_id", Ecto.UUID.generate())
      |> Map.put("entry_id", Ecto.UUID.generate())

    assert {:ok, %{"status" => "pending"}} = Sources.call("source_mutate", second, context)

    assert {:ok, %{rows: rows}} =
             Store.query(c.store, "SELECT payload FROM memory_outbox ORDER BY seq")

    assert length(rows) == 2
    assert Enum.all?(rows, &(Jason.decode!(&1["payload"])["arguments"]["agent_id"] == "Rikka"))

    assert Enum.all?(
             rows,
             &(Jason.decode!(&1["payload"])["arguments"]["provenance"]["session_id"] ==
                 "actual-session")
           )
  end

  test "source ACK keeps canonical outcome and status is bound to original source and authority",
       c do
    alias Backplane.HostAgent.MemorySourceFacade, as: Sources
    assert :ok = install_sources(c)
    context = %{access_server: c.owner, agent_id: "Rikka", sync_opts: [channel: nil]}
    args = source_mutation()
    assert {:ok, %{"status" => "pending"}} = Sources.call("source_mutate", args, context)
    [row] = rows = claim(c)

    source_result = %{
      "protocol" => "memory_sources.v1",
      "event_id" => args["event_id"],
      "status" => "committed",
      "outcome" => "applied",
      "canonical_id" => "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      "revision" => 9,
      "source_revision" => 1,
      "authority" => "canonical",
      "consistency" => "canonical"
    }

    ack = ack(row, "committed") |> Map.put("source_result", source_result)
    assert {:ok, %{drained: 1}} = settle(c, rows, ack)
    status = Map.take(args, ~w(protocol source event_id))

    assert {:ok,
            %{
              "status" => "committed",
              "outcome" => "applied",
              "revision" => 9,
              "authority" => "canonical"
            }} = Sources.call("source_status", status, context)

    assert {:error, :not_found} =
             Sources.call(
               "source_status",
               put_in(status, ["source", "profile_id"], "different"),
               context
             )

    assert :ok = install_sources(c, 2)
    assert {:error, :not_found} = Sources.call("source_status", status, context)
  end

  test "revoking either source grant dead letters pending source commands", c do
    alias Backplane.HostAgent.MemorySourceFacade, as: Sources
    assert :ok = install_sources(c)
    context = %{access_server: c.owner, agent_id: "Rikka", sync_opts: [channel: nil]}

    assert {:ok, %{"status" => "pending"}} =
             Sources.call("source_mutate", source_mutation(), context)

    assert :ok = install_sources(c, 2, ["remember"])

    assert {:ok, %{rows: [%{"state" => "dead_letter", "last_error" => "authority_changed"}]}} =
             Store.query(c.store, "SELECT state,last_error FROM memory_outbox")

    assert [] == claim(c)
  end

  for stale_channel <- [:provider, :access] do
    @tag stale_channel: stale_channel
    test "dead #{stale_channel} channel preserves source commands until authenticated reconnect",
         c do
      alias Backplane.HostAgent.Memory.Syncer
      alias Backplane.HostAgent.MemorySourceFacade, as: Sources

      assert :ok = install_sources(c)
      context = %{access_server: c.owner, agent_id: "Rikka"}
      args = source_mutation()
      assert {:ok, %{"status" => "pending"}} = Sources.call("source_mutate", args, context)
      assert {:ok, %{rows: [original]}} = Store.query(c.store, "SELECT * FROM memory_outbox")
      assert original["state"] == "pending"
      assert original["attempts"] == 0

      {:ok, channel} = Agent.start_link(fn -> nil end)
      GenServer.stop(channel)
      refute Process.alive?(channel)

      negotiated =
        inventory()
        |> Map.put("extensions", ~w(memory_access.v1 memory_commands.v2 memory_sources.v1))

      assert :ok =
               Access.install_inventory(
                 %{id: 2, sent_at_ms: 10_000, channel: channel},
                 negotiated,
                 c.owner
               )

      MemoryProxy.set_channel(if(c.stale_channel == :provider, do: channel, else: self()))
      opts = [store: c.store, access_server: c.owner, channel_module: SourceChannel]
      results = for _ <- 1..6, do: Syncer.drain_shared(opts)

      assert {:ok, %{rows: [^original]}} = Store.query(c.store, "SELECT * FROM memory_outbox")
      assert Enum.all?(results, &(&1 == {:error, :not_connected}))
      refute_received {:source_dispatch, _, _}
      assert {:ok, %{"status" => "pending"}} = Sources.call("source_mutate", args, context)

      assert :ok =
               Access.install_inventory(
                 %{id: 3, sent_at_ms: 10_000, channel: self()},
                 negotiated,
                 c.owner
               )

      MemoryProxy.set_channel(self())
      assert {:ok, %{drained: 1}} = Syncer.drain_shared(opts)
      assert_receive {:source_dispatch, _, %{"items" => [payload]}}
      assert payload == Jason.decode!(original["payload"])
      assert {:ok, %{rows: [settled]}} = Store.query(c.store, "SELECT * FROM memory_outbox")
      assert settled["state"] == "done"
      assert settled["attempts"] == 0
      assert settled["payload"] == original["payload"]
      assert settled["payload_digest"] == original["payload_digest"]
      assert settled["command_id"] == original["command_id"]

      assert {:ok, %{"status" => "committed", "authority" => "canonical", "revision" => 9}} =
               Sources.call(
                 "source_status",
                 Map.take(args, ~w(protocol source event_id)),
                 context
               )
    end
  end

  test "source push transport failure counts once and dead channel drains preserve retry state",
       c do
    alias Backplane.HostAgent.Memory.Syncer
    alias Backplane.HostAgent.MemorySourceFacade, as: Sources

    assert :ok = install_sources(c)
    {:ok, channel} = Agent.start_link(fn -> nil end)

    context = %{
      access_server: c.owner,
      agent_id: "Rikka",
      sync_opts: [channel: channel, channel_module: DiesOnPush]
    }

    assert {:ok, %{"status" => "pending"}} =
             Sources.call("source_mutate", source_mutation(), context)

    refute Process.alive?(channel)
    assert {:ok, %{rows: [attempted]}} = Store.query(c.store, "SELECT * FROM memory_outbox")
    assert attempted["state"] == "retry_wait"
    assert attempted["attempts"] == 1
    assert attempted["last_error"] == "transport_failure"

    for _ <- 1..6 do
      assert {:error, :not_connected} =
               Syncer.drain_shared(store: c.store, access_server: c.owner, channel: channel)
    end

    assert {:ok, %{rows: [^attempted]}} = Store.query(c.store, "SELECT * FROM memory_outbox")

    assert {:ok, %{drained: 1}} =
             Syncer.drain_shared(
               store: c.store,
               access_server: c.owner,
               channel: self(),
               channel_module: SourceChannel
             )

    assert {:ok, %{rows: [settled]}} = Store.query(c.store, "SELECT * FROM memory_outbox")
    assert settled["state"] == "done"
    assert settled["attempts"] == 1
    assert settled["payload"] == attempted["payload"]
    assert settled["payload_digest"] == attempted["payload_digest"]
  end

  defp install_sources(c, version \\ 1, caps \\ ~w(read deliver remember forget)) do
    inventory =
      inventory(version, 0, caps)
      |> Map.put("extensions", ~w(memory_access.v1 memory_commands.v2 memory_sources.v1))

    Access.install_inventory(%{id: 1, sent_at_ms: 10_000}, inventory, c.owner)
  end

  defp source_mutation do
    %{
      "protocol" => "memory_sources.v1",
      "event_id" => "2699493c-6347-4138-baba-8b09393a8500",
      "entry_id" => "34aa960d-50c9-4086-ad8e-06f9a340b03f",
      "source" => %{
        "integration" => "hermes",
        "installation_id" => "b6b8672a-74a0-4df7-b533-ec0a99f49df8",
        "profile_id" => "default",
        "target" => "memory"
      },
      "revision" => 1,
      "operation" => "upsert",
      "content" => "same canonical content",
      "type" => "semantic",
      "occurred_at" => "2026-10-24T01:00:00Z",
      "provenance" => %{"session_id" => "actual-session"}
    }
  end

  test "unknown selectors and unsupported capabilities never fall back", c do
    assert :ok = install(c, 1, 0, ["remember"])
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @other}, :read, c.owner)
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, c.owner)
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :forget, c.owner)
    assert {:ok, _, _} = Access.begin_request({:access_id, @id}, :remember, c.owner)
    assert {:error, :invalid_request} = Access.begin_request({:access_id, @id}, :capture, c.owner)
  end

  test "target revocation is durable before unavailable mirror cleanup and same version cannot revive it",
       c do
    assert :ok = install(c)
    assert :ok = Access.fence({:access_id, @id}, :unauthorized, 1, c.owner)

    assert {:ok, %{rows: [%{"status" => "fenced"}]}} =
             Store.query(c.store, "SELECT status FROM memory_access_state WHERE access_id=?", [
               @id
             ])

    assert :ok = install(c)
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, c.owner)
    GenServer.stop(c.owner)
    {:ok, restarted} = Access.start_link(Keyword.put(c.opts, :edge_store, :missing_mirror))
    Process.unlink(restarted)
    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, restarted)
    assert :ok = install(%{c | owner: restarted})
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, restarted)
    assert :ok = install(%{c | owner: restarted}, 2)
    assert {:ok, target, _} = Access.begin_request({:access_id, @id}, :read, restarted)
    assert target.status == "needs_sync"
  end

  test "fresh credentials recover global fences but never clear a durable target revoke", c do
    assert :ok = install(c)
    assert :ok = Access.fence(:all, :connection_rejected, 1, c.owner)
    assert :ok = Access.install_inventory(%{id: 2, sent_at_ms: 10_000}, inventory(), c.owner)
    assert {:ok, _, _} = Access.begin_request({:access_id, @id}, :read, c.owner)
    assert :ok = Access.fence({:access_id, @id}, :authority_changed, 2, c.owner)
    assert :ok = Access.fence(:all, :connection_rejected, 2, c.owner)
    assert :ok = Access.install_inventory(%{id: 3, sent_at_ms: 10_000}, inventory(), c.owner)
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, c.owner)
  end

  test "target fence serializes with composed mirror and pending/ACK overlay release", c do
    on_exit(fn -> stop_fault_owner(c.owner) end)
    assert :ok = install(c, 1, 5)
    target = activate(c, [protected_item("canonical-protected", "canonical protected")])
    {:ok, _} = enqueue(c, target, "remember", %{"content" => "ack protected"})
    rows = claim(c)
    assert {:ok, %{drained: 1}} = settle(c, rows, ack(hd(rows), "committed"))
    {:ok, pending} = enqueue(c, target, "remember", %{"content" => "pending protected"})
    parent = self()
    gate = make_ref()

    reader =
      Task.async(fn ->
        composed_read(c, target, fn ->
          send(parent, {:composition_ready, gate})

          receive do
            {:release_composition, ^gate} -> :ok
          after
            2_000 -> flunk("composition barrier was not released")
          end
        end)
      end)

    try do
      assert_receive {:composition_ready, ^gate}, 1_000

      # Both real calls originate here, so mailbox ordering fixes the race without
      # relying on scheduler timing: composition, fence, then the later read.
      fence = :gen_server.send_request(c.owner, {:fence, {:access_id, @id}, :unauthorized, 1})

      later_read =
        :gen_server.send_request(
          c.owner,
          {:local, target, :read,
           fn _ ->
             send(parent, {:forbidden_composition, gate})
             {:ok, %{"content" => "must not escape"}}
           end}
        )

      assert {:messages, messages} = Process.info(c.owner, :messages)
      requests = for {:"$gen_call", _, request} <- messages, do: request

      assert [
               {:fence, {:access_id, @id}, :unauthorized, 1},
               {:local, ^target, :read, _}
             ] = requests

      assert Task.yield(reader, 0) == nil
      send(c.owner, {:release_composition, gate})
      assert {:ok, result} = Task.await(reader, 2_000)

      assert Enum.sort(Enum.map(result["items"], & &1["content"])) ==
               ["ack protected", "canonical protected", "pending protected"]

      assert result["pending_operations"] == 1
      assert result["acknowledged_operations"] == 1
      assert :gen_server.wait_response(fence, 2_000) == {:reply, :ok}
      assert :gen_server.wait_response(later_read, 2_000) == {:reply, {:error, :unauthorized}}
      refute_received {:forbidden_composition, ^gate}
      assert {:error, :unauthorized} = composed_read(c, target)

      assert {:ok, %{rows: [%{"state" => "dead_letter"}]}} =
               Store.query(c.store, "SELECT state FROM memory_outbox WHERE command_id=?", [
                 pending["command_id"]
               ])
    after
      if Process.alive?(reader.pid) do
        send(c.owner, {:release_composition, gate})
        Task.shutdown(reader, :brutal_kill)
      end
    end
  end

  test "owner crash after durable target fence cannot expose an uncleaned mirror after store reopen",
       c do
    on_exit(fn -> stop_fault_owner(c.owner) end)
    assert :ok = install(c, 1, 5)
    item = protected_item("crash-protected", "crash protected")
    target = activate(c, [item])
    {:ok, pending} = enqueue(c, target, "remember", %{"content" => "crash pending"})
    assert {:ok, %{"items" => [%{"content" => "crash protected"}]}} = local_read(c, target)
    sql = "SELECT active_generation,sync_status,access_id,authority_version FROM edge_partitions"
    assert {:ok, %{rows: [before_mirror]}} = Store.query(c.edge, sql)
    parent = self()
    gate = make_ref()

    holder =
      Task.async(fn ->
        Store.transaction(c.edge, fn _conn ->
          send(parent, {:mirror_checkout_held, gate})

          receive do
            {:release_mirror, ^gate} -> :ok
          after
            3_000 -> flunk("mirror checkout barrier was not released")
          end
        end)
      end)

    try do
      assert_receive {:mirror_checkout_held, ^gate}, 1_000
      :erlang.trace_pattern({Mirror.Store, :fence, 2}, true, [:local])
      :erlang.trace(c.owner, true, [:call])
      fence = :gen_server.send_request(c.owner, {:fence, {:access_id, @id}, :unauthorized, 1})
      owner = c.owner
      edge = c.edge

      # This call occurs only after the independent command transaction commits.
      # The held real edge checkout prevents cleanup from starting its transaction.
      assert_receive {:trace, ^owner, :call, {Mirror.Store, :fence, [^edge, _]}}, 1_000

      assert {:ok, %{rows: [%{"status" => "fenced", "fence_reason" => "unauthorized"}]}} =
               Store.query(
                 c.store,
                 "SELECT status,fence_reason FROM memory_access_state WHERE access_id=?",
                 [@id]
               )

      assert {:ok, %{rows: [%{"state" => "dead_letter"}]}} =
               Store.query(c.store, "SELECT state FROM memory_outbox WHERE command_id=?", [
                 pending["command_id"]
               ])

      monitor = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 1_000
      assert {:error, _} = :gen_server.wait_response(fence, 1_000)
      send(holder.pid, {:release_mirror, gate})
      assert Task.await(holder, 1_000) == {:ok, :ok}
    after
      :erlang.trace_pattern({Mirror.Store, :fence, 2}, false, [:local])
      if Process.alive?(c.owner), do: :erlang.trace(c.owner, false, [:call])
      send(holder.pid, {:release_mirror, gate})
      if Process.alive?(holder.pid), do: Task.shutdown(holder, :brutal_kill)
    end

    GenServer.stop(c.store)
    GenServer.stop(c.edge)
    {:ok, store} = Store.start_link(database: Path.join(c.tmp_dir, "commands.db"), pool_size: 1)
    Process.unlink(store)
    on_exit(fn -> stop_fault_owner(store) end)

    {:ok, edge} =
      Edge.Store.start_link(database: Path.join(c.tmp_dir, "mirror.db"), config: @config)

    Process.unlink(edge)
    on_exit(fn -> stop_fault_owner(edge) end)
    opts = c.opts |> Keyword.put(:store, store) |> Keyword.put(:edge_store, edge)
    {:ok, owner} = Access.start_link(opts)
    Process.unlink(owner)
    on_exit(fn -> stop_fault_owner(owner) end)

    reopened = %{c | owner: owner, edge: edge, store: store}
    assert {:ok, %{rows: [^before_mirror]}} = Store.query(edge, sql)

    assert {:ok, %{rows: [%{"content" => "crash protected"}]}} =
             Store.query(edge, "SELECT content FROM edge_memories WHERE canonical_id=?", [
               item["canonical_id"]
             ])

    assert {:error, :unauthorized} = composed_read(reopened, target)
    assert :ok = install(reopened, 1, 5)
    assert {:error, :unauthorized} = composed_read(reopened, target)
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, owner)
    assert :ok = install(reopened, 2, 5)
    assert {:error, :no_committed_mirror} = local_read(reopened, %{target | authority_version: 2})
    fresh = activate(reopened, [item])

    assert {:ok, %{"items" => [%{"content" => "crash protected"}]}} =
             composed_read(reopened, fresh)
  end

  test "old channel inventories and replies cannot fence or revive the current connection", c do
    assert :ok = install(c)
    assert {:ok, target, ticket} = Access.begin_request({:access_id, @id}, :read, c.owner)
    assert :ok = Access.install_inventory(%{id: 2, sent_at_ms: 10_000}, inventory(), c.owner)

    assert {:error, :stale_connection} =
             Access.install_inventory(%{id: 1, sent_at_ms: 10_000}, %{}, c.owner)

    assert {:error, :stale_request} = Access.finish_request(ticket, read_reply(target), c.owner)

    assert {:error, :stale_request} =
             Access.finish_request(ticket, {:error, :unauthorized}, c.owner)

    assert {:ok, _, _} = Access.begin_request({:access_id, @id}, :read, c.owner)
  end

  test "real channel call exits leave shared authority admissible through the edge syncer", c do
    for failure <- [:noproc, :timeout] do
      channel = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(channel, :stop) end)

      if failure == :noproc do
        ref = Process.monitor(channel)
        send(channel, :stop)
        assert_receive {:DOWN, ^ref, :process, ^channel, :normal}
      end

      negotiated = delivery_inventory(inventory())
      {syncer, generation} = start_access_feed(c, negotiated, channel, CallChannel)
      assert eventually(fn -> Edge.Syncer.diagnostics(syncer)["last_poll_result"] == "error" end)
      diagnostic = Edge.Syncer.diagnostics(syncer)
      assert diagnostic["last_stage"] == "memory_next"
      assert diagnostic["last_error"] == "channel_exit"
      assert diagnostic["retry_scheduled"]
      assert {:ok, _, _} = Access.begin_request({:access_id, @id}, :deliver, c.owner)
      assert [%{status: "needs_sync", fence_reason: nil}] = Access.status(c.owner).accesses
      assert :ok = Access.install_inventory(generation, negotiated, c.owner)
      assert {:ok, _, _} = Access.begin_request({:access_id, @id}, :read, c.owner)
      Edge.Syncer.stop(syncer)
      send(channel, :stop)
    end
  end

  test "unknown channel exits and permanent denials still fence their intended authority", c do
    reasons = [
      {:channel_exit, :unclassified_failure},
      {:channel_exit, {:unauthorized, :detail}},
      {:unknown_wrapper, :timeout},
      :unauthorized,
      :authority_changed,
      :partition_mismatch,
      :invalid_protocol,
      :protocol_mismatch,
      %{"code" => "unauthorized", "retryable" => false}
    ]

    for {reason, version} <- Enum.with_index(reasons, 1) do
      negotiated =
        Map.update!(two_accesses(), "accesses", fn entries ->
          Enum.map(entries, &Map.put(&1, "authority_version", version))
        end)

      assert :ok =
               Access.install_inventory(%{id: version, sent_at_ms: 10_000}, negotiated, c.owner)

      assert {:ok, _, ticket} = Access.begin_request({:access_id, @id}, :deliver, c.owner)
      assert {:error, ^reason} = Access.finish_request(ticket, {:error, reason}, c.owner)
      assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, c.owner)

      if is_map(reason) do
        assert Access.status(c.owner).global_fenced

        assert {:error, :unauthorized} =
                 Access.begin_request({:access_id, @other}, :read, c.owner)
      else
        refute Access.status(c.owner).global_fenced
        assert {:ok, _, _} = Access.begin_request({:access_id, @other}, :read, c.owner)
      end
    end
  end

  test "automatic polling passes a fenced first grant and completes the second grant snapshot",
       c do
    observer = self()
    second_partition = Map.put(@partition, "namespace", "second")

    negotiated =
      two_accesses()
      |> Map.update!("accesses", fn [first, second] ->
        [first, Map.put(second, "partition", second_partition)]
      end)
      |> delivery_inventory()

    {:ok, channel} =
      Agent.start_link(fn -> %{owner: observer, sent: MapSet.new(), inventory: negotiated} end)

    on_exit(fn -> if Process.alive?(channel), do: Agent.stop(channel) end)

    assert :ok = Access.install_inventory(%{id: 1, sent_at_ms: 10_000}, negotiated, c.owner)
    assert :ok = Access.fence({:access_id, @id}, :unauthorized, 1, c.owner)

    {syncer, _} =
      start_access_feed(c, negotiated, channel, FeedChannel, poll_interval_ms: 50)

    assert_receive {:feed, "memory_next", %{"access" => %{"access_id" => @other}}}, 2_000
    assert_receive {:feed, "memory_ack", %{"access" => %{"access_id" => @other}}}, 2_000

    assert %{"last_poll_result" => "ok", "last_stage" => "ack_commit"} =
             Edge.Syncer.diagnostics(syncer)

    Edge.Syncer.stop(syncer)
    refute_receive {:feed, "memory_next", %{"access" => %{"access_id" => @id}}}
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, c.owner)

    assert {:ok, %{status: "active"} = target, _} =
             Access.begin_request({:access_id, @other}, :read, c.owner)

    assert Mirror.Store.complete?(c.edge, target)

    assert Enum.find(Access.status(c.owner).accesses, &(&1.access_id == @id)).fence_reason ==
             "unauthorized"
  end

  test "fresh replacement credentials narrow and widen effective capabilities without reusing a mirror",
       c do
    assert :ok = install(c, 1, 1)
    target = activate(c)
    assert {:ok, _} = local_read(c, target)
    {:ok, remember} = enqueue(c, target, "remember", %{"content" => "pending remember"})

    {:ok, forget} =
      enqueue(c, target, "forget", %{"id" => "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"})

    assert :ok =
             Access.install_inventory(
               %{id: 2, sent_at_ms: 10_000},
               inventory(1, 1, ~w(read deliver forget)),
               c.owner
             )

    assert {:ok, narrowed, _} = Access.begin_request({:access_id, @id}, :read, c.owner)
    assert narrowed.status == "needs_sync"
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :remember, c.owner)
    assert {:error, :no_committed_mirror} = local_read(c, narrowed)

    assert {:ok, %{rows: rows}} =
             Store.query(c.store, "SELECT command_id,state FROM memory_outbox ORDER BY seq")

    assert rows == [
             %{"command_id" => remember["command_id"], "state" => "dead_letter"},
             %{"command_id" => forget["command_id"], "state" => "pending"}
           ]

    assert :ok =
             Access.install_inventory(
               %{id: 3, sent_at_ms: 10_000},
               inventory(1, 0, ["remember"]),
               c.owner
             )

    assert {:ok, import_only, _} = Access.begin_request({:access_id, @id}, :remember, c.owner)
    assert import_only.status == "needs_sync"
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, c.owner)
    assert :ok = Access.install_inventory(%{id: 4, sent_at_ms: 10_000}, inventory(1, 1), c.owner)
    assert {:ok, widened, _} = Access.begin_request({:access_id, @id}, :remember, c.owner)
    assert widened.status == "needs_sync"
    assert {:error, :no_committed_mirror} = local_read(c, widened)
  end

  test "missing private default never retargets an omitted selector to an explicit shared grant",
       c do
    negotiated = Map.put(inventory(), "default_access_id", nil)
    assert :ok = Access.install_inventory(%{id: 1, sent_at_ms: 10_000}, negotiated, c.owner)
    assert {:error, :unauthorized} = Access.begin_request(:default, :read, c.owner)
    assert {:ok, _, _} = Access.begin_request({:access_id, @id}, :read, c.owner)
  end

  test "same-generation capability changes fence until fresh credentials and never clear grant revocation",
       c do
    assert :ok = install(c, 1, 0, ["remember"])
    assert :ok = install(c)
    assert [%{fence_reason: "credential_policy"}] = Access.status(c.owner).accesses
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, c.owner)
    assert :ok = install(c)
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :remember, c.owner)
    assert :ok = Access.install_inventory(%{id: 2, sent_at_ms: 10_000}, inventory(), c.owner)
    assert {:ok, recovered, _} = Access.begin_request({:access_id, @id}, :read, c.owner)
    assert recovered.status == "needs_sync"
    assert :ok = Access.fence({:access_id, @id}, :authority_changed, 2, c.owner)

    assert :ok =
             Access.install_inventory(
               %{id: 3, sent_at_ms: 10_000},
               inventory(1, 0, ["remember"]),
               c.owner
             )

    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :remember, c.owner)
  end

  test "structured shared credential denial fences every grant and private intent and clears lifecycle cache",
       c do
    Process.register(c.owner, Access)
    generation = %{id: 1, sent_at_ms: 10_000, channel: self()}

    assert :ok =
             MemoryProxy.set_connection(
               %{channel: self(), memory: two_accesses(), memory_generation: generation},
               %{}
             )

    assert :ok =
             Backplane.HostAgent.Memory.RecallCache.put(c.cache, :private, %{
               "content" => "cached"
             })

    {:ok, _, ticket} = Access.begin_request({:access_id, @id}, :read, c.owner)
    denial = %{"code" => "unauthorized", "retryable" => false}

    assert {:error, ^denial} =
             MemoryProxy.call("list", %{},
               agent_id: "actor-b",
               channel_module: DeniedReadChannel,
               access: %{"access_id" => @id, "authority_version" => 1},
               connection_generation: 1
             )

    assert {:error, ^denial} = Access.finish_request(ticket, {:error, denial}, c.owner)
    assert Access.status(c.owner).global_fenced
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @other}, :read, c.owner)
    assert {:error, ^denial} = MemoryProxy.authorize_command()
    assert :miss = Backplane.HostAgent.Memory.RecallCache.get(c.cache, :private)
  end

  test "target-only denial preserves other grants and cache while shared command credential denial closes all",
       c do
    generation = %{id: 1, sent_at_ms: 10_000, channel: self()}
    Process.register(c.owner, Access)

    assert :ok =
             MemoryProxy.set_connection(
               %{channel: self(), memory: two_accesses(), memory_generation: generation},
               %{}
             )

    assert :ok =
             Backplane.HostAgent.Memory.RecallCache.put(c.cache, :private, %{
               "content" => "cached"
             })

    {:ok, _, ticket} = Access.begin_request({:access_id, @id}, :read, c.owner)

    assert {:error, "unauthorized"} =
             Access.finish_request(ticket, {:error, "unauthorized"}, c.owner)

    refute Access.status(c.owner).global_fenced
    assert :ok = MemoryProxy.authorize_command()
    assert {:ok, _} = Backplane.HostAgent.Memory.RecallCache.get(c.cache, :private)
    {:ok, target, _} = Access.begin_request({:access_id, @other}, :remember, c.owner)
    {:ok, _} = enqueue(c, target, "remember", %{"content" => "pending"})
    Process.put({SharedChannel, :mode}, :credential_denied)

    assert {:ok, %{drained: 0}} =
             Backplane.HostAgent.Memory.Syncer.drain_shared(
               store: c.store,
               access_server: c.owner,
               channel: self(),
               channel_module: SharedChannel
             )

    assert Access.status(c.owner).global_fenced
    assert {:error, %{"code" => "unauthorized"}} = MemoryProxy.authorize_command()
    assert :miss = Backplane.HostAgent.Memory.RecallCache.get(c.cache, :private)
  end

  test "snapshot authority cannot be read outside owner; lease expires before and during composed reads",
       c do
    assert :ok = install(c, 1, 1)
    target = activate(c)

    assert {:error, :unauthorized} =
             Mirror.offline_read("list", @partition, store: c.edge, config: @config)

    assert {:ok, %{"items" => []}} = local_read(c, target)
    Agent.update(c.clock, fn _ -> 10_999 end)

    assert {:error, :access_lease_expired} =
             Access.run_local(
               target,
               :read,
               fn _ ->
                 Agent.update(c.clock, fn _ -> 11_000 end)
                 {:ok, %{"content" => "must not escape"}}
               end,
               c.owner
             )

    assert {:error, :access_lease_expired} = local_read(c, target)
  end

  test "lease zero denies shared fallback while authoritative private omission retains offline policy",
       c do
    assert :ok = install(c)
    target = activate(c)
    assert {:error, :access_lease_expired} = local_read(c, target)
    assert {:ok, %{"items" => []}} = local_read(c, Map.put(target, :local_mode, :private_default))
  end

  test "ACK responses and notifications cannot renew a lease", c do
    assert :ok = install(c, 1, 1)
    _ = activate(c)
    Agent.update(c.clock, fn _ -> 10_900 end)
    assert {:ok, target, ticket} = Access.begin_request({:access_id, @id}, :deliver, c.owner)
    reply = %{"access" => Access.claim(target), "partition" => @partition, "status" => "advanced"}
    assert {:ok, _, _} = Access.finish_request(ticket, {:ok, reply}, c.owner)
    [entry] = Access.status(c.owner).accesses
    assert entry.deadline == 11_000
  end

  test "complete inventory removal closes mirror and rejects old pending commands", c do
    assert :ok = install(c, 1, 5)
    target = activate(c)

    assert {:ok, receipt} =
             enqueue(c, target, "remember", %{"content" => "pending", "idempotency_key" => "one"})

    assert :ok =
             Access.install_inventory(
               %{id: 1, sent_at_ms: 10_000},
               %{
                 "extensions" => ["memory_access.v1", "memory_commands.v2"],
                 "accesses" => [],
                 "default_access_id" => nil
               },
               c.owner
             )

    assert {:error, :unauthorized} = local_read(c, target)

    assert {:ok, %{rows: [%{"state" => "dead_letter"}]}} =
             Store.query(c.store, "SELECT state FROM memory_outbox WHERE command_id=?", [
               receipt["command_id"]
             ])
  end

  test "shared command target and payload are durable immutable identities", c do
    assert :ok = install(c)
    {:ok, target, _} = Access.begin_request({:access_id, @id}, :remember, c.owner)

    args = %{
      "content" => "one",
      "idempotency_key" => "stable",
      "facets" => [%{"dimension" => "topic", "value" => "memory"}]
    }

    assert {:ok, receipt} = enqueue(c, target, "remember", args)
    assert {:ok, ^receipt} = enqueue(c, target, "remember", args)

    assert {:error, :idempotency_conflict} =
             enqueue(c, target, "remember", Map.put(args, "content", "two"))

    assert {:error, _} =
             Store.execute(
               c.store,
               "UPDATE memory_outbox SET authority_version=2 WHERE command_id=?",
               [receipt["command_id"]]
             )

    assert :ok = install(c, 2)
    {:ok, new_target, _} = Access.begin_request({:access_id, @id}, :remember, c.owner)
    assert {:error, :idempotency_conflict} = enqueue(c, new_target, "remember", args)

    assert {:ok, %{rows: [%{"count" => 0}]}} =
             Store.query(c.store, "SELECT COUNT(*) AS count FROM memories")
  end

  test "rejected ACK is a permanent error and cannot release provisional success", c do
    assert :ok = install(c)
    {:ok, target, _} = Access.begin_request({:access_id, @id}, :remember, c.owner)
    {:ok, receipt} = enqueue(c, target, "remember", %{"content" => "denied"})
    rows = claim(c)
    ack = ack(hd(rows), "rejected") |> Map.put("code", "unauthorized")
    assert {:ok, %{drained: 1}} = settle(c, rows, ack)

    assert {:error, :unauthorized} =
             Access.run_local(
               target,
               :remember,
               &Memory.shared_receipt(&1, receipt["command_id"]),
               c.owner
             )

    assert {:ok, %{rows: [%{"state" => "dead_letter"}]}} =
             Store.query(c.store, "SELECT state FROM memory_outbox WHERE command_id=?", [
               receipt["command_id"]
             ])
  end

  test "late committed ACK settles after revoke without exposing overlay or reopening authority",
       c do
    assert :ok = install(c, 1, 5)
    target = activate(c)
    {:ok, receipt} = enqueue(c, target, "remember", %{"content" => "late secret"})
    rows = claim(c)
    assert :ok = Access.fence({:access_id, @id}, :unauthorized, 1, c.owner)
    assert {:ok, %{drained: 1}} = settle(c, rows, ack(hd(rows), "committed"))

    assert {:ok, %{rows: [%{"state" => "done"}]}} =
             Store.query(c.store, "SELECT state FROM memory_outbox WHERE command_id=?", [
               receipt["command_id"]
             ])

    assert {:error, :unauthorized} = local_read(c, target)
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, c.owner)
  end

  test "explicit facade strips selector/scope, preserves source and rejects raw authority before enqueue",
       c do
    assert :ok = install(c)
    context = %{access_server: c.owner, agent_id: "actor-b", remote_adapter: Remote}

    assert {:ok, result} =
             MemoryFacade.call("list", %{"memory_access_id" => @id, "scope" => "shared"}, context)

    assert hd(result["results"])["source_host_id"] == "author-a"
    assert_receive {:shared_remote, args, opts}
    refute Map.has_key?(args, "memory_access_id")
    refute Map.has_key?(args, "scope")
    assert opts[:access]["access_id"] == @id

    for args <- [
          %{"memory_access_id" => @id, "memory_space_id" => @partition["memory_space_id"]},
          %{"memory_access_id" => @id, "scope" => "global"}
        ] do
      assert {:error, :invalid_request} =
               MemoryFacade.call("remember", Map.put(args, "content", "blocked"), context)
    end

    assert {:ok, %{rows: [%{"count" => 0}]}} =
             Store.query(c.store, "SELECT COUNT(*) AS count FROM memory_outbox")
  end

  test "same caller request key in two accesses remains independently bound and receipts cannot cross targets",
       c do
    offered = inventory()

    other =
      hd(offered["accesses"])
      |> Map.put("access_id", @other)
      |> put_in(["partition", "memory_space_id"], "cccccccc-cccc-4ccc-8ccc-cccccccccccc")

    assert :ok =
             Access.install_inventory(
               %{id: 1, sent_at_ms: 10_000},
               Map.update!(offered, "accesses", &(&1 ++ [other])),
               c.owner
             )

    {:ok, first, _} = Access.begin_request({:access_id, @id}, :remember, c.owner)
    {:ok, second, _} = Access.begin_request({:access_id, @other}, :remember, c.owner)
    args = %{"content" => "same caller intent", "idempotency_key" => "caller-key"}
    assert {:ok, a} = enqueue(c, first, "remember", args)
    assert {:ok, b} = enqueue(c, second, "remember", args)
    refute a["command_id"] == b["command_id"]

    assert {:error, :not_found} =
             Access.run_local(
               second,
               :remember,
               &Memory.shared_receipt(&1, a["command_id"]),
               c.owner
             )

    assert {:ok, %{rows: rows}} =
             Store.query(
               c.store,
               "SELECT access_id,authority_version,target_partition,payload_digest FROM memory_outbox ORDER BY seq"
             )

    assert Enum.map(rows, & &1["access_id"]) == [@id, @other]
    refute hd(rows)["payload_digest"] == List.last(rows)["payload_digest"]
  end

  test "interrupted shared snapshot cannot activate old authority after regrant", c do
    assert :ok = install(c, 1, 1)
    {:ok, target, ticket} = Access.begin_request({:access_id, @id}, :deliver, c.owner)
    frame = snapshot(Access.claim(target))

    manifest =
      "sha256:" <>
        Base.encode16(:crypto.hash(:sha256, [frame["chunk_hash"], frame["chunk_hash"]]),
          case: :lower
        )

    frame = Map.merge(frame, %{"chunk_count" => 2, "integrity_hash" => manifest})
    {:ok, permitted, _} = Access.finish_request(ticket, {:ok, frame}, c.owner)

    assert {:ok, _} =
             Access.run_local(
               permitted,
               :deliver,
               fn _ -> Mirror.apply_delivery(frame, store: c.edge, config: @config) end,
               c.owner
             )

    assert hd(Access.status(c.owner).accesses).status == "needs_sync"
    assert {:error, :no_committed_mirror} = local_read(c, target)
    {:ok, _, old_ticket} = Access.begin_request({:access_id, @id}, :deliver, c.owner)
    assert :ok = install(c, 2, 1)
    final = frame |> Map.put("chunk_index", 1) |> Map.put("batch_id", "late-old-chunk")
    assert {:error, :stale_request} = Access.finish_request(old_ticket, {:ok, final}, c.owner)
    current = activate(c)
    assert current.authority_version == 2
    assert {:ok, %{"items" => []}} = local_read(c, current)
  end

  test "inventory bounds and malformed response do not create a lease or release protected data",
       c do
    assert :ok = install(c, 1, 1)
    target = activate(c)
    {:ok, _, ticket} = Access.begin_request({:access_id, @id}, :deliver, c.owner)

    malformed =
      snapshot(Access.claim(target))
      |> Map.put("chunk_hash", "sha256:" <> String.duplicate("0", 64))

    assert {:error, :authority_changed} = Access.finish_request(ticket, {:ok, malformed}, c.owner)
    assert {:error, :unauthorized} = local_read(c, target)
    assert {:error, :invalid_inventory} = install(c, 2, 301)
    assert Access.status(c.owner).global_fenced
  end

  test "V2 drain retries lost ACK identity, keeps private rows V1, and rejects successful-transport denial",
       c do
    assert :ok = install(c)
    {:ok, target, _} = Access.begin_request({:access_id, @id}, :remember, c.owner)

    {:ok, receipt} =
      enqueue(c, target, "remember", %{
        "content" => "shared command",
        "idempotency_key" => "retry"
      })

    {:ok, _} =
      Memory.remember(%{"content" => "private command"},
        store: c.store,
        config: %{bound_scope: "private"},
        agent_id: "actor-b"
      )

    opts = [
      store: c.store,
      access_server: c.owner,
      channel: self(),
      channel_module: SharedChannel
    ]

    Process.put({SharedChannel, :mode}, :timeout)
    assert {:ok, %{drained: 0}} = Backplane.HostAgent.Memory.Syncer.drain_shared(opts)
    assert_receive {:command_batch, %{"protocol" => "memory_commands.v2", "items" => [first]}}
    Process.delete({SharedChannel, :mode})
    assert {:ok, %{drained: 1}} = Backplane.HostAgent.Memory.Syncer.drain_shared(opts)
    assert_receive {:command_batch, %{"protocol" => "memory_commands.v2", "items" => [^first]}}
    assert first["command_id"] == receipt["command_id"]
    assert {:ok, %{"drained" => 1}} = Backplane.HostAgent.Memory.Syncer.drain_once(opts)
    assert_receive {:command_batch, %{"protocol" => "host_memory.v1", "items" => [private]}}
    assert private["content"] == "private command"
    {:ok, _} = enqueue(c, target, "remember", %{"content" => "rejected"})
    Process.put({SharedChannel, :mode}, :reject)

    assert {:error, :unauthorized} =
             MemoryFacade.call(
               "remember",
               %{"memory_access_id" => @id, "content" => "new rejected"},
               %{
                 access_server: c.owner,
                 agent_id: "actor-b",
                 sync_opts: [channel: self(), channel_module: SharedChannel]
               }
             )

    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, c.owner)
  end

  test "channel dying during push keeps a zero-lease shared write pending and retries the same durable command",
       c do
    assert :ok = install(c)
    target = activate(c)
    assert {:error, :access_lease_expired} = local_read(c, target)
    {:ok, closed_channel} = Agent.start_link(fn -> nil end)

    args = %{
      "memory_access_id" => @id,
      "content" => "closed-channel private payload",
      "idempotency_key" => "closed-channel-command"
    }

    context = %{
      access_server: c.owner,
      agent_id: "actor-b",
      sync_opts: [channel: closed_channel, channel_module: DiesOnPush]
    }

    assert {:ok, %{"command_id" => command_id, "status" => "pending"} = pending} =
             MemoryFacade.call("remember", args, context)

    assert pending["authority"] == "provisional"
    assert pending["consistency"] == "pending_canonical_ack"
    assert pending["canonical_id"] == nil

    assert {:ok, %{rows: [row]}} =
             Store.query(c.store, "SELECT * FROM memory_outbox WHERE command_id=?", [command_id])

    assert row["state"] == "retry_wait"
    assert row["attempts"] == 1
    assert row["last_error"] == "transport_failure"
    assert row["dead_lettered_at"] == nil
    [access] = Access.status(c.owner).accesses
    assert access.status == "active"
    assert access.fence_reason == nil

    connected = Map.put(context, :sync_opts, channel: self(), channel_module: SharedChannel)

    assert {:ok, %{"command_id" => ^command_id, "status" => "committed"}} =
             MemoryFacade.call("remember", args, connected)

    assert_receive {:command_batch, %{"items" => [%{"command_id" => ^command_id}]}}
    assert {:ok, %{rows: [settled]}} = Store.query(c.store, "SELECT * FROM memory_outbox", [])
    assert settled["state"] == "done"
    assert settled["payload"] == row["payload"]
    assert settled["payload_digest"] == row["payload_digest"]
    assert settled["attempts"] == 1
  end

  test "returned shared command authorization partition and protocol errors remain permanent",
       c do
    reasons = [
      :unauthorized,
      :partition_mismatch,
      :invalid_protocol,
      %{"code" => "unauthorized", "retryable" => false},
      {:noproc, {GenServer, :call, []}}
    ]

    for {reason, version} <- Enum.with_index(reasons, 1) do
      assert :ok =
               Access.install_inventory(
                 %{id: version, sent_at_ms: 10_000},
                 inventory(version),
                 c.owner
               )

      Process.put({SharedChannel, :mode}, {:error, reason})

      assert {:error, _} =
               MemoryFacade.call(
                 "remember",
                 %{"memory_access_id" => @id, "content" => "permanent #{version}"},
                 %{
                   access_server: c.owner,
                   agent_id: "actor-b",
                   sync_opts: [channel: self(), channel_module: SharedChannel]
                 }
               )

      assert_receive {:command_batch, %{"items" => [%{"command_id" => command_id}]}}

      assert {:ok, %{rows: [%{"state" => "dead_letter", "attempts" => 1}]}} =
               Store.query(
                 c.store,
                 "SELECT state,attempts FROM memory_outbox WHERE command_id=?",
                 [command_id]
               )
    end
  end

  test "extended feed applies a bound snapshot/current/ACK then fences and refreshes on current-channel change",
       c do
    GenServer.stop(c.owner)
    {:ok, owner} = Access.start_link(Keyword.delete(c.opts, :now_fun))
    Process.unlink(owner)
    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)
    negotiated = inventory(1, 1)

    partition =
      Map.merge(@partition, %{
        "access_id" => @id,
        "authority_version" => 1,
        "applied_revision" => 0
      })

    negotiated = Map.put(negotiated, "partitions", [partition])

    {:ok, channel} =
      Agent.start_link(fn -> %{owner: self(), sent: MapSet.new(), inventory: negotiated} end)

    # Agent callbacks run in the channel; explicitly retain the observer pid.
    observer = self()
    Agent.update(channel, &Map.put(&1, :owner, observer))
    generation = %{id: 1, sent_at_ms: System.monotonic_time(:millisecond), channel: channel}
    assert :ok = Access.install_inventory(generation, negotiated, owner)

    {:ok, syncer} =
      Edge.Syncer.start_link(
        name: nil,
        channel: channel,
        channel_module: FeedChannel,
        mirror_opts: [store: c.edge, config: @config],
        selected: "host_memory.v2",
        generation: generation,
        extensions: negotiated["extensions"],
        default_access_id: @id,
        partitions: [partition],
        access_server: owner,
        poll_interval_ms: 60_000
      )

    on_exit(fn -> if Process.alive?(syncer), do: GenServer.stop(syncer) end)
    assert_receive {:feed, "memory_next", %{"access" => %{"access_id" => @id}}}, 1000

    assert_receive {:feed, "memory_ack",
                    %{"access" => %{"access_id" => @id}, "batch_id" => "snapshot-batch"}},
                   1000

    assert eventually(fn -> Edge.Syncer.diagnostics(syncer)["last_poll_result"] != "never" end)
    assert Edge.Syncer.diagnostics(syncer)["last_poll_result"] == "ok"
    assert hd(Access.status(owner).accesses).status == "active"
    state = Edge.Syncer.status(syncer)
    send(syncer, {:poll, state.poll_token})
    assert_receive {:feed, "memory_next", _}, 1000
    assert eventually(fn -> Edge.Syncer.status(syncer).poll_token != state.poll_token end)
    refute_receive {:feed, "memory_ack", _}, 20

    Edge.Syncer.memory_access_changed(
      %{channel: self(), hint: %{"access_id" => @id, "authority_version" => 2}},
      syncer
    )

    _ = Edge.Syncer.status(syncer)
    assert hd(Access.status(owner).accesses).status == "active"
    changed = inventory(2, 0, ["remember"]) |> Map.put("partitions", [])
    Agent.update(channel, &Map.put(&1, :inventory, changed))

    Edge.Syncer.memory_access_changed(
      %{channel: channel, hint: %{"access_id" => @id, "authority_version" => 2}},
      syncer
    )

    assert_receive {:feed, "memory_access_refresh", %{}}, 1000
    assert eventually(fn -> hd(Access.status(owner).accesses).authority_version == 2 end)
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, owner)
    assert {:ok, _, _} = Access.begin_request({:access_id, @id}, :remember, owner)
  end

  test "snapshot ACKs preserve progress cursors and fence malformed completion or binding replies",
       c do
    cases = [
      {2, %{}, "ok"},
      {2, %{"next_chunk_index" => nil}, "error"},
      {1, %{"next_chunk_index" => 1}, "error"},
      {2, %{"status" => "advanced", "next_chunk_index" => nil}, "error"},
      {1, %{"applied_revision" => 99}, "error"},
      {1, %{"batch_id" => "forged-batch"}, "error"}
    ]

    for {{chunks, changes, expected}, version} <- Enum.with_index(cases, 1) do
      {syncer, channel} = ack_feed(c, version, chunks, changes)
      assert_receive {:feed, "memory_ack", ack}, 1_000
      assert ack["next_chunk_index"] == 1
      assert eventually(fn -> Edge.Syncer.diagnostics(syncer)["last_poll_result"] != "never" end)
      diagnostic = Edge.Syncer.diagnostics(syncer)
      assert diagnostic["last_poll_result"] == expected

      if expected == "ok" do
        assert ack["status"] == "progress"
        assert diagnostic["last_stage"] == "ack_commit"
        assert hd(Access.status(c.owner).accesses).status == "needs_sync"
      else
        assert diagnostic["last_stage"] == "ack_binding"
        assert diagnostic["last_error"] == "invalid_protocol"
        assert hd(Access.status(c.owner).accesses).status == "fenced"
      end

      GenServer.stop(syncer)
      GenServer.stop(channel)
    end
  end

  test "current and older access hints neither fence a grant nor renew its lease", c do
    {syncer, _generation, owner} = inventory_syncer(c, 2, 30)
    c = %{c | owner: owner}
    [before_hint] = Access.status(c.owner).accesses
    {:ok, target, ticket} = Access.begin_request({:access_id, @id}, :read, c.owner)

    for version <- [2, 1, 2] do
      access_hint(syncer, version)
      _ = Edge.Syncer.status(syncer)
      refute_receive {:inventory_request, _}, 20
      assert [^before_hint] = Access.status(c.owner).accesses
    end

    assert {:ok, _, _} = Access.finish_request(ticket, read_reply(target), c.owner)
  end

  test "duplicate hints queued behind inventory refresh cannot refence the installed version",
       c do
    {syncer, _generation, owner} = inventory_syncer(c, 2, 30)
    c = %{c | owner: owner}
    access_hint(syncer, 3)
    assert_receive {:inventory_request, caller}, 1_000
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, c.owner)

    # These arrive while the authenticated refresh is awaiting its response.
    access_hint(syncer, 3)
    access_hint(syncer, 2)
    access_hint(syncer, 3)
    send(caller, {:inventory_reply, Map.put(inventory(3, 30), "partitions", [])})
    _ = Edge.Syncer.status(syncer)

    refute_receive {:inventory_request, _}, 20

    assert {:ok, %{authority_version: 3}, _} =
             Access.begin_request({:access_id, @id}, :read, c.owner)
  end

  test "newer revoke fences before refresh and only a newer regrant permits fresh sync", c do
    {syncer, generation, owner} = inventory_syncer(c, 2, 30)
    c = %{c | owner: owner}
    access_hint(syncer, 3, "revoked")
    assert_receive {:inventory_request, caller}, 1_000
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, c.owner)
    assert [%{deadline: nil, fence_reason: "authority_changed"}] = Access.status(c.owner).accesses

    # A response still carrying the old active grant cannot clear the fence.
    send(caller, {:inventory_reply, Map.put(inventory(2, 30), "partitions", [])})
    _ = Edge.Syncer.status(syncer)
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, c.owner)

    revoked =
      Map.update!(inventory(3, 30), "accesses", fn [entry] ->
        [Map.put(entry, "status", "revoked")]
      end)

    access_hint(syncer, 3, "revoked")
    assert_receive {:inventory_request, caller}, 1_000
    send(caller, {:inventory_reply, Map.put(revoked, "partitions", [])})
    _ = Edge.Syncer.status(syncer)
    access_hint(syncer, 3, "revoked")
    _ = Edge.Syncer.status(syncer)
    refute_receive {:inventory_request, _}, 20
    generation = %{generation | sent_at_ms: System.monotonic_time(:millisecond)}
    assert :ok = Access.install_inventory(generation, inventory(3, 30), c.owner)
    assert {:error, :unauthorized} = Access.begin_request({:access_id, @id}, :read, c.owner)

    access_hint(syncer, 4)
    assert_receive {:inventory_request, caller}, 1_000
    send(caller, {:inventory_reply, Map.put(inventory(4, 30), "partitions", [])})
    _ = Edge.Syncer.status(syncer)

    assert {:ok, %{authority_version: 4, status: "needs_sync"}, _} =
             Access.begin_request({:access_id, @id}, :read, c.owner)
  end

  test "Worker binds fresh extended negotiation before shared admission with mirror disabled",
       c do
    Process.register(c.owner, Access)
    keys = [:memory_config, :memory_store, :memory_host_sync_v2]
    previous = Map.new(keys, &{&1, Application.fetch_env(:backplane_host_agent, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        case value do
          {:ok, v} -> Application.put_env(:backplane_host_agent, key, v)
          :error -> Application.delete_env(:backplane_host_agent, key)
        end
      end)
    end)

    {:ok, channel} = Agent.start_link(fn -> nil end)
    negotiated = inventory() |> Map.put("selected", "host_memory.v2") |> Map.put("partitions", [])

    config = %{
      host_id: "host-b",
      hub_url: "http://unused.invalid",
      token: "synthetic-token",
      machine_name: "test-host",
      manifest_path: Path.join(c.tmp_dir, "manifest.json"),
      interval_ms: 60_000,
      memory: %{enabled: false, host_sync_v2: %{enabled: false}},
      test_connection: %{channel: channel, host_id: "host-b", memory: negotiated}
    }

    {:ok, worker} =
      Backplane.HostAgent.Worker.start_link(
        name: nil,
        connect?: true,
        config: config,
        connector_module: ExtendedConnector,
        http_server_module: NoHttp,
        sync_on_start?: false
      )

    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker) end)
    assert eventually(fn -> Access.status(c.owner).negotiated end)
    assert {:ok, target, _} = Access.begin_request({:access_id, @id}, :read, c.owner)
    assert target.connection_generation == Access.status(c.owner).generation
    assert is_integer(target.connection_generation)
    assert MemoryProxy.channel() == channel
    assert %{last_error: nil} = GenServer.call(worker, :status)
    GenServer.stop(worker)
  end

  test "shared diagnostics expose safe authority/command metadata and hide cold/fenced mirror rows",
       c do
    request = %{"memory_access_id" => @id, "command_ids" => [], "mirror_ids" => []}
    assert :ok = install(c, 1, 1)
    target = activate(c)
    {:ok, receipt} = enqueue(c, target, "remember", %{"content" => "diagnostic protected secret"})
    request = Map.put(request, "command_ids", [receipt["command_id"]])

    assert {:ok, open} =
             Backplane.HostAgent.Memory.Diagnostics.targeted(request, access_server: c.owner)

    assert open["mirror"]["status"] == "complete"
    refute Jason.encode!(open) =~ "diagnostic protected secret"
    assert :ok = Access.fence({:access_id, @id}, :unauthorized, 1, c.owner)

    assert {:ok, closed} =
             Backplane.HostAgent.Memory.Diagnostics.targeted(request, access_server: c.owner)

    assert closed["access"]["status"] == "closed"
    assert closed["mirror"] == %{"status" => "closed"}
    refute Jason.encode!(closed) =~ "last_error"
    GenServer.stop(c.owner)
    {:ok, cold} = Access.start_link(c.opts)
    Process.unlink(cold)
    on_exit(fn -> if Process.alive?(cold), do: GenServer.stop(cold) end)

    assert {:ok, observation} =
             Backplane.HostAgent.Memory.Diagnostics.targeted(request, access_server: cold)

    assert observation["access"]["fence_reason"] == "not_negotiated"
    assert observation["mirror"] == %{"status" => "closed"}
  end

  test "both HTTP and MCP route explicit selector through real owner and reject unsupported/raw authority",
       c do
    Process.register(c.owner, Access)
    assert :ok = install(c)
    previous = Application.get_env(:backplane_host_agent, :local_services)

    Application.put_env(:backplane_host_agent, :local_services, [
      Backplane.HostAgent.Services.Memory
    ])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:backplane_host_agent, :local_services, previous),
        else: Application.delete_env(:backplane_host_agent, :local_services)
    end)

    args = %{"memory_access_id" => @id}
    direct = router("/memory/actor-b/call/list", args)
    assert direct.status == 200
    assert Jason.decode!(direct.resp_body)["ok"]

    mcp =
      router("/memory/actor-b/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "memory::list", "arguments" => args}
      })

    assert Jason.decode!(mcp.resp_body)["result"]["isError"] == false

    for method <- ["slot_write", "recall_explain"] do
      denied = router("/memory/actor-b/call/" <> method, args)
      assert Jason.decode!(denied.resp_body)["error"] == "invalid_request"
    end

    denied =
      router("/memory/actor-b/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "memory::remember",
          "arguments" => Map.put(args, "namespace", "private")
        }
      })

    assert Jason.decode!(denied.resp_body)["result"]["isError"]
  end

  defp router(path, args) do
    Plug.Test.conn(:post, path, Jason.encode!(args))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_private(:backplane_memory_facade, RouterFacade)
    |> Backplane.HostAgent.MemoryRouter.call(Backplane.HostAgent.MemoryRouter.init([]))
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  def snapshot(access) do
    chunk_hash = Mirror.Store.hash(%{"items" => []})
    manifest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, chunk_hash), case: :lower)

    %{
      "protocol" => "host_memory.v2",
      "status" => "batch",
      "kind" => "snapshot_chunk",
      "batch_id" => "snapshot-batch",
      "partition" => @partition,
      "access" => access,
      "snapshot_id" => "fresh-snapshot-#{access["authority_version"]}",
      "chunk_index" => 0,
      "chunk_count" => 1,
      "item_count" => 0,
      "base_revision" => 0,
      "to_revision" => 0,
      "chunk_hash" => chunk_hash,
      "integrity_hash" => manifest,
      "items" => []
    }
  end

  defp ack_feed(c, version, chunks, changes) do
    observer = self()

    partition =
      Map.merge(@partition, %{
        "access_id" => @id,
        "authority_version" => version,
        "applied_revision" => 0
      })

    negotiated = Map.put(inventory(version), "partitions", [partition])

    {:ok, channel} =
      Agent.start_link(fn ->
        %{
          owner: observer,
          sent: MapSet.new(),
          inventory: negotiated,
          chunks: chunks,
          ack_changes: changes
        }
      end)

    generation = %{id: 1, sent_at_ms: 10_000, channel: channel}
    assert :ok = Access.install_inventory(generation, negotiated, c.owner)

    {:ok, syncer} =
      Edge.Syncer.start_link(
        name: nil,
        channel: channel,
        channel_module: FeedChannel,
        mirror_opts: [store: c.edge, config: @config],
        selected: "host_memory.v2",
        generation: generation,
        extensions: negotiated["extensions"],
        partitions: [partition],
        access_server: c.owner,
        poll_interval_ms: 60_000,
        retry_backoff_ms: 60_000
      )

    on_exit(fn ->
      for pid <- [syncer, channel], Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {syncer, channel}
  end

  defp delivery_inventory(negotiated) do
    Map.put(
      negotiated,
      "partitions",
      Enum.map(negotiated["accesses"], fn entry ->
        Map.merge(entry["partition"], %{
          "access_id" => entry["access_id"],
          "authority_version" => entry["authority_version"],
          "applied_revision" => 0
        })
      end)
    )
  end

  defp start_access_feed(c, negotiated, channel, channel_module, opts \\ []) do
    generation = %{id: 1, sent_at_ms: 10_000, channel: channel}
    assert :ok = Access.install_inventory(generation, negotiated, c.owner)

    {:ok, syncer} =
      Edge.Syncer.start_link(
        Keyword.merge(
          [
            name: nil,
            channel: channel,
            channel_module: channel_module,
            mirror_opts: [store: c.edge, config: @config],
            selected: "host_memory.v2",
            generation: generation,
            extensions: negotiated["extensions"],
            partitions: negotiated["partitions"],
            access_server: c.owner,
            poll_interval_ms: 60_000,
            retry_backoff_ms: 60_000
          ],
          opts
        )
      )

    on_exit(fn ->
      if Process.alive?(syncer), do: GenServer.stop(syncer)
    end)

    {syncer, generation}
  end

  defp inventory_syncer(c, version, lease) do
    GenServer.stop(c.owner)
    {:ok, owner} = Access.start_link(Keyword.delete(c.opts, :now_fun))
    Process.unlink(owner)
    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)
    generation = %{id: 1, sent_at_ms: System.monotonic_time(:millisecond), channel: self()}
    negotiated = Map.put(inventory(version, lease), "partitions", [])
    assert :ok = Access.install_inventory(generation, negotiated, owner)

    {:ok, syncer} =
      Edge.Syncer.start_link(
        name: nil,
        channel: self(),
        channel_module: InventoryChannel,
        generation: generation,
        extensions: negotiated["extensions"],
        access_server: owner,
        retry_backoff_ms: 60_000
      )

    on_exit(fn -> if Process.alive?(syncer), do: GenServer.stop(syncer) end)
    {syncer, generation, owner}
  end

  defp access_hint(syncer, version, status \\ "active") do
    Edge.Syncer.memory_access_changed(
      %{
        channel: self(),
        hint: %{
          "access_id" => @id,
          "authority_version" => version,
          "status" => status
        }
      },
      syncer
    )
  end

  defp install(c, version \\ 1, lease \\ 0, caps \\ ~w(read deliver remember forget)),
    do:
      Access.install_inventory(
        %{id: 1, sent_at_ms: 10_000},
        inventory(version, lease, caps),
        c.owner
      )

  defp inventory(version \\ 1, lease \\ 0, caps \\ ~w(read deliver remember forget)),
    do: %{
      "extensions" => ["memory_access.v1", "memory_commands.v2"],
      "default_access_id" => @id,
      "accesses" => [
        %{
          "access_id" => @id,
          "authority_version" => version,
          "status" => "active",
          "partition" => @partition,
          "capabilities" => caps,
          "offline_read_lease_seconds" => lease
        }
      ]
    }

  defp two_accesses do
    inventory = inventory()
    [first] = inventory["accesses"]
    Map.put(inventory, "accesses", [first, Map.put(first, "access_id", @other)])
  end

  defp read_reply(target),
    do:
      {:ok,
       %{
         "access" => Access.claim(target),
         "partition" => target.partition,
         "result" => %{"results" => []}
       }}

  defp activate(c, items \\ []) do
    {:ok, target, ticket} = Access.begin_request({:access_id, @id}, :deliver, c.owner)
    chunk_hash = Mirror.Store.hash(%{"items" => items})
    manifest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, chunk_hash), case: :lower)

    delivery = %{
      "protocol" => "host_memory.v2",
      "status" => "batch",
      "kind" => "snapshot_chunk",
      "batch_id" => "snapshot-batch",
      "partition" => @partition,
      "access" => Access.claim(target),
      "snapshot_id" => "fresh-snapshot",
      "chunk_index" => 0,
      "chunk_count" => 1,
      "item_count" => length(items),
      "base_revision" => 0,
      "to_revision" => 0,
      "chunk_hash" => chunk_hash,
      "integrity_hash" => manifest,
      "items" => items
    }

    {:ok, permitted, _} = Access.finish_request(ticket, {:ok, delivery}, c.owner)

    {:ok, _} =
      Access.run_local(
        permitted,
        :deliver,
        fn _ -> Mirror.apply_delivery(delivery, store: c.edge, config: @config) end,
        c.owner
      )

    target
  end

  defp protected_item(id, content),
    do: %{
      "canonical_id" => id,
      "memory_type" => "semantic",
      "content" => content,
      "content_hash" => "protected-test-hash",
      "confidence" => 0.9,
      "edge_priority" => 0.9,
      "updated_at" => "2026-10-20T00:00:00.000000",
      "lifecycle_state" => "active",
      "tags" => [],
      "metadata" => %{},
      "expires_at" => nil
    }

  defp stop_fault_owner(pid) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)

      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> Process.exit(pid, :kill)
      end

      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
    end
  end

  defp composed_read(c, target, before_release \\ fn -> :ok end) do
    Access.run_local(
      target,
      :read,
      fn current ->
        with {:ok, mirror} <-
               Mirror.offline_read("list", @partition,
                 store: c.edge,
                 config: @config,
                 access_target: current
               ),
             {:ok, overlay} <-
               Memory.shared_overlay(current, "list", %{}, :offline, mirror["partition_revision"]) do
          before_release.()
          {:ok, Map.put(overlay, "items", mirror["items"] ++ overlay["upserts"])}
        end
      end,
      c.owner
    )
  end

  defp local_read(c, target),
    do:
      Access.run_local(
        target,
        :read,
        fn current ->
          Mirror.offline_read("list", @partition,
            store: c.edge,
            config: @config,
            access_target: current
          )
        end,
        c.owner
      )

  defp enqueue(c, target, operation, args),
    do:
      Access.run_local(
        target,
        String.to_existing_atom(operation),
        &Memory.shared_enqueue(&1, operation, args, "actor-b"),
        c.owner
      )

  defp claim(c) do
    {:ok, rows} =
      Access.run_local(:all, :drain, &Memory.shared_claim(&1, "2026-10-20T00:00:00Z", 5), c.owner)

    rows
  end

  defp ack(row, status),
    do: %{
      "command_id" => row["command_id"],
      "access" => %{
        "access_id" => row["access_id"],
        "authority_version" => row["authority_version"]
      },
      "partition" => Jason.decode!(row["target_partition"]),
      "status" => status,
      "canonical_id" => "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      "revision" => 1
    }

  defp settle(c, rows, ack),
    do:
      Access.run_local(
        :all,
        :settle,
        &Memory.shared_settle(
          &1,
          rows,
          {:ok, %{"protocol" => "memory_commands.v2", "items" => [ack]}},
          "2026-10-20T00:00:01Z",
          5
        ),
        c.owner
      )
end
