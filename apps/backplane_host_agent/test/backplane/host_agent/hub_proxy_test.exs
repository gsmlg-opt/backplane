defmodule Backplane.HostAgent.HubProxyTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.{HubProxy, MemoryProxy, Trace}

  defmodule FakeChannel do
    def push(channel, event, payload, _timeout \\ 5_000) do
      send(channel, {:push, event, payload})
      {:ok, %{"ok" => true, "result" => %{"status" => "ok"}}}
    end
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
end
