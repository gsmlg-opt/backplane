defmodule Backplane.HostAgent.HubProxyTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.{HubProxy, MemoryProxy, Trace}

  defmodule FakeChannel do
    def push(channel, event, payload, _timeout \\ 5_000) do
      send(channel, {:push, event, payload})
      reply(event, payload)
    end

    defp reply("memory_pull", %{"cursor" => %{"id" => "bad"}}),
      do: {:error, %{"code" => "invalid_cursor", "retryable" => false}}

    defp reply("memory_pull", _payload),
      do: {:ok, %{"records" => [%{"id" => "r1"}], "cursor" => %{"id" => "r1"}}}

    defp reply(_event, _payload), do: {:ok, %{"ok" => true, "result" => %{"status" => "ok"}}}
  end

  setup do
    previous = Application.get_env(:backplane_host_agent, :channel_module)
    Application.put_env(:backplane_host_agent, :channel_module, FakeChannel)
    MemoryProxy.set_channel(self())

    on_exit(fn ->
      MemoryProxy.set_channel(nil)

      if previous do
        Application.put_env(:backplane_host_agent, :channel_module, previous)
      else
        Application.delete_env(:backplane_host_agent, :channel_module)
      end
    end)
  end

  test "call_tool payload carries child traceparent when context exists" do
    ctx = Trace.new_ctx()

    assert {:ok, %{"status" => "ok"}} =
             Trace.with_ctx(ctx, fn ->
               HubProxy.call_tool("hub::echo", %{"x" => 1})
             end)

    assert_receive {:push, "mcp_tool_call",
                    %{
                      "name" => "hub::echo",
                      "arguments" => %{"x" => 1},
                      "traceparent" => traceparent
                    }}

    assert {:ok, child} = Trace.parse_traceparent(traceparent)
    assert child.trace_id == ctx.trace_id
    assert child.parent_id != nil
  end

  test "pull_memory pushes memory_pull and normalizes the reply" do
    assert {:ok, %{"records" => [%{"id" => "r1"}], "cursor" => %{"id" => "r1"}}} =
             HubProxy.pull_memory(nil, 200)

    assert_receive {:push, "memory_pull", %{"cursor" => nil, "limit" => 200}}

    assert {:error, "invalid_cursor"} = HubProxy.pull_memory(%{"id" => "bad"}, 200)
  end

  test "pull_memory reports not_connected without a channel" do
    MemoryProxy.set_channel(nil)
    assert {:error, :not_connected} = HubProxy.pull_memory(nil, 200)
  end
end
