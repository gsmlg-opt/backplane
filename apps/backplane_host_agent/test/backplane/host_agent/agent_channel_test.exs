defmodule Backplane.HostAgent.AgentChannelTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.AgentChannel

  setup do
    previous_services = Application.get_env(:backplane_host_agent, :local_services)
    :persistent_term.put({__MODULE__.FakeService, :owner}, self())
    Application.put_env(:backplane_host_agent, :local_services, [__MODULE__.FakeService])

    on_exit(fn ->
      if previous_services do
        Application.put_env(:backplane_host_agent, :local_services, previous_services)
      else
        Application.delete_env(:backplane_host_agent, :local_services)
      end

      :persistent_term.erase({__MODULE__.FakeService, :owner})
    end)
  end

  defmodule FakeService do
    def prefix, do: "host_agent"
    def tools, do: []

    def call("install_plugin", args, _ctx) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:local_call, "install_plugin", args})

      {:ok,
       %{
         "plugin" => args["plugin"],
         "runtime" => args["runtime"],
         "installed" => true
       }}
    end
  end

  test "a second channel for the same topic cannot start an unregistered joiner" do
    start_supervised!({Registry, keys: :unique, name: __MODULE__.JoinRegistry})
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    topic = "host_agent:single-owner"
    args = {nil, nil, topic, %{}, __MODULE__.JoinRegistry}
    assert {:ok, first} = DynamicSupervisor.start_child(supervisor, {AgentChannel, args})

    assert {:error, {:already_registered, ^first}} =
             DynamicSupervisor.start_child(supervisor, {AgentChannel, args})

    assert Registry.lookup(__MODULE__.JoinRegistry, topic) == [{first, first}]
    assert DynamicSupervisor.count_children(supervisor).active == 1
  end

  test "duplicate startup keeps private topic and params out of crash logs" do
    start_supervised!({Registry, keys: :unique, name: __MODULE__.PrivateJoinRegistry})
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    topic = "host_agent:private-host-sentinel"

    args =
      {nil, nil, topic, %{"token" => "private-token-sentinel"}, __MODULE__.PrivateJoinRegistry}

    assert {:ok, first} = DynamicSupervisor.start_child(supervisor, {AgentChannel, args})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:already_registered, ^first}} =
                 DynamicSupervisor.start_child(supervisor, {AgentChannel, args})
      end)

    refute log =~ "private-host-sentinel"
    refute log =~ "private-token-sentinel"
    assert AgentChannel.child_spec(args).restart == :temporary
  end

  test "server channel closure terminates the registered client without an unjoined restart" do
    registry = start_supervised!({Registry, keys: :unique, name: __MODULE__.CloseRegistry})
    assert is_pid(registry)
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    for event <- ["phx_error", "phx_close"] do
      topic = "host_agent:closure-#{event}"
      args = {nil, nil, topic, %{}, __MODULE__.CloseRegistry}
      assert {:ok, channel} = DynamicSupervisor.start_child(supervisor, {AgentChannel, args})
      ref = Process.monitor(channel)
      send(channel, %Phoenix.SocketClient.Message{topic: topic, event: event, payload: %{}})
      assert_receive {:DOWN, ^ref, :process, ^channel, :normal}
      assert Registry.lookup(__MODULE__.CloseRegistry, topic) == []
      assert DynamicSupervisor.which_children(supervisor) == []
    end
  end

  test "builds a plugin_call_result by executing the local host-agent service" do
    payload = %{
      "call_id" => "call-1",
      "name" => "host_agent::install_plugin",
      "arguments" => %{"plugin" => "memory", "runtime" => "hermes"}
    }

    assert %{
             "call_id" => "call-1",
             "ok" => true,
             "result" => %{
               "plugin" => "memory",
               "runtime" => "hermes",
               "installed" => true
             }
           } = AgentChannel.plugin_call_result(payload)

    assert_received {:local_call, "install_plugin",
                     %{"plugin" => "memory", "runtime" => "hermes"}}
  end

  test "returns a stable plugin_call_result error for malformed payloads" do
    assert %{"call_id" => nil, "ok" => false, "error" => error} =
             AgentChannel.plugin_call_result(%{"name" => "host_agent::install_plugin"})

    assert error =~ "invalid plugin call"
  end

  test "retired memory events cannot mutate local state or emit acknowledgements" do
    for event <- ~w(memory_facts memory_wipe memory_available memory_access_changed) do
      assert {:noreply, %{}} = AgentChannel.handle_message(event, %{"receipt_key" => "old"}, %{})
    end

    refute_received {:facts, _, _}
    refute_received {:wipe, _, _}
    refute_received {:ack, _}
  end
end
