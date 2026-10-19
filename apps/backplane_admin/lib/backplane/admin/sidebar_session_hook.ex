defmodule Backplane.Admin.SidebarSessionHook do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Backplane.Admin.SidebarSession
  alias Phoenix.SessionProcess.SessionId

  def on_mount(:default, _params, session, socket) do
    # Isolated LiveViews have no browser pipeline; give each its own identity.
    session_id = session["session_id"] || SessionId.generate_unique_session_id()
    collapsed = persisted_state!(SidebarSession.read(session_id))

    socket =
      socket
      |> assign(admin_session_id: session_id, sidebar_collapsed: collapsed)
      |> attach_hook(:sidebar_session, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  defp handle_event("sidebar_collapsed", %{"collapsed" => collapsed}, socket)
       when is_boolean(collapsed) do
    persisted = persisted_state!(SidebarSession.put(socket.assigns.admin_session_id, collapsed))
    {:halt, assign(socket, :sidebar_collapsed, persisted)}
  end

  defp handle_event("sidebar_collapsed", _params, socket), do: {:halt, socket}

  defp handle_event("sidebar_state", _params, socket) do
    collapsed = persisted_state!(SidebarSession.read(socket.assigns.admin_session_id))
    {:halt, %{collapsed: collapsed}, assign(socket, :sidebar_collapsed, collapsed)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp persisted_state!({:ok, collapsed}), do: collapsed

  defp persisted_state!({:error, reason}) do
    raise "cannot persist admin sidebar session state: #{inspect(reason)}"
  end
end
