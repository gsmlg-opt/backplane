defmodule Backplane.Admin.MemoryOperatorHook do
  @moduledoc "Keeps operator selection in navigation and refreshes bounded Memory reads."

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  @selection ~w(memory_space_id host client scope namespace project repository)
  @refresh_views [
    Backplane.Admin.MemoryMemoriesLive,
    Backplane.Admin.MemorySessionsLive,
    Backplane.Admin.MemoryLessonsLive,
    Backplane.Admin.MemoryCrystalsLive,
    Backplane.Admin.MemoryProfileLive,
    Backplane.Admin.MemoryGraphLive
  ]

  def on_mount(:default, _params, _session, socket) do
    timer = if connected?(socket) and socket.view in @refresh_views, do: schedule()

    {:cont,
     socket
     |> assign(
       memory_navigation: %{},
       memory_route_params: %{},
       memory_route_uri: nil,
       memory_refresh_error: nil,
       memory_refresh_timer: timer
     )
     |> attach_hook(:memory_selection, :handle_params, &remember_route/3)
     |> attach_hook(:memory_refresh, :handle_info, &refresh/2)}
  end

  defp remember_route(params, uri, socket) do
    {:cont,
     assign(socket,
       memory_route_params: params,
       memory_route_uri: uri,
       memory_navigation: Map.take(params, @selection)
     )}
  end

  defp refresh(:refresh_memory_operator, socket) do
    if socket.view in @refresh_views do
      if socket.assigns.memory_refresh_timer,
        do: Process.cancel_timer(socket.assigns.memory_refresh_timer)

      socket = assign(socket, :memory_refresh_timer, schedule())
      {:halt, refresh_view(socket)}
    else
      {:halt, socket}
    end
  end

  defp refresh(_message, socket), do: {:cont, socket}

  defp refresh_view(%{assigns: %{memory_route_uri: nil}} = socket), do: socket

  defp refresh_view(socket) do
    {:noreply, refreshed} =
      socket.view.handle_params(
        socket.assigns.memory_route_params,
        socket.assigns.memory_route_uri,
        socket
      )

    assign(refreshed, :memory_refresh_error, nil)
  rescue
    _ ->
      assign(
        socket,
        :memory_refresh_error,
        "The latest Memory query failed. Last displayed data may be stale; refresh will retry."
      )
  end

  defp schedule, do: Process.send_after(self(), :refresh_memory_operator, 2_000)
end
