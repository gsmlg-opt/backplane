defmodule Backplane.NotificationsTest do
  use ExUnit.Case, async: true

  alias Backplane.Notifications

  setup do
    # Ensure :pg scope is started (application.ex starts it, but test may need it)
    start_supervised!({:pg, :backplane_notifications})
    :ok
  end

  test "subscribe/unsubscribe lifecycle" do
    assert Notifications.subscriber_count() == 0

    Notifications.subscribe()
    assert Notifications.subscriber_count() == 1

    Notifications.unsubscribe()
    assert Notifications.subscriber_count() == 0
  end

  test "broadcast delivers to subscribers" do
    Notifications.subscribe()

    notification = %{jsonrpc: "2.0", method: "notifications/tools/list_changed"}
    Notifications.broadcast(notification)

    assert_receive {:mcp_notification, ^notification}
  end

  test "tools_changed sends correct notification" do
    Notifications.subscribe()
    Notifications.tools_changed()

    assert_receive {:mcp_notification,
                    %{jsonrpc: "2.0", method: "notifications/tools/list_changed"}}
  end

  test "resources_changed sends correct notification" do
    Notifications.subscribe()
    Notifications.resources_changed()

    assert_receive {:mcp_notification,
                    %{jsonrpc: "2.0", method: "notifications/resources/list_changed"}}
  end

  test "prompts_changed sends correct notification" do
    Notifications.subscribe()
    Notifications.prompts_changed()

    assert_receive {:mcp_notification,
                    %{jsonrpc: "2.0", method: "notifications/prompts/list_changed"}}
  end

  test "broadcast does not deliver to unsubscribed processes" do
    Notifications.subscribe()
    Notifications.unsubscribe()

    Notifications.broadcast(%{jsonrpc: "2.0", method: "test"})

    refute_receive {:mcp_notification, _}, 50
  end

  test "multiple subscribers all receive notifications" do
    parent = self()

    pids =
      for i <- 1..3 do
        spawn(fn ->
          Notifications.subscribe()
          send(parent, {:ready, i})

          receive do
            {:mcp_notification, msg} -> send(parent, {:got, i, msg})
          end
        end)
      end

    # Wait for all to subscribe
    for i <- 1..3, do: assert_receive({:ready, ^i})

    notification = %{jsonrpc: "2.0", method: "test/multi"}
    Notifications.broadcast(notification)

    for i <- 1..3 do
      assert_receive {:got, ^i, ^notification}
    end

    # Clean up
    for pid <- pids, Process.alive?(pid), do: Process.exit(pid, :kill)
  end
end
