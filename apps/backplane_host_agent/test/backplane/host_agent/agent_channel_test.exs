defmodule Backplane.HostAgent.AgentChannelTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.AgentChannel

  setup do
    previous_services = Application.get_env(:backplane_host_agent, :local_services)
    previous_syncer = Application.get_env(:backplane_host_agent, :edge_syncer_module)
    previous_facts = Application.get_env(:backplane_host_agent, :memory_facts_module)
    previous_push = Application.get_env(:backplane_host_agent, :agent_channel_push_module)
    previous_edge = Application.get_env(:backplane_host_agent, :memory_host_sync_v2)
    :persistent_term.put({__MODULE__.FakeService, :owner}, self())
    Application.put_env(:backplane_host_agent, :local_services, [__MODULE__.FakeService])

    on_exit(fn ->
      if previous_services do
        Application.put_env(:backplane_host_agent, :local_services, previous_services)
      else
        Application.delete_env(:backplane_host_agent, :local_services)
      end

      :persistent_term.erase({__MODULE__.FakeService, :owner})
      restore_env(:edge_syncer_module, previous_syncer)
      restore_env(:memory_facts_module, previous_facts)
      restore_env(:agent_channel_push_module, previous_push)
      restore_env(:memory_host_sync_v2, previous_edge)
    end)
  end

  defmodule FakeSyncer do
    def memory_available(hint),
      do: send(:persistent_term.get({__MODULE__, :owner}), {:wake, hint})
  end

  defmodule FakeFacts do
    def apply_facts(payload, opts) do
      send(:persistent_term.get({__MODULE__, :owner}), {:facts, payload, opts})
      Process.get(:facts_result, {:ok, %{}})
    end

    def apply_wipe(payload, opts) do
      send(:persistent_term.get({__MODULE__, :owner}), {:wipe, payload, opts})
      Process.get(:wipe_result, {:ok, %{}})
    end
  end

  defmodule FakePush do
    def handle_push_cast(message, state) do
      send(:persistent_term.get({__MODULE__, :owner}), {:ack, message})
      {:noreply, state}
    end
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

  test "memory_available wakes the edge syncer" do
    :persistent_term.put({FakeSyncer, :owner}, self())
    Application.put_env(:backplane_host_agent, :edge_syncer_module, FakeSyncer)

    assert {:noreply, %{}} =
             AgentChannel.handle_message("memory_available", %{"current_revision" => 1}, %{})

    assert_received {:wake, %{"current_revision" => 1}}
  end

  test "facts ACK follows durable apply" do
    configure_memory_callbacks()
    payload = receipt(%{"facts" => []})
    assert {:noreply, %{}} = AgentChannel.handle_message("memory_facts", payload, %{})
    assert_received {:facts, ^payload, _}
    assert_received {:ack, {"memory_facts_ack", ack}}
    assert ack["status"] == "applied"
  end

  test "protection failure emits no facts ACK" do
    configure_memory_callbacks()
    Process.put(:facts_result, {:error, :protection_unavailable})
    assert {:noreply, %{}} = AgentChannel.handle_message("memory_facts", receipt(%{}), %{})
    assert_received {:facts, _, _}
    refute_received {:ack, _}
  end

  test "wipe ACK follows apply and storage failure emits no ACK" do
    configure_memory_callbacks()
    payload = receipt(%{"items" => []})
    assert {:noreply, %{}} = AgentChannel.handle_message("memory_wipe", payload, %{})
    assert_received {:wipe, ^payload, _}
    assert_received {:ack, {"memory_wipe_ack", _}}

    Process.put(:wipe_result, {:error, :storage_error})
    assert {:noreply, %{}} = AgentChannel.handle_message("memory_wipe", payload, %{})
    assert_received {:wipe, ^payload, _}
    refute_received {:ack, _}
  end

  defp configure_memory_callbacks do
    :persistent_term.put({FakeFacts, :owner}, self())
    Application.put_env(:backplane_host_agent, :memory_facts_module, FakeFacts)
    Application.put_env(:backplane_host_agent, :agent_channel_push_module, FakePush)
    :persistent_term.put({FakePush, :owner}, self())
  end

  defp receipt(extra),
    do: Map.merge(%{"receipt_key" => "r", "payload_hash" => "h", "scope" => "private"}, extra)

  defp restore_env(key, nil), do: Application.delete_env(:backplane_host_agent, key)
  defp restore_env(key, value), do: Application.put_env(:backplane_host_agent, key, value)
end
