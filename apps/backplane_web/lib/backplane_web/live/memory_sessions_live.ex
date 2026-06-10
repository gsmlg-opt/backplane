defmodule BackplaneWeb.MemorySessionsLive do
  @moduledoc "Paginated list of agent observation sessions."

  use BackplaneWeb, :live_view

  import Ecto.Query

  @page_size 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/memory/sessions",
       sessions: [],
       page: 1,
       page_size: @page_size
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page =
      case Integer.parse(to_string(params["page"] || "1")) do
        {n, _} when n > 0 -> n
        _ -> 1
      end

    sessions = load_sessions(page)
    {:noreply, assign(socket, sessions: sessions, page: page)}
  end

  defp load_sessions(page) do
    safe_call(
      fn ->
        repo = Application.fetch_env!(:backplane_memory, :repo)
        alias BackplaneMemory.Observations.Session
        offset = (page - 1) * @page_size

        repo.all(
          from(s in Session,
            order_by: [desc: s.started_at],
            limit: @page_size,
            offset: ^offset
          )
        )
      end,
      []
    )
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp format_dt(nil), do: "active"
  defp format_dt(dt) do
    assigns = %{dt: dt}
    ~H"""
    <.local_time datetime={@dt} />
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">Sessions</h1>
        <p class="text-sm text-on-surface-variant mt-1">
          Agent observation sessions. Page {@page}.
        </p>
      </div>

      <.dm_card variant="bordered">
        <div :if={@sessions == []} class="text-on-surface-variant text-sm py-4">
          No sessions recorded yet.
        </div>
        <div :if={@sessions != []} class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-outline-variant">
                <th class="text-left py-2 font-medium">Session ID</th>
                <th class="text-left py-2 font-medium">Project</th>
                <th class="text-left py-2 font-medium">Started</th>
                <th class="text-left py-2 font-medium">Ended</th>
                <th class="text-right py-2 font-medium">Observations</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={s <- @sessions} class="border-b border-outline-variant/40">
                <td class="py-2 font-mono text-xs">{s.session_id}</td>
                <td class="py-2">{s.project}</td>
                <td class="py-2 text-xs">{format_dt(s.started_at)}</td>
                <td class="py-2 text-xs">
                  <.dm_badge :if={is_nil(s.ended_at)} variant="success">active</.dm_badge>
                  <span :if={!is_nil(s.ended_at)}>{format_dt(s.ended_at)}</span>
                </td>
                <td class="py-2 text-right">{s.observation_count}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.dm_card>

      <div class="flex items-center justify-between mt-4 text-sm">
        <div class="text-on-surface-variant">Page {@page}</div>
        <div class="flex items-center gap-2">
          <.link :if={@page > 1} patch={~p"/admin/memory/sessions?#{%{page: @page - 1}}"}>
            <.dm_btn size="xs">Previous</.dm_btn>
          </.link>
          <.link :if={length(@sessions) == @page_size} patch={~p"/admin/memory/sessions?#{%{page: @page + 1}}"}>
            <.dm_btn size="xs">Next</.dm_btn>
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
