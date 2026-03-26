defmodule Backplane.NotificationsTest do
  use ExUnit.Case, async: true

  alias Backplane.Notifications

  setup do
    # Ensure :pg scope and debounce table are started
    unless :ets.whereis(:backplane_notification_debounce) != :undefined do
      :ets.new(:backplane_notification_debounce, [
        :named_table,
        :public,
        :set,
        write_concurrency: true
      ])
    end

    # Start :pg scope if not already started (Application may have started it)
    case :pg.start_link(:backplane_notifications) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Clear debounce state between tests
    :ets.delete_all_objects(:backplane_notification_debounce)

    # Unsubscribe current process to clean state
    :pg.leave(:backplane_notifications, :mcp_subscribers, self())
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

  test "debounce suppresses rapid duplicate notifications" do
    Notifications.subscribe()

    # First call should send
    Notifications.tools_changed()
    assert_receive {:mcp_notification, %{method: "notifications/tools/list_changed"}}

    # Rapid second call should be debounced
    Notifications.tools_changed()
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
