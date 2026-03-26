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

    {:ok, assign(socket, current_path: "/admin/upstreams", loading: true)}
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
      <h1 class="text-2xl font-bold text-white mb-6">Upstream MCP Servers</h1>

      <div :if={@upstreams == []} class="text-gray-400">
        No upstream MCP servers configured. Add [[upstream]] sections to your backplane.toml.
      </div>

      <div class="space-y-4">
        <div
          :for={upstream <- @upstreams}
          class={[
            "bg-gray-900 border rounded-lg p-4 cursor-pointer transition-colors",
            if(@selected == upstream.name,
              do: "border-emerald-600",
              else: "border-gray-800 hover:border-gray-700"
            )
          ]}
          phx-click="select"
          phx-value-name={upstream.name}
        >
          <div class="flex items-center justify-between">
            <div>
              <h3 class="text-sm font-medium text-white">{upstream.name}</h3>
              <p class="text-xs text-gray-400 mt-1">
                {upstream.prefix}:: | {upstream.transport}
              </p>
            </div>
            <.status_badge status={upstream_status(upstream)} />
          </div>

          <div :if={@selected == upstream.name} class="mt-4 border-t border-gray-800 pt-4">
            <h4 class="text-xs font-medium text-gray-400 mb-2">Registered Tools</h4>
            <div class="space-y-1">
              <div
                :for={tool <- Map.get(@upstream_tools, upstream.name, [])}
                class="text-xs text-gray-300 font-mono"
              >
                {tool.name}
              </div>
              <div
                :if={Map.get(@upstream_tools, upstream.name, []) == []}
                class="text-xs text-gray-500"
              >
                No tools registered
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp upstream_status(%{status: :connected}), do: :connected
  defp upstream_status(%{status: :degraded}), do: :degraded
  defp upstream_status(%{connected: true}), do: :connected
  defp upstream_status(_), do: :disconnected
end
