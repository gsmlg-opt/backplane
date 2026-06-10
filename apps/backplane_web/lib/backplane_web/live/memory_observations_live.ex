defmodule BackplaneWeb.MemoryObservationsLive do
  @moduledoc "Live feed of recent agent observations."

  use BackplaneWeb, :live_view

  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    safe_call(
      fn -> Phoenix.PubSub.subscribe(Backplane.PubSub, "memory:observations") end,
      :ok
    )

    observations = load_observations()

    {:ok,
     assign(socket,
       current_path: "/admin/memory/observations",
       observations: observations
     )}
  end

  @impl true
  def handle_info({:new_observation, observation}, socket) do
    updated = [observation | socket.assigns.observations] |> Enum.take(100)
    {:noreply, assign(socket, observations: updated)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_observations do
    safe_call(
      fn ->
        repo = Application.fetch_env!(:backplane_memory, :repo)
        alias BackplaneMemory.Observations.Observation

        repo.all(from(o in Observation, order_by: [desc: o.created_at], limit: 50))
      end,
      []
    )
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp truncate(nil, _), do: ""

  defp truncate(str, len) when is_binary(str) do
    if String.length(str) > len, do: String.slice(str, 0, len) <> "…", else: str
  end

  defp format_dt(nil), do: ""
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
        <h1 class="text-2xl font-bold">Observations</h1>
        <p class="text-sm text-on-surface-variant mt-1">
          Recent tool call observations (last 50, live-updating).
        </p>
      </div>

      <.dm_card variant="bordered">
        <div :if={@observations == []} class="text-on-surface-variant text-sm py-4">
          No observations recorded yet.
        </div>
        <div :if={@observations != []} class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-outline-variant">
                <th class="text-left py-2 font-medium">Session</th>
                <th class="text-left py-2 font-medium">Tool</th>
                <th class="text-left py-2 font-medium">Error?</th>
                <th class="text-left py-2 font-medium">Content</th>
                <th class="text-left py-2 font-medium">Created</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={obs <- @observations} class="border-b border-outline-variant/40">
                <td class="py-2 font-mono text-xs">{truncate(obs.session_id, 12)}</td>
                <td class="py-2">{obs.tool_name}</td>
                <td class="py-2">
                  <.dm_badge :if={obs.is_error} variant="error">error</.dm_badge>
                  <.dm_badge :if={!obs.is_error} variant="success">ok</.dm_badge>
                </td>
                <td class="py-2 text-xs text-on-surface-variant">{truncate(obs.content, 100)}</td>
                <td class="py-2 text-xs text-on-surface-variant">{format_dt(obs.created_at)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.dm_card>
    </div>
    """
  end
end
