defmodule Backplane.Admin.LogsSinksLiveTest do
  use ExUnit.Case, async: true

  require Phoenix.LiveViewTest

  alias Backplane.Admin.LogsSinksLive

  test "aggregates MCP root and tool writer records and queue health" do
    health =
      LogsSinksLive.aggregate_mcp_health(healthy_channel(queued: 12), healthy_channel(queued: 3))

    assert health.status == :ok
    assert health.inserted_total == 2_468
    assert health.dropped_total == 10
    assert health.failed_total == 4
    assert health.duplicate_total == 14
    assert health.root.queue == %{queued: 12, capacity: 100}
    assert health.tools.queue == %{queued: 3, capacity: 100}
  end

  test "does not report MCP health as healthy when a channel is missing or unavailable" do
    root = healthy_channel()

    assert %{status: :unavailable, tools: %{queue: %{queued: 0, capacity: 0}}} =
             LogsSinksLive.aggregate_mcp_health(root, nil)

    assert %{status: :unavailable} =
             LogsSinksLive.aggregate_mcp_health(root, %{status: :unavailable})

    assert %{status: :unavailable} = LogsSinksLive.aggregate_mcp_health(nil, root)
    assert %{status: :unavailable} = LogsSinksLive.aggregate_mcp_health(%{}, %{})

    assert %{status: :unavailable} =
             LogsSinksLive.aggregate_mcp_health(root, %{status: :ok})

    assert %{status: :unavailable} =
             LogsSinksLive.aggregate_mcp_health(
               root,
               %{status: :ok, buffer: %{status: :unavailable, queued: 0, capacity: 100}}
             )
  end

  test "renders one MCP writer with comma-formatted aggregate and channel counts" do
    html =
      Phoenix.LiveViewTest.render_component(&LogsSinksLive.render/1,
        loading: false,
        observability: %{settings: %{}, flags: %{}, runtime_sink: %{}, buffers: %{}},
        llm_writer: %{status: :disabled},
        mcp_writer: healthy_channel(queued: 1_200),
        mcp_tool_writer: healthy_channel(queued: 3),
        audit_writer: %{status: :disabled},
        metrics: %{}
      )

    assert length(Regex.scan(~r/MCP LogWriter/, html)) == 1
    refute html =~ "MCP ToolLogWriter"
    assert html =~ "2,468"
    assert html =~ "1,234"
    assert html =~ "queue 1,200/100"
    assert html =~ "Request records"
    assert html =~ "Tool calls"
  end

  test "reports disabled only when both MCP channels are disabled" do
    disabled = %{status: :disabled}

    assert %{status: :disabled} = LogsSinksLive.aggregate_mcp_health(disabled, disabled)

    assert %{status: :degraded} =
             LogsSinksLive.aggregate_mcp_health(disabled, healthy_channel())
  end

  defp healthy_channel(overrides \\ []) do
    %{
      status: :ok,
      buffer: %{status: :ok, queued: 0, capacity: 100},
      inserted_total: 1_234,
      dropped_total: 5,
      failed_total: 2,
      duplicate_total: 7
    }
    |> Map.update!(:buffer, fn buffer ->
      Map.merge(buffer, Map.new(overrides))
    end)
  end
end
