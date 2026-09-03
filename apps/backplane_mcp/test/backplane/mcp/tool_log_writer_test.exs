defmodule Backplane.MCP.ToolLogWriterTest do
  use Backplane.MCP.ObservabilityCase, async: false

  import Ecto.Query

  alias Backplane.MCP.{ToolCall, ToolLogWriter}
  alias Backplane.Observability.Buffer
  alias Backplane.Repo

  @moduletag observability_v2: true

  test "persists sanitized tool rows with event_id conflict handling" do
    row = %{
      event_id: "evt-tool-writer-001",
      tool_name: "fixture::echo",
      outcome: "success",
      execution_kind: "managed",
      arguments_hash: "abc123",
      metadata: %{}
    }

    assert :ok = Buffer.try_enqueue(:mcp_tool_calls, row)
    assert :ok = Buffer.try_enqueue(:mcp_tool_calls, row)
    flush_tool_logs!()

    assert [%ToolCall{} = call] =
             Repo.all(from(t in ToolCall, where: t.event_id == ^row.event_id))

    assert call.tool_name == "fixture::echo"
    refute Map.has_key?(call, :arguments)
  end

  test "health reflects buffer and insert totals" do
    assert :ok =
             Buffer.try_enqueue(:mcp_tool_calls, %{
               event_id: "evt-tool-health-001",
               tool_name: "fixture::echo",
               outcome: "success",
               metadata: %{}
             })

    flush_tool_logs!()

    health = ToolLogWriter.health()
    assert health.status == :ok
    assert health.inserted_total >= 1
    assert is_map(health.buffer)
  end

  test "writer database failure does not crash the process" do
    assert :ok =
             Buffer.try_enqueue(:mcp_tool_calls, %{
               tool_name: "fixture::echo",
               outcome: "success"
             })

    flush_tool_logs!()
    health = ToolLogWriter.health()
    assert health.status == :ok
    assert health.failed_total >= 1
  end
end
