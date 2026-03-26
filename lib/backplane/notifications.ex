defmodule Backplane.Notifications do
  @moduledoc """
  Lightweight pub/sub for server-initiated MCP notifications using OTP :pg.

  SSE connections subscribe by joining the :mcp_subscribers group.
  Internal modules broadcast events that get forwarded to all connected clients.
  """

  @scope :backplane_notifications
  @group :mcp_subscribers

  @doc "Start the :pg scope. Called from the supervision tree."
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {:pg, :start_link, [@scope]},
      type: :worker
    }
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

  @doc "Notify clients that the tool list has changed."
  def tools_changed do
    broadcast(%{
      jsonrpc: "2.0",
      method: "notifications/tools/list_changed"
    })
  end

  @doc "Notify clients that the resource list has changed."
  def resources_changed do
    broadcast(%{
      jsonrpc: "2.0",
      method: "notifications/resources/list_changed"
    })
  end

  @doc "Notify clients that the prompt list has changed."
  def prompts_changed do
    broadcast(%{
      jsonrpc: "2.0",
      method: "notifications/prompts/list_changed"
    })
  end

  @doc "Returns the number of active subscribers."
  def subscriber_count do
    length(subscribers())
  end

  defp subscribers do
    :pg.get_members(@scope, @group)
  rescue
    # :pg group may not exist yet
    ArgumentError -> []
  end
end
