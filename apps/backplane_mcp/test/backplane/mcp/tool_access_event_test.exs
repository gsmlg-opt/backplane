defmodule Backplane.MCP.ToolAccessEventTest do
  use Backplane.MCP.ObservabilityCase, async: false

  import ExUnit.CaptureLog

  alias Backplane.MCP.{ToolAccessEvent, ToolCall}
  alias Backplane.Observability.Context
  alias Backplane.Registry.ToolRegistry

  @moduletag observability_v2: true

  setup do
    :ets.delete_all_objects(:backplane_tools)

    ToolRegistry.register_managed("fixture", [
      %{
        name: "fixture::echo",
        description: "Echo",
        input_schema: %{"type" => "object"},
        handler: fn args -> {:ok, %{"echo" => args["value"]}} end
      },
      %{
        name: "fixture::fail",
        description: "Fail",
        input_schema: %{"type" => "object"},
        handler: fn _args -> {:error, "managed failure"} end
      }
    ])

    on_exit(fn -> :ets.delete_all_objects(:backplane_tools) end)
    :ok
  end

  test "records managed tool success without argument content" do
    observability = %{
      context: Context.root(request_id: "req-tool-1", trace_id: "trace-tool-1"),
      mcp_request_id: "mcp-root-evt-1"
    }

    assert {:ok, %{"echo" => "hello"}} =
             Backplane.MCP.Dispatch.call_tool(
               "fixture::echo",
               %{"value" => "hello", "secret" => "hidden"},
               %{},
               observability
             )

    flush_tool_logs!()

    assert %ToolCall{} = call = tool_call_for_name("fixture::echo")
    assert call.outcome == "success"
    assert call.execution_kind == "managed"
    assert call.mcp_request_id == "mcp-root-evt-1"
    assert call.trace_id == "trace-tool-1"
    assert call.parent_span_id == observability.context.span_id
    assert is_binary(call.arguments_hash)
    refute call.arguments_hash == ""
    refute Map.has_key?(call, :arguments)
    refute inspect(call) =~ "hidden"
  end

  test "records managed tool error outcome" do
    observability = %{
      context: Context.root(request_id: "req-tool-2"),
      mcp_request_id: "mcp-root-evt-2"
    }

    assert {:error, message} =
             Backplane.MCP.Dispatch.call_tool("fixture::fail", %{}, %{}, observability)

    assert message =~ "managed failure"

    flush_tool_logs!()

    assert %ToolCall{} = call = tool_call_for_name("fixture::fail")
    assert call.outcome == "error"
    assert call.error_kind == "internal"
  end

  test "records unknown tool execution" do
    observability = %{
      context: Context.root(request_id: "req-tool-3"),
      mcp_request_id: "mcp-root-evt-3"
    }

    assert {:error, message} =
             Backplane.MCP.Dispatch.call_tool("missing::tool", %{}, %{}, observability)

    assert message =~ "Unknown tool"
    flush_tool_logs!()

    assert %ToolCall{} = call = tool_call_for_name("missing::tool")
    assert call.outcome == "error"
    assert call.execution_kind == "unknown"
    assert call.error_kind == "not_found"
  end

  test "duplicate child events are idempotent" do
    row = %{
      event_id: "evt-tool-dup-001",
      tool_name: "fixture::echo",
      outcome: "success",
      execution_kind: "managed",
      metadata: %{}
    }

    assert :ok = Backplane.Observability.Buffer.try_enqueue(:mcp_tool_calls, row)
    assert :ok = Backplane.Observability.Buffer.try_enqueue(:mcp_tool_calls, row)
    flush_tool_logs!()

    import Ecto.Query

    assert [%ToolCall{}] =
             Backplane.Repo.all(from(t in ToolCall, where: t.event_id == ^row.event_id))
  end

  test "span_tool_call skips duplicate Logger output when v2 enabled" do
    log =
      capture_log(fn ->
        Backplane.Telemetry.span_tool_call("fixture::echo", fn -> {:ok, "ok"} end)
      end)

    refute log =~ "Tool call completed"
  end

  test "ToolAccessEvent emits v2 telemetry for metrics consumers" do
    handler_id = "tool-access-test-#{System.unique_integer()}"

    :telemetry.attach(
      handler_id,
      [:backplane, :mcp_proxy, :tool_call, :stop],
      fn _event, _measurements, metadata, _config ->
        send(self(), {:tool_stop, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    observability = %{context: Context.root(request_id: "req-tool-4"), mcp_request_id: nil}

    ToolAccessEvent.span("fixture::echo", %{}, observability, fn _ctx ->
      {:ok, "ok", %{execution_kind: "managed"}}
    end)

    assert_receive {:tool_stop, metadata}

    attrs = Map.get(metadata, :attributes, %{})
    assert Map.get(attrs, :tool_name) == "fixture::echo" or Map.get(attrs, "tool_name") == "fixture::echo"
  end
end
