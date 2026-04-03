defmodule Backplane.Notifications do
  @moduledoc """
  Lightweight pub/sub for server-initiated MCP notifications using OTP :pg.

  SSE connections subscribe by joining the :mcp_subscribers group.
  Internal modules broadcast events that get forwarded to all connected clients.

  Notifications of the same type are debounced within a 500ms window to avoid
  flooding clients during bulk operations (e.g., boot-time tool registration).
  """

  @scope :backplane_notifications
  @group :mcp_subscribers
  @debounce_ms 500
  @debounce_table :backplane_notification_debounce

  @doc "Start the :pg scope. Called from the supervision tree."
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start, []},
      type: :worker
    }
  end

  @doc false
  def start do
    :ets.new(@debounce_table, [:named_table, :public, :set, write_concurrency: true])
    :pg.start_link(@scope)
  end

  @doc "Subscribe the calling process to MCP notifications."
  def subscribe do
    :pg.join(@scope, @group, self())
  end

  @doc "Unsubscribe the calling process."
  def unsubscribe do
    :pg.leave(@scope, @group, self())
  end

  @doc "Broadcast a notification to all subscribers."
  def broadcast(notification) when is_map(notification) do
    for pid <- subscribers(), Process.alive?(pid) do
      send(pid, {:mcp_notification, notification})
    end

    :ok
  end

  @doc "Notify clients that the tool list has changed (debounced)."
  def tools_changed do
    debounced_broadcast("notifications/tools/list_changed")
  end

  @doc "Notify clients that the resource list has changed (debounced)."
  def resources_changed do
    debounced_broadcast("notifications/resources/list_changed")
  end

  @doc "Notify clients that the prompt list has changed (debounced)."
  def prompts_changed do
    debounced_broadcast("notifications/prompts/list_changed")
  end

  @doc "Returns the number of active subscribers."
  def subscriber_count do
    length(subscribers())
  end

  # Debounce: only send the notification if no notification of the same type
  # was sent within the last @debounce_ms milliseconds. This prevents flooding
  # SSE clients during bulk operations like boot-time tool registration.
  defp debounced_broadcast(method) do
    now = System.monotonic_time(:millisecond)

    should_send =
      case :ets.lookup(@debounce_table, method) do
        [{^method, last_sent}] -> now - last_sent >= @debounce_ms
        [] -> true
      end

    if should_send do
      :ets.insert(@debounce_table, {method, now})
      broadcast(%{jsonrpc: "2.0", method: method})
    else
      :ok
    end
  rescue
    ArgumentError ->
      # ETS table doesn't exist yet (boot race) — broadcast directly
      broadcast(%{jsonrpc: "2.0", method: method})
  end

  defp subscribers do
    :pg.get_members(@scope, @group)
  rescue
    # :pg group may not exist yet
    ArgumentError -> []
  end
end
