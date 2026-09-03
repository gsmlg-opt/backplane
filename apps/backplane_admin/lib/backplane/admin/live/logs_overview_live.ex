defmodule Backplane.Admin.LogsOverviewLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.LogsComponents

  alias Backplane.LLM.LogQuery, as: LlmLogQuery
  alias Backplane.MCP.LogQuery, as: McpLogQuery
  alias Backplane.PubSubBroadcaster

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSubBroadcaster.subscribe(PubSubBroadcaster.tools_call_topic())
    end

    {:ok,
     assign(socket,
       current_path: "/system/logs",
       loading: true,
       llm_stats: nil,
       mcp_stats: nil,
       tool_events: []
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    time_filters = %{since: default_since(), until: default_until()}

    {:noreply,
     socket
     |> assign(loading: false)
     |> assign_stats(time_filters)}
  end

  @impl true
  def handle_info({event, payload}, socket)
      when event in [:dispatched, :completed, :failed] do
    entry = %{
      event: event,
      tool: payload[:tool],
      reason: payload[:reason],
      timestamp: DateTime.utc_now()
    }

    {:noreply, assign(socket, tool_events: Enum.take([entry | socket.assigns.tool_events], 20))}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="mb-2 text-2xl font-bold">Logs</h1>
      <p class="mb-6 text-sm text-on-surface-variant">
        Durable observability records for LLM proxy, MCP hub, audit trails, and background jobs.
      </p>

      <.logs_nav current="/system/logs" />

      <div :if={@loading} class="mb-6">
        <.loading_state />
      </div>

      <div :if={!@loading} class="mb-8 grid gap-4 sm:grid-cols-2">
        <.dm_card variant="bordered">
          <:title>LLM (24h)</:title>
          <.dm_stat title="Requests" value={format_number(@llm_stats.total_requests)} />
          <.link navigate={~p"/system/logs/llm"} class="mt-3 inline-block text-sm text-primary underline">
            Browse LLM logs
          </.link>
        </.dm_card>

        <.dm_card variant="bordered">
          <:title>MCP (24h)</:title>
          <.dm_stat title="Requests" value={format_number(@mcp_stats.total_requests)} />
          <.link navigate={~p"/system/logs/mcp"} class="mt-3 inline-block text-sm text-primary underline">
            Browse MCP logs
          </.link>
        </.dm_card>
      </div>

      <.dm_card variant="bordered">
        <:title>Live tool activity (non-durable)</:title>
        <p class="mb-3 text-xs text-on-surface-variant">
          Real-time PubSub events since this page loaded. For persisted tool calls, open MCP log detail.
        </p>
        <div :if={@tool_events == []} class="text-sm text-on-surface-variant">
          No live tool events yet.
        </div>
        <div class="space-y-1">
          <div
            :for={event <- @tool_events}
            class="flex items-center gap-3 border-b border-outline-variant py-1.5 text-sm"
          >
            <span class={event_color(event.event)}>{event.event}</span>
            <span class="font-mono text-xs text-on-surface">{event.tool}</span>
            <span :if={event.reason} class="max-w-md truncate text-xs text-error">
              {to_string(event.reason)}
            </span>
            <span class="ml-auto text-xs text-on-surface-variant">
              <.local_time datetime={event.timestamp} format="time" />
            </span>
          </div>
        </div>
      </.dm_card>
    </div>
    """
  end

  defp assign_stats(socket, filters) do
    socket
    |> assign(llm_stats: safe_aggregate(&LlmLogQuery.aggregate/1, filters))
    |> assign(mcp_stats: safe_aggregate(&McpLogQuery.aggregate/1, filters))
  end

  defp safe_aggregate(fun, filters) do
    fun.(filters)
  rescue
    _ ->
      %{total_requests: 0}
  end

  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(value), do: to_string(value || 0)

  defp event_color(:dispatched), do: "text-info"
  defp event_color(:completed), do: "text-success"
  defp event_color(:failed), do: "text-error"
  defp event_color(_), do: "text-on-surface-variant"
end
