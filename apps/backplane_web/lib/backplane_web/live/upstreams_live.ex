defmodule BackplaneWeb.UpstreamsLive do
  use BackplaneWeb, :live_view

  alias Backplane.Proxy.Pool
  alias Backplane.PubSubBroadcaster
  alias Backplane.Registry.ToolRegistry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to upstream topics for each known upstream
      upstreams = safe_call(fn -> Pool.list_upstreams() end, [])

      for upstream <- upstreams do
        PubSubBroadcaster.subscribe(PubSubBroadcaster.upstream_topic(upstream.prefix))
      end

      PubSubBroadcaster.subscribe(PubSubBroadcaster.config_reloaded_topic())
    end

    {:ok, assign(socket, current_path: "/admin/hub/upstreams", loading: true)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(selected: nil) |> reload_upstreams()}
  end

  @impl true
  def handle_info({event, _payload}, socket)
      when event in [:connected, :disconnected, :degraded, :tools_refreshed, :reloaded] do
    {:noreply, reload_upstreams(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select", %{"name" => name}, socket) do
    {:noreply, assign(socket, selected: name)}
  end

  defp reload_upstreams(socket) do
    upstreams = safe_call(fn -> Pool.list_upstreams() end, [])
    tools = safe_call(fn -> ToolRegistry.list_all() end, [])

    upstream_tools =
      Enum.group_by(tools, fn tool ->
        case tool.origin do
          {:upstream, name} -> name
          _ -> nil
        end
      end)

    assign(socket, loading: false, upstreams: upstreams, upstream_tools: upstream_tools)
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex gap-2 mb-6">
        <.dm_btn
          variant={if @current_path in ["/admin/hub", "/admin/hub/upstreams"], do: "primary", else: nil}
          phx-click={JS.navigate(~p"/admin/hub/upstreams")}
        >
          Upstreams
        </.dm_btn>
        <.dm_btn
          variant={if @current_path == "/admin/hub/skills", do: "primary", else: nil}
          phx-click={JS.navigate(~p"/admin/hub/skills")}
        >
          Skills
        </.dm_btn>
        <.dm_btn
          variant={if @current_path == "/admin/hub/tools", do: "primary", else: nil}
          phx-click={JS.navigate(~p"/admin/hub/tools")}
        >
          Tools
        </.dm_btn>
      </div>

      <h1 class="text-2xl font-bold mb-6">Upstream MCP Servers</h1>

      <div :if={@upstreams == []} class="text-on-surface-variant">
        No upstream MCP servers configured. Use the admin UI or API to add upstream servers.
      </div>

      <div class="space-y-4">
        <.dm_card
          :for={upstream <- @upstreams}
          variant="bordered"
          class={[
            "cursor-pointer transition-colors",
            @selected == upstream.name && "ring-2 ring-primary"
          ]}
          phx-click="select"
          phx-value-name={upstream.name}
        >
          <:title>
            <div class="flex items-center justify-between">
              <div>
                <span class="text-sm font-medium">{upstream.name}</span>
                <p class="text-xs text-on-surface-variant mt-1">
                  {upstream.prefix}:: | {upstream.transport}
                </p>
              </div>
              <.dm_badge variant={upstream_badge_color(upstream)}>
                {upstream_status(upstream) |> to_string() |> String.capitalize()}
              </.dm_badge>
            </div>
          </:title>

          <div :if={@selected == upstream.name} class="mt-2 border-t border-outline-variant pt-4">
            <h4 class="text-xs font-medium text-on-surface-variant mb-2">Registered Tools</h4>
            <div class="space-y-1">
              <div
                :for={tool <- Map.get(@upstream_tools, upstream.name, [])}
                class="text-xs text-on-surface font-mono"
              >
                {tool.name}
              </div>
              <div
                :if={Map.get(@upstream_tools, upstream.name, []) == []}
                class="text-xs text-on-surface-variant"
              >
                No tools registered
              </div>
            </div>
          </div>
        </.dm_card>
      </div>
    </div>
    """
  end

  defp upstream_status(%{status: :connected}), do: :connected
  defp upstream_status(%{status: :degraded}), do: :degraded
  defp upstream_status(%{connected: true}), do: :connected
  defp upstream_status(_), do: :disconnected

  defp upstream_badge_color(upstream) do
    case upstream_status(upstream) do
      :connected -> "success"
      :degraded -> "warning"
      :disconnected -> "error"
    end
  end
end
