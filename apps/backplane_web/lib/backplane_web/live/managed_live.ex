defmodule BackplaneWeb.ManagedLive do
  use BackplaneWeb, :live_view

  alias Backplane.Settings
  alias Backplane.Registry.ToolRegistry

  @managed_services [
    %{
      module: Backplane.Services.Day,
      name: "Day",
      description: "Date/time utilities",
      setting_key: "services.day.enabled"
    },
    %{
      module: Backplane.Services.WebFetch,
      name: "Web Fetch",
      description: "Fetch HTTP(S) pages and convert them to Markdown",
      setting_key: "services.web.enabled"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/admin/hub/managed", loading: true)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_services(socket)}
  end

  @impl true
  def handle_event("toggle", %{"key" => key}, socket) do
    current = Settings.get(key) == true
    Settings.set(key, !current)

    service = Enum.find(@managed_services, &(&1.setting_key == key))

    if service do
      mod = service.module

      if !current do
        # Was false, now true -- register
        ToolRegistry.register_managed(mod.prefix(), mod.tools())
      else
        # Was true, now false -- deregister
        ToolRegistry.deregister_managed(mod.prefix())
      end
    end

    {:noreply, socket |> put_flash(:info, "Service updated") |> load_services()}
  end

  defp load_services(socket) do
    tools = safe_call(fn -> ToolRegistry.list_all() end, [])

    services =
      Enum.map(@managed_services, fn svc ->
        mod = svc.module
        prefix = mod.prefix()
        enabled = Settings.get(svc.setting_key) == true
        tool_count = Enum.count(tools, fn t -> t.origin == {:managed, prefix} end)

        Map.merge(svc, %{
          prefix: prefix,
          enabled: enabled,
          tool_count: tool_count,
          tools: Enum.filter(tools, fn t -> t.origin == {:managed, prefix} end)
        })
      end)

    assign(socket, loading: false, services: services)
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
      <div class="flex items-center gap-3 mb-6">
        <.dm_btn variant="link" size="sm" phx-click={JS.navigate(~p"/admin/hub")}>
          &larr; Hub
        </.dm_btn>
        <h1 class="text-2xl font-bold">Managed Services</h1>
      </div>

      <div class="space-y-4">
        <.dm_card :for={service <- @services} variant="bordered">
          <:title>
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <span class="font-medium">{service.name}</span>
                <span class="text-xs text-on-surface-variant font-mono">{service.prefix}::</span>
                <.dm_badge variant={if service.enabled, do: "success", else: "ghost"}>
                  {if service.enabled, do: "Enabled", else: "Disabled"}
                </.dm_badge>
                <span class="text-sm text-on-surface-variant">{service.tool_count} tools</span>
              </div>
              <.dm_btn
                size="sm"
                variant={if service.enabled, do: "warning", else: "primary"}
                phx-click="toggle"
                phx-value-key={service.setting_key}
              >
                {if service.enabled, do: "Disable", else: "Enable"}
              </.dm_btn>
            </div>
          </:title>
          <p class="text-sm text-on-surface-variant mb-2">{service.description}</p>
          <div
            :if={service.enabled and service.tools != []}
            class="border-t border-outline-variant pt-2 mt-2"
          >
            <h4 class="text-xs font-medium text-on-surface-variant mb-1">Tools</h4>
            <div class="flex flex-wrap gap-2">
              <.dm_badge :for={tool <- service.tools} variant="ghost">
                {tool.name}
              </.dm_badge>
            </div>
          </div>
        </.dm_card>
      </div>
    </div>
    """
  end
end
