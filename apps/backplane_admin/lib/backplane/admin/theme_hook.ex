defmodule Backplane.Admin.ThemeHook do
  @moduledoc false

  import Phoenix.LiveView, only: [attach_hook: 4]

  def on_mount(:default, _params, _session, socket) do
    socket =
      attach_hook(socket, :theme_switcher, :handle_event, fn
        "theme_changed", _params, socket -> {:halt, socket}
        _event, _params, socket -> {:cont, socket}
      end)

    {:cont, socket}
  end
end
