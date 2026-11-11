defmodule Backplane.Admin.MemorySessionsLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_blank_state: 1, memory_page_header: 1]

  alias Backplane.Memory.{AdminQueries, Distillations}

  @retryable ~w(failed blocked completed)
  @error_limit 200

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket, current_path: "/memory/sessions", sessions: [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if connected?(socket),
      do: {:noreply, assign(socket, sessions: AdminQueries.recent_sessions(100))},
      else: {:noreply, socket}
  end

  @impl true
  def handle_event("retry-distillation", %{"subject_id" => subject_id}, socket) do
    socket =
      case Distillations.retry(subject_id) do
        {:ok, _row} -> put_flash(socket, :info, dgettext("admin", "Distillation scheduled"))
        {:error, :not_found} -> put_flash(socket, :error, dgettext("errors", "Session cannot be retried"))
      end

    {:noreply, assign(socket, sessions: AdminQueries.recent_sessions(100))}
  end

  defp retryable?(%{distillation: %{status: status}}), do: status in @retryable
  defp retryable?(_), do: false

  defp truncate_error(nil), do: nil
  defp truncate_error(error), do: String.slice(error, 0, @error_limit)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="memory-page">
      <.memory_page_header title={dgettext("navigation", "Sessions")} subtitle={dgettext("admin", "Recently active agent sessions")} />
      <.memory_blank_state
        :if={@sessions == []}
        id="memory-sessions-empty"
        title={dgettext("admin", "No sessions")}
        description={dgettext("admin", "No sessions have been captured yet.")}
      />
      <div :if={@sessions != []} class="min-w-0 w-full overflow-x-auto">
        <.dm_table id="memory-sessions-table" data={@sessions} hover zebra>
          <:col :let={s} label={dgettext("admin", "Session")}><span class="break-all">{s.session.session_id}</span></:col>
          <:col :let={s} label={dgettext("admin", "Host")}>{s.session.host_id}</:col>
          <:col :let={s} label={dgettext("admin", "Agent")}>{s.session.agent_id}</:col>
          <:col :let={s} label={dgettext("common", "Status")}>{s.session.status}</:col>
          <:col :let={s} label={dgettext("admin", "Started")}><.local_time datetime={s.session.started_at} format="short" /></:col>
          <:col :let={s} label={dgettext("admin", "Ended")}><.local_time datetime={s.session.ended_at} format="short" /></:col>
          <:col :let={s} label={dgettext("admin", "Events")}>{s.event_count}</:col>
          <:col :let={s} label={dgettext("admin", "Distillation")}>
            <span :if={s.distillation} id={"distill-status-#{s.session.subject_id}"}>
              {s.distillation.status} ({s.distillation.mode})
            </span>
          </:col>
          <:col :let={s} label={dgettext("errors", "Error")}>
            <span
              :if={s.distillation && s.distillation.last_error}
              id={"distill-error-#{s.session.subject_id}"}
              class="break-words text-error"
            >
              {truncate_error(s.distillation.last_error)}
            </span>
          </:col>
          <:col :let={s} label={dgettext("admin", "Records")}>{s.distillation && s.distillation.records_written}</:col>
          <:col :let={s} label="">
            <.dm_btn
              :if={retryable?(s)}
              id={"distill-retry-#{s.session.subject_id}"}
              type="button"
              size="sm"
              variant="outline"
              phx-click="retry-distillation"
              phx-value-subject_id={s.session.subject_id}
            >
              {dgettext("common", "Retry")}
            </.dm_btn>
          </:col>
        </.dm_table>
      </div>
    </div>
    """
  end
end
