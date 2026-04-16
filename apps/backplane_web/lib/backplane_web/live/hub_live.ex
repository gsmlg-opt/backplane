defmodule BackplaneWeb.HubLive do
  use BackplaneWeb, :live_view

  alias Backplane.Proxy.Pool
  alias Backplane.PubSubBroadcaster
  alias Backplane.Registry.ToolRegistry

  @managed_services [Backplane.Services.Day]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSubBroadcaster.subscribe(PubSubBroadcaster.config_reloaded_topic())

      for upstream <- safe_call(fn -> Pool.list_upstreams() end, []) do
        PubSubBroadcaster.subscribe(PubSubBroadcaster.upstream_topic(upstream.prefix))
      end
    end

    {:ok, assign(socket, current_path: "/admin/hub", loading: true)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, reload_services(socket)}
  end

  @impl true
  def handle_info({event, _}, socket)
      when event in [:connected, :disconnected, :degraded, :tools_refreshed, :reloaded] do
    {:noreply, reload_services(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp reload_services(socket) do
    tools = safe_call(fn -> ToolRegistry.list_all() end, [])
    upstreams = safe_call(fn -> Pool.list_upstreams() end, [])

    managed =
      Enum.map(@managed_services, fn mod ->
        prefix = mod.prefix()
        tool_count = Enum.count(tools, fn t -> t.origin == {:managed, prefix} end)

        %{
          name: prefix,
          prefix: prefix,
          type: :managed,
          enabled: mod.enabled?(),
          status: if(mod.enabled?(), do: :connected, else: :disabled),
          tool_count: tool_count
        }
      end)

    upstream_entries =
      Enum.map(upstreams, fn u ->
        %{
          name: u.name,
          prefix: u.prefix,
          type: :upstream,
          enabled: true,
          status: u.status || :disconnected,
          tool_count: u.tool_count || 0,
          transport: u.transport
        }
      end)

    assign(socket,
      loading: false,
      services: managed ++ upstream_entries,
      managed_count: length(managed),
      upstream_count: length(upstream_entries)
    )
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
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">MCP Hub</h1>
        <div class="flex gap-2">
          <.dm_btn variant="primary" size="sm" phx-click={JS.navigate(~p"/admin/hub/managed")}>
            Managed Services
          </.dm_btn>
          <.dm_btn variant="primary" size="sm" phx-click={JS.navigate(~p"/admin/hub/upstreams")}>
            Upstream Servers
          </.dm_btn>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 mb-8">
        <.dm_stat title="Managed Services" value={to_string(@managed_count)} />
        <.dm_stat title="Upstream Servers" value={to_string(@upstream_count)} />
        <.dm_stat title="Total Services" value={to_string(length(@services))} />
      </div>

      <h2 class="text-lg font-semibold mb-4">All Services</h2>

      <div :if={@services == []} class="text-on-surface-variant">
        No MCP services configured. Add managed services or upstream servers to get started.
      </div>

      <div class="space-y-3">
        <.dm_card :for={service <- @services} variant="bordered">
          <:title>
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <span class="font-medium">{service.name}</span>
                <span class="text-xs text-on-surface-variant font-mono">{service.prefix}::</span>
                <.dm_badge variant={if service.type == :managed, do: "info", else: "primary"}>
                  {to_string(service.type)}
                </.dm_badge>
                <span :if={service[:transport]} class="text-xs text-on-surface-variant">
                  {service.transport}
                </span>
              </div>
              <div class="flex items-center gap-3">
                <span class="text-sm text-on-surface-variant">{service.tool_count} tools</span>
                <.dm_badge variant={status_color(service.status)}>
                  {service.status |> to_string() |> String.capitalize()}
                </.dm_badge>
              </div>
            </div>
          </:title>
        </.dm_card>
      </div>
    </div>
    """
  end

  defp status_color(:connected), do: "success"
  defp status_color(:disabled), do: "ghost"
  defp status_color(:degraded), do: "warning"
  defp status_color(_), do: "error"
end
