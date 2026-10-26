defmodule Backplane.HostAgent.MemoryProxyTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.{MemoryProxy, Trace}

  defmodule FakeConnector do
    def connect(config) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:connect, config})

      {:ok, %{channel: owner, host_id: "host-1", host_name: "t430", socket: owner}}
    end
  end

  defmodule FakeChannel do
    def push(channel, event, payload, _timeout \\ 5_000) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:push, channel, event, payload})

      {:ok, %{"ok" => true, "result" => %{"status" => "ok"}}}
    end
  end

  defmodule TimeoutChannel do
    def push(channel, event, payload, timeout) do
      send(channel, {:push_timeout, event, payload, timeout})
      {:ok, %{"ok" => true, "result" => %{"status" => "ok"}}}
    end
  end

  defmodule ReplacingGetChannel do
    def push(channel, "memory_call", _payload, _timeout) do
      MemoryProxy.set_connection(%{channel: channel, memory_generation: %{id: 2}}, %{})
      {:ok, %{"ok" => true, "result" => %{"content" => "old connection content"}}}
    end
  end

  defmodule DeniedChannel do
    def push(_, _, _, _), do: {:error, %{"code" => "unauthorized", "retryable" => false}}
  end

  defmodule StaleDeniedChannel do
    def push(_, _, _, _) do
      MemoryProxy.set_connection(%{channel: Process.get(:replacement_channel)}, %{})
      {:error, %{"code" => "unauthorized", "retryable" => false}}
    end
  end

  defmodule StaleDeniedConnector do
    def connect(_config) do
      MemoryProxy.set_connection(%{channel: self()}, %{})
      {:error, :unauthorized}
    end
  end

  defmodule RejoinChannel do
    def join(socket, host_id) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:join, socket, host_id})
      {:ok, owner}
    end

    def push(channel, event, payload, _timeout \\ 5_000) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:push, channel, event, payload})

      {:ok, %{"ok" => true, "result" => %{"status" => "ok"}}}
    end
  end

  defmodule AlreadyJoinedChannel do
    def join(socket, host_id) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:join, socket, host_id})
      {:error, {:already_started, owner}}
    end

    def push(channel, event, payload, _timeout \\ 5_000) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:push, channel, event, payload})

      {:ok, %{"ok" => true, "result" => %{"status" => "ok"}}}
    end
  end

  defmodule SlowConnector do
    def connect(config) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:connect, config})
      Process.sleep(50)

      {:ok, %{channel: owner, host_id: "host-1", host_name: "t430", socket: owner}}
    end
  end

  defmodule FakeSocketClient do
    def disconnect(pid) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:disconnect, pid})
      :ok
    end
  end

  defmodule UnexpectedConnector do
    def connect(config) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:unexpected_connect, config})
      {:error, :unexpected_reconnect}
    end
  end

  defmodule ScopeConnector do
    def connect(config) do
      send(self(), {:scope_connect, config})
      {:ok, %{channel: self(), memory: Process.get(:scope_negotiation)}}
    end
  end

  defmodule ScopeRejoinChannel do
    def join(_socket, _host_id), do: {:ok, Process.get(:scope_negotiation), self()}
    defdelegate push(channel, event, payload, timeout), to: FakeChannel
  end

  setup do
    previous_socket_client = Application.get_env(:backplane_host_agent, :socket_client_module)

    MemoryProxy.set_channel(nil)
    :persistent_term.put({FakeConnector, :owner}, self())
    :persistent_term.put({FakeChannel, :owner}, self())
    :persistent_term.put({RejoinChannel, :owner}, self())
    :persistent_term.put({AlreadyJoinedChannel, :owner}, self())
    :persistent_term.put({SlowConnector, :owner}, self())
    :persistent_term.put({FakeSocketClient, :owner}, self())
    :persistent_term.put({UnexpectedConnector, :owner}, self())
    Application.put_env(:backplane_host_agent, :socket_client_module, FakeSocketClient)

    on_exit(fn ->
      MemoryProxy.set_channel(nil)
      :persistent_term.erase({FakeConnector, :owner})
      :persistent_term.erase({FakeChannel, :owner})
      :persistent_term.erase({RejoinChannel, :owner})
      :persistent_term.erase({AlreadyJoinedChannel, :owner})
      :persistent_term.erase({SlowConnector, :owner})
      :persistent_term.erase({FakeSocketClient, :owner})
      :persistent_term.erase({UnexpectedConnector, :owner})

      if previous_socket_client do
        Application.put_env(:backplane_host_agent, :socket_client_module, previous_socket_client)
      else
        Application.delete_env(:backplane_host_agent, :socket_client_module)
      end
    end)

    :ok
  end

  test "get never injects the route agent as a record constraint" do
    MemoryProxy.set_channel(self())
    args = %{"id" => "11111111-1111-4111-8111-111111111111"}

    assert {:ok, _} =
             MemoryProxy.call("get", args, agent_id: "reader", channel_module: FakeChannel)

    assert_received {:push, _, "memory_call", %{"method" => "get", "arguments" => ^args}}
  end

  test "get rejects replies after the connection generation changes on the same channel" do
    MemoryProxy.set_connection(%{channel: self(), memory_generation: %{id: 1}}, %{})

    assert {:error, :stale_connection} =
             MemoryProxy.call("get", %{}, agent_id: "reader", channel_module: ReplacingGetChannel)
  end

  test "get rejects a channel replaced after selection but before its connection snapshot" do
    old_channel = start_supervised!({Agent, fn -> nil end})
    MemoryProxy.set_connection(%{channel: old_channel, memory_generation: %{id: 1}}, %{})

    result =
      replace_before_push_snapshot(
        fn -> MemoryProxy.call("get", %{}, agent_id: "reader", channel_module: FakeChannel) end,
        fn -> MemoryProxy.set_connection(%{channel: self(), memory_generation: %{id: 2}}, %{}) end
      )

    assert {:error, :stale_connection} = result
    refute_received {:push, ^old_channel, "memory_call", _}
  end

  test "explicit access rejects a generation replaced before the connection snapshot" do
    MemoryProxy.set_connection(%{channel: self(), memory_generation: %{id: 1}}, %{})
    access = %{"access_id" => "11111111-1111-4111-8111-111111111111", "authority_version" => 1}

    result =
      replace_before_push_snapshot(
        fn ->
          MemoryProxy.call("get", %{},
            agent_id: "reader",
            channel_module: FakeChannel,
            access: access,
            connection_generation: 1
          )
        end,
        fn -> MemoryProxy.set_connection(%{channel: self(), memory_generation: %{id: 2}}, %{}) end
      )

    assert {:error, :stale_connection} = result
    refute_received {:push, _, "memory_call", _}
  end

  test "default get pins its selected generation before the connection snapshot" do
    MemoryProxy.set_connection(%{channel: self(), memory_generation: %{id: 1}}, %{})

    result =
      replace_before_push_snapshot(
        fn -> MemoryProxy.call("get", %{}, agent_id: "reader", channel_module: FakeChannel) end,
        fn -> MemoryProxy.set_connection(%{channel: self(), memory_generation: %{id: 2}}, %{}) end
      )

    assert {:error, :stale_connection} = result
    refute_received {:push, _, "memory_call", _}
  end

  test "a negotiated default-access scope mismatch blocks private memory without retiring the channel" do
    connection = %{
      channel: self(),
      memory: %{
        "selected" => "host_memory.v2",
        "default_access_id" => "default",
        "accesses" => [
          %{
            "access_id" => "default",
            "partition" => %{"scope" => "registered", "namespace" => "private"}
          }
        ]
      }
    }

    assert :ok = MemoryProxy.set_connection(connection, %{memory: %{bound_scope: "local"}})
    assert MemoryProxy.channel() == self()
    assert :ok = MemoryProxy.authorize_command()
    assert {:error, :memory_scope_mismatch} = MemoryProxy.authorize_private()

    assert {:error, :memory_scope_mismatch} =
             MemoryProxy.call("list", %{}, agent_id: "hermes", channel_module: FakeChannel)

    refute_received {:push, _, _, _}
  end

  test "v2 binding uses default access even without delivery partitions" do
    connection = %{
      channel: self(),
      memory: %{
        "selected" => "host_memory.v2",
        "partitions" => [],
        "default_access_id" => "default",
        "accesses" => [
          %{
            "access_id" => "other",
            "partition" => %{"scope" => "local", "namespace" => "public"}
          },
          %{
            "access_id" => "default",
            "partition" => %{"scope" => "registered", "namespace" => "private"}
          }
        ]
      }
    }

    :ok = MemoryProxy.set_connection(connection, %{memory: %{bound_scope: "local"}})
    assert {:error, :memory_scope_mismatch} = MemoryProxy.authorize_private()

    :ok = MemoryProxy.set_connection(connection, %{memory: %{bound_scope: "registered"}})
    assert :ok = MemoryProxy.authorize_private()
  end

  test "missing comparable private negotiation does not invent a binding error" do
    for memory <- [
          %{},
          %{"selected" => "host_memory.v2", "partitions" => []},
          %{
            "selected" => "host_memory.v2",
            "partitions" => [%{"scope" => "other", "namespace" => "public"}]
          },
          %{
            "selected" => "host_memory.v2",
            "partitions" => [%{"scope" => "", "namespace" => "private"}]
          }
        ] do
      :ok =
        MemoryProxy.set_connection(%{channel: self(), memory: memory}, %{
          memory: %{bound_scope: "local"}
        })

      assert :ok = MemoryProxy.authorize_private()
    end
  end

  test "binding errors survive channel loss and matching authenticated joins restore private memory" do
    channel = start_supervised!({Agent, fn -> nil end})
    MemoryProxy.set_connection_owner(self())

    memory = %{
      "selected" => "host_memory.v2",
      "default_access_id" => "default",
      "accesses" => [
        %{
          "access_id" => "default",
          "partition" => %{"scope" => "registered", "namespace" => "private"}
        }
      ]
    }

    :ok =
      MemoryProxy.set_connection(%{channel: channel, memory: memory}, %{
        memory: %{bound_scope: "local"}
      })

    Agent.stop(channel)
    assert {:error, :memory_scope_mismatch} = MemoryProxy.authorize_private()
    :ok = MemoryProxy.set_connection(%{channel: self()}, %{memory: %{bound_scope: "local"}})
    assert {:error, :memory_scope_mismatch} = MemoryProxy.authorize_private()

    :ok =
      MemoryProxy.set_connection(%{channel: self(), memory: memory}, %{
        memory: %{bound_scope: "registered"}
      })

    assert :ok = MemoryProxy.authorize_private()

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("list", %{}, agent_id: "hermes", channel_module: FakeChannel)
  end

  test "credential rejection takes precedence over a private binding error" do
    MemoryProxy.set_connection_owner(self())

    :ok =
      MemoryProxy.set_connection(
        %{
          channel: self(),
          memory: %{
            "selected" => "host_memory.v2",
            "default_access_id" => "default",
            "accesses" => [
              %{
                "access_id" => "default",
                "partition" => %{"scope" => "registered", "namespace" => "private"}
              }
            ]
          }
        },
        %{memory: %{bound_scope: "local"}}
      )

    :ok = MemoryProxy.set_connection_error(:unauthorized, self())
    assert {:error, :unauthorized} = MemoryProxy.authorize_private()
  end

  test "a private mismatch does not block explicitly selected shared access" do
    :ok =
      MemoryProxy.set_connection(
        %{
          channel: self(),
          memory_generation: %{id: 42},
          memory: %{
            "selected" => "host_memory.v2",
            "default_access_id" => "default",
            "accesses" => [
              %{
                "access_id" => "default",
                "partition" => %{"scope" => "registered", "namespace" => "private"}
              }
            ]
          }
        },
        %{memory: %{bound_scope: "local"}}
      )

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("list", %{},
               agent_id: "hermes",
               channel_module: FakeChannel,
               access: %{"access_id" => "shared-access", "authority_version" => 1},
               connection_generation: 42
             )

    assert_received {:push, _, "memory_call", %{"access" => %{"access_id" => "shared-access"}}}
  end

  test "a reconnect that discovers a mismatch rejects the first private push" do
    MemoryProxy.set_config(%{memory: %{bound_scope: "local"}})

    Process.put(:scope_negotiation, %{
      "selected" => "host_memory.v2",
      "default_access_id" => "default",
      "accesses" => [
        %{
          "access_id" => "default",
          "partition" => %{"scope" => "registered", "namespace" => "private"}
        }
      ]
    })

    assert {:error, :memory_scope_mismatch} =
             MemoryProxy.call("list", %{},
               agent_id: "hermes",
               channel_module: FakeChannel,
               connector_module: ScopeConnector
             )

    assert_received {:scope_connect, _}
    refute_received {:push, _, _, _}
  end

  test "a rejoined socket checks the new authenticated partition before pushing" do
    socket = start_supervised!({Agent, fn -> nil end})

    :ok =
      MemoryProxy.set_connection(
        %{channel: dead_pid(), socket: socket, host_id: "host-1"},
        %{memory: %{bound_scope: "local"}}
      )

    Process.put(:scope_negotiation, %{
      "selected" => "host_memory.v2",
      "default_access_id" => "default",
      "accesses" => [
        %{
          "access_id" => "default",
          "partition" => %{"scope" => "registered", "namespace" => "private"}
        }
      ]
    })

    assert {:error, :memory_scope_mismatch} =
             MemoryProxy.call("list", %{},
               agent_id: "hermes",
               channel_module: ScopeRejoinChannel,
               connector_module: UnexpectedConnector
             )

    refute_received {:push, _, _, _}
    refute_received {:unexpected_connect, _}
  end

  test "returns not_connected instead of exiting when the cached channel pid is dead" do
    dead_channel = dead_pid()
    MemoryProxy.set_channel(dead_channel)

    assert {:error, :not_connected} = MemoryProxy.call("list", %{}, agent_id: "hermes")
    assert MemoryProxy.channel() == nil
  end

  test "an explicit channel rejection survives channel loss until a new authenticated join" do
    channel = start_supervised!({Agent, fn -> nil end})
    MemoryProxy.set_connection_owner(self())
    MemoryProxy.set_connection(%{channel: channel}, %{})
    rejection = %{"code" => "unauthorized", "retryable" => false}

    assert {:error, ^rejection} =
             MemoryProxy.call("recall", %{}, agent_id: "codex", channel_module: DeniedChannel)

    Agent.stop(channel)
    assert {:error, ^rejection} = MemoryProxy.call("recall", %{}, agent_id: "codex")
    MemoryProxy.set_connection(%{channel: self()}, %{})

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("recall", %{}, agent_id: "codex", channel_module: FakeChannel)
  end

  test "an old channel rejection cannot replace a newer authenticated connection" do
    channel = start_supervised!({Agent, fn -> nil end})
    MemoryProxy.set_connection(%{channel: channel}, %{})
    Process.put(:replacement_channel, self())

    assert {:error, %{"code" => "unauthorized"}} =
             MemoryProxy.call("recall", %{},
               agent_id: "codex",
               channel_module: StaleDeniedChannel
             )

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("recall", %{}, agent_id: "codex", channel_module: FakeChannel)
  end

  test "exposes and forwards lifecycle_context with the local agent identity" do
    MemoryProxy.set_channel(self())

    assert "lifecycle_context" in MemoryProxy.methods()

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call(
               "lifecycle_context",
               %{
                 "kind" => "session_start",
                 "session_id" => "session-1",
                 "project" => "/workspace/project"
               },
               agent_id: "hermes",
               channel_module: FakeChannel
             )

    assert_receive {:push, channel, "memory_call",
                    %{
                      "method" => "lifecycle_context",
                      "arguments" => %{
                        "kind" => "session_start",
                        "session_id" => "session-1",
                        "project" => "/workspace/project",
                        "agent_id" => "hermes"
                      }
                    }}

    assert channel == self()
  end

  @tag :authoritative_connection
  test "a delayed connector rejection cannot poison a newer authenticated connection" do
    MemoryProxy.set_config(%{})

    assert {:error, {:reconnect_failed, :unauthorized}} =
             MemoryProxy.call("recall", %{},
               agent_id: "codex",
               connector_module: StaleDeniedConnector
             )

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("recall", %{}, agent_id: "codex", channel_module: FakeChannel)
  end

  test "caps the channel push timeout at the lifecycle hard limit" do
    MemoryProxy.set_channel(self())

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call(
               "lifecycle_context",
               %{
                 "kind" => "session_start",
                 "session_id" => "session-1",
                 "project" => "/workspace/project"
               },
               agent_id: "hermes",
               timeout: 9_000,
               channel_module: TimeoutChannel
             )

    assert_receive {:push_timeout, "memory_call", _payload, 1_500}
  end

  test "preserves the existing channel timeout for non-lifecycle memory calls" do
    MemoryProxy.set_channel(self())

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("list", %{},
               agent_id: "hermes",
               channel_module: TimeoutChannel
             )

    assert_receive {:push_timeout, "memory_call", _payload, 5_000}
  end

  test "can omit path-agent filtering while retaining agent telemetry context" do
    MemoryProxy.set_channel(self())

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("recall", %{"query" => "canonical"},
               agent_id: "codex",
               inject_agent_id: false,
               channel_module: FakeChannel
             )

    assert_receive {:push, channel, "memory_call",
                    %{
                      "method" => "recall",
                      "arguments" => arguments
                    }}

    assert channel == self()
    assert arguments == %{"query" => "canonical"}
  end

  test "reconnects with stored config when the cached channel pid is dead" do
    config = %{hub_url: "http://localhost:4220", token: "host-token", machine_name: "t430"}

    MemoryProxy.set_connection(
      %{channel: dead_pid(), host_id: "host-1", host_name: "t430", socket: nil},
      config
    )

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("list", %{"scope" => "/tmp"},
               agent_id: "hermes",
               channel_module: FakeChannel,
               connector_module: FakeConnector
             )

    assert_receive {:connect, ^config}

    assert_receive {:push, channel, "memory_call",
                    %{
                      "method" => "list",
                      "arguments" => %{"agent_id" => "hermes", "scope" => "/tmp"}
                    }}

    assert channel == self()
    assert MemoryProxy.channel() == self()
  end

  test "reconnects with stored config before any channel exists" do
    config = %{hub_url: "http://localhost:4220", token: "host-token", machine_name: "t430"}

    MemoryProxy.set_config(config)

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("list", %{"scope" => "/tmp"},
               agent_id: "hermes",
               channel_module: FakeChannel,
               connector_module: FakeConnector
             )

    assert_receive {:connect, ^config}
    assert_receive {:push, channel, "memory_call", %{"method" => "list"}}
    assert channel == self()
    assert MemoryProxy.channel() == self()
  end

  test "rejoins stored live socket before starting a new socket" do
    config = %{hub_url: "http://localhost:4220", token: "host-token", machine_name: "t430"}

    MemoryProxy.set_connection(
      %{channel: dead_pid(), host_id: "host-1", host_name: "t430", socket: self()},
      config
    )

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("list", %{"scope" => "/tmp"},
               agent_id: "hermes",
               channel_module: RejoinChannel,
               connector_module: UnexpectedConnector
             )

    assert_receive {:join, socket, "host-1"}
    assert socket == self()

    assert_receive {:push, channel, "memory_call",
                    %{
                      "method" => "list",
                      "arguments" => %{"agent_id" => "hermes", "scope" => "/tmp"}
                    }}

    assert channel == self()
    refute_received {:unexpected_connect, ^config}
  end

  test "reuses already joined channel before starting a new socket" do
    config = %{hub_url: "http://localhost:4220", token: "host-token", machine_name: "t430"}

    MemoryProxy.set_connection(
      %{channel: dead_pid(), host_id: "host-1", host_name: "t430", socket: self()},
      config
    )

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("list", %{"scope" => "/tmp"},
               agent_id: "hermes",
               channel_module: AlreadyJoinedChannel,
               connector_module: UnexpectedConnector
             )

    assert_receive {:join, socket, "host-1"}
    assert socket == self()

    assert_receive {:push, channel, "memory_call", %{"method" => "list"}}
    assert channel == self()
    refute_received {:unexpected_connect, ^config}
  end

  test "concurrent managed requests leave joining to the worker before and after reconnect" do
    config = %{hub_url: "http://localhost:4220", token: "host-token"}
    MemoryProxy.set_connection_owner(self())
    MemoryProxy.set_config(config)

    for _ <- 1..2 do
      tasks =
        for _ <- 1..8 do
          Task.async(fn ->
            MemoryProxy.call("list", %{},
              agent_id: "fixture",
              channel_module: RejoinChannel,
              connector_module: UnexpectedConnector
            )
          end)
        end

      assert Enum.all?(tasks, &(Task.await(&1) == {:error, :not_connected}))
      assert_receive {:memory_connection_lost, _}
      refute_received {:join, _, _}
      refute_received {:unexpected_connect, _}

      MemoryProxy.set_connection(
        %{channel: dead_pid(), host_id: "host-1", socket: self()},
        config
      )
    end
  end

  test "a stopped managed owner does not silently enable request-owned reconnection" do
    MemoryProxy.set_connection_owner(dead_pid())
    MemoryProxy.set_config(%{hub_url: "http://localhost:4220"})
    old_channel = start_supervised!({Agent, fn -> nil end})
    MemoryProxy.set_connection(%{channel: old_channel}, %{})

    assert {:error, :not_connected} =
             MemoryProxy.call("list", %{},
               agent_id: "fixture",
               connector_module: UnexpectedConnector
             )

    refute_received {:unexpected_connect, _}
    MemoryProxy.set_connection_owner(self())
    refute Process.alive?(old_channel)

    assert {:error, :not_connected} =
             MemoryProxy.call("list", %{}, agent_id: "fixture")

    assert_receive {:memory_connection_lost, nil}
  end

  test "a live owner cannot be replaced and stale cleanup cannot erase the new owner" do
    assert :ok = MemoryProxy.set_connection_owner(self())
    next_owner = start_supervised!({Agent, fn -> nil end})
    assert {:error, :connection_owned} = MemoryProxy.set_connection_owner(next_owner)
    assert :ok = MemoryProxy.clear_connection_owner(self())
    assert :ok = MemoryProxy.set_connection_owner(next_owner)
    assert :ok = MemoryProxy.clear_connection_owner(self())
    assert {:error, :connection_owned} = MemoryProxy.set_connection_owner(self())
  end

  test "serializes concurrent reconnect attempts" do
    config = %{hub_url: "http://localhost:4220", token: "host-token", machine_name: "t430"}
    MemoryProxy.set_config(config)

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          MemoryProxy.call("list", %{"scope" => "/tmp"},
            agent_id: "hermes",
            channel_module: FakeChannel,
            connector_module: SlowConnector
          )
        end)
      end

    assert Enum.all?(tasks, fn task ->
             Task.await(task) == {:ok, %{"status" => "ok"}}
           end)

    assert_receive {:connect, ^config}
    refute_receive {:connect, ^config}, 100
  end

  test "disconnects and stops stale socket when replacing the connection" do
    config = %{hub_url: "http://localhost:4220", token: "host-token", machine_name: "t430"}
    {:ok, old_socket} = Supervisor.start_link([], strategy: :one_for_one)
    {:ok, new_socket} = Supervisor.start_link([], strategy: :one_for_one)
    old_ref = Process.monitor(old_socket)

    on_exit(fn ->
      if Process.alive?(new_socket), do: Supervisor.stop(new_socket)
    end)

    MemoryProxy.set_connection(
      %{channel: self(), host_id: "host-1", host_name: "t430", socket: old_socket},
      config
    )

    MemoryProxy.set_connection(
      %{channel: self(), host_id: "host-1", host_name: "t430", socket: new_socket},
      config
    )

    assert_receive {:disconnect, ^old_socket}
    assert_receive {:DOWN, ^old_ref, :process, ^old_socket, :normal}
    refute_received {:disconnect, ^new_socket}
    assert Process.alive?(new_socket)
  end

  test "emits telemetry for memory calls" do
    attach_telemetry("memory-proxy-call")
    MemoryProxy.set_channel(self())

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("list", %{"scope" => "/tmp"},
               agent_id: "hermes",
               channel_module: FakeChannel
             )

    assert_receive {:telemetry, [:backplane, :host_agent, :memory, :call, :start],
                    %{system_time: _},
                    %{agent_id: "hermes", method: "list", argument_keys: ["scope"]}}

    assert_receive {:telemetry, [:backplane, :host_agent, :memory, :call, :stop],
                    %{duration: duration}, %{agent_id: "hermes", method: "list", result: :ok}}

    assert is_integer(duration)
  end

  test "memory call payload carries child traceparent when context exists" do
    MemoryProxy.set_channel(self())
    ctx = Trace.new_ctx()

    assert {:ok, %{"status" => "ok"}} =
             Trace.with_ctx(ctx, fn ->
               MemoryProxy.call("list", %{"scope" => "/tmp"},
                 agent_id: "hermes",
                 channel_module: FakeChannel
               )
             end)

    assert_receive {:push, _channel, "memory_call",
                    %{
                      "method" => "list",
                      "arguments" => %{"agent_id" => "hermes", "scope" => "/tmp"},
                      "traceparent" => traceparent
                    }}

    assert {:ok, child} = Trace.parse_traceparent(traceparent)
    assert child.trace_id == ctx.trace_id
    assert child.parent_id != nil
  end

  test "emits telemetry for memory call errors" do
    attach_telemetry("memory-proxy-error")

    assert {:error, :not_connected} = MemoryProxy.call("list", %{}, agent_id: "hermes")

    assert_receive {:telemetry, [:backplane, :host_agent, :memory, :call, :stop],
                    %{duration: duration},
                    %{agent_id: "hermes", method: "list", result: :error, error: ":not_connected"}}

    assert is_integer(duration)
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end

  defp replace_before_push_snapshot(call, replace) do
    with_otp_debugger(fn -> replace_at_push_entry(call, replace) end)
  end

  defp replace_at_push_entry(call, replace) do
    # The OTP interpreter pauses at the actual selected push, before state() runs.
    # This makes the selection/snapshot race deterministic without product hooks.
    assert {:module, MemoryProxy} = apply(:int, :ni, [MemoryProxy])
    apply(:int, :subscribe, [])
    assert :ok = apply(:int, :break_in, [MemoryProxy, :push_channel, 5])
    task = Task.async(call)
    pid = task.pid

    try do
      assert_receive {:int, {:new_status, ^pid, :break, _}}, 2_000
      replace.()
      assert :ok = apply(:int, :del_break_in, [MemoryProxy, :push_channel, 5])
      assert :ok = apply(:int, :continue, [pid])
      Task.await(task, 2_000)
    after
      apply(:int, :del_break_in, [MemoryProxy, :push_channel, 5])

      if Process.alive?(pid) do
        apply(:int, :continue, [pid])
        Task.shutdown(task, :brutal_kill)
      end

      apply(:int, :nn, [MemoryProxy])
    end
  end

  defp with_otp_debugger(fun) do
    # Mix prunes optional OTP applications from its code path, even when installed.
    [path] =
      :code.root_dir() |> to_string() |> Path.join("lib/debugger-*/ebin") |> Path.wildcard()

    path = String.to_charlist(path)
    present? = path in :code.get_path()
    assert true = :code.add_patha(path)

    try do
      assert {:module, :int} = Code.ensure_loaded(:int)
      fun.()
    after
      unless present?, do: :code.del_path(path)
    end
  end

  defp attach_telemetry(id) do
    owner = self()
    handler_id = "#{id}-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:backplane, :host_agent, :memory, :call, :start],
        [:backplane, :host_agent, :memory, :call, :stop],
        [:backplane, :host_agent, :memory, :call, :exception]
      ],
      fn event, measurements, metadata, _config ->
        send(owner, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
