defmodule BackplaneWeb.LogsLive do
  use BackplaneWeb, :live_view

  import Ecto.Query

  alias Backplane.PubSubBroadcaster
  alias Backplane.Repo

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSubBroadcaster.subscribe(PubSubBroadcaster.tools_call_topic())
      PubSubBroadcaster.subscribe(PubSubBroadcaster.skills_sync_topic())
    end

    {:ok,
     assign(socket,
       current_path: "/admin/logs",
       loading: true,
       tab: "jobs",
       jobs: [],
       tool_events: []
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({event, payload}, socket)
      when event in [:dispatched, :completed, :failed] do
    tool_events = socket.assigns.tool_events

    entry = %{
      event: event,
      tool: payload[:tool],
      reason: payload[:reason],
      timestamp: DateTime.utc_now()
    }

    # Keep last 100 events in memory
    tool_events = Enum.take([entry | tool_events], 100)

    {:noreply, assign(socket, tool_events: tool_events)}
  end

  def handle_info({event, _payload}, socket)
      when event in [:started] do
    {:noreply, load_data(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: tab)}
  end

  defp load_data(socket) do
    jobs = load_recent_jobs()
    assign(socket, loading: false, jobs: jobs)
  end

  defp load_recent_jobs do
    from(j in "oban_jobs",
      where: j.state in ["completed", "executing", "retryable", "discarded"],
      order_by: [desc: j.attempted_at],
      limit: ^@page_size,
      select: %{
        id: j.id,
        worker: j.worker,
        queue: j.queue,
        state: j.state,
        attempted_at: j.attempted_at,
        completed_at: j.completed_at,
        attempt: j.attempt,
        max_attempts: j.max_attempts,
        args: j.args
      }
    )
    |> Repo.all()
  rescue
    _ -> []
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-2xl font-bold mb-6">Logs</h1>

      <div class="flex gap-2 mb-6">
        <.dm_btn
          :for={tab <- ["jobs", "tool_calls"]}
          variant={if @tab == tab, do: "primary", else: nil}
          size="sm"
          phx-click="switch_tab"
          phx-value-tab={tab}
        >
          {tab_label(tab)}
        </.dm_btn>
      </div>

      <div :if={@tab == "jobs"}>
        <div :if={@jobs == []} class="text-on-surface-variant text-sm">No recent jobs found.</div>
        <.dm_table :if={@jobs != []} id="jobs-table" data={@jobs} hover zebra>
          <:col :let={job} label="Worker">
            <span class="font-mono text-xs">{short_worker(job.worker)}</span>
          </:col>
          <:col :let={job} label="Queue">{job.queue}</:col>
          <:col :let={job} label="State">
            <.dm_badge variant={state_badge_variant(job.state)} size="sm">
              {job.state}
            </.dm_badge>
          </:col>
          <:col :let={job} label="Attempt">{job.attempt}/{job.max_attempts}</:col>
          <:col :let={job} label="Started">
            <span class="text-xs">{format_time(job.attempted_at)}</span>
          </:col>
          <:col :let={job} label="Completed">
            <span class="text-xs">{format_time(job.completed_at)}</span>
          </:col>
        </.dm_table>
      </div>

      <div :if={@tab == "tool_calls"}>
        <div :if={@tool_events == []} class="text-on-surface-variant text-sm">
          No tool call events yet. Events appear in real-time as tools are called.
        </div>
        <div class="space-y-1">
          <div
            :for={event <- @tool_events}
            class="flex items-center gap-3 py-1.5 border-b border-outline-variant text-sm"
          >
            <span class={event_color(event.event)}>{event.event}</span>
            <span class="font-mono text-xs text-on-surface">{event.tool}</span>
            <span :if={event.reason} class="text-xs text-error truncate max-w-md">
              {to_string(event.reason)}
            </span>
            <span class="ml-auto text-xs text-on-surface-variant">{format_time(event.timestamp)}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp tab_label("jobs"), do: "Background Jobs"
  defp tab_label("tool_calls"), do: "Tool Calls"
  defp tab_label(other), do: other

  defp short_worker(worker) when is_binary(worker) do
    worker
    |> String.split(".")
    |> Enum.take(-2)
    |> Enum.join(".")
  end

  defp short_worker(worker), do: to_string(worker)

  defp state_badge_variant("completed"), do: "success"
  defp state_badge_variant("executing"), do: "info"
  defp state_badge_variant("retryable"), do: "warning"
  defp state_badge_variant("discarded"), do: "error"
  defp state_badge_variant(_), do: "neutral"

  defp event_color(:dispatched), do: "text-info"
  defp event_color(:completed), do: "text-success"
  defp event_color(:failed), do: "text-error"
  defp event_color(_), do: "text-on-surface-variant"

  defp format_time(nil), do: "-"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(_), do: "-"
end
