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
      <h1 class="text-2xl font-bold text-white mb-6">Logs</h1>

      <div class="flex gap-2 mb-6">
        <button
          :for={tab <- ["jobs", "tool_calls"]}
          phx-click="switch_tab"
          phx-value-tab={tab}
          class={[
            "px-3 py-1.5 text-sm font-medium rounded-md",
            if(@tab == tab,
              do: "bg-emerald-700 text-white",
              else: "bg-gray-800 text-gray-400 hover:text-white"
            )
          ]}
        >
          {tab_label(tab)}
        </button>
      </div>

      <div :if={@tab == "jobs"}>
        <div :if={@jobs == []} class="text-gray-400 text-sm">No recent jobs found.</div>
        <div class="overflow-x-auto">
          <table :if={@jobs != []} class="w-full text-sm">
            <thead>
              <tr class="text-left text-gray-400 border-b border-gray-800">
                <th class="pb-2 pr-4">Worker</th>
                <th class="pb-2 pr-4">Queue</th>
                <th class="pb-2 pr-4">State</th>
                <th class="pb-2 pr-4">Attempt</th>
                <th class="pb-2 pr-4">Started</th>
                <th class="pb-2">Completed</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={job <- @jobs}
                class="border-b border-gray-900 text-gray-300"
              >
                <td class="py-2 pr-4 font-mono text-xs">{short_worker(job.worker)}</td>
                <td class="py-2 pr-4">{job.queue}</td>
                <td class="py-2 pr-4">
                  <span class={state_color(job.state)}>{job.state}</span>
                </td>
                <td class="py-2 pr-4">{job.attempt}/{job.max_attempts}</td>
                <td class="py-2 pr-4 text-xs">{format_time(job.attempted_at)}</td>
                <td class="py-2 text-xs">{format_time(job.completed_at)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div :if={@tab == "tool_calls"}>
        <div :if={@tool_events == []} class="text-gray-400 text-sm">
          No tool call events yet. Events appear in real-time as tools are called.
        </div>
        <div class="space-y-1">
          <div
            :for={event <- @tool_events}
            class="flex items-center gap-3 py-1.5 border-b border-gray-900 text-sm"
          >
            <span class={event_color(event.event)}>{event.event}</span>
            <span class="font-mono text-xs text-gray-300">{event.tool}</span>
            <span :if={event.reason} class="text-xs text-red-400 truncate max-w-md">
              {to_string(event.reason)}
            </span>
            <span class="ml-auto text-xs text-gray-500">{format_time(event.timestamp)}</span>
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

  defp state_color("completed"), do: "text-green-400"
  defp state_color("executing"), do: "text-blue-400"
  defp state_color("retryable"), do: "text-amber-400"
  defp state_color("discarded"), do: "text-red-400"
  defp state_color(_), do: "text-gray-400"

  defp event_color(:dispatched), do: "text-blue-400"
  defp event_color(:completed), do: "text-green-400"
  defp event_color(:failed), do: "text-red-400"
  defp event_color(_), do: "text-gray-400"

  defp format_time(nil), do: "-"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(_), do: "-"
end
