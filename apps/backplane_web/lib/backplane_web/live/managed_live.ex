defmodule BackplaneWeb.ManagedLive do
  use BackplaneWeb, :live_view

  alias Backplane.Math.Config, as: MathConfig
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
      description: "Fetch HTTP(S) pages and convert them to Markdown"
    },
    %{
      module: Backplane.Services.Math,
      name: "Math",
      description: "Evaluate math expressions with the native math engine"
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
  def handle_event("toggle", %{"prefix" => prefix}, socket) do
    service = Enum.find(@managed_services, &(&1.module.prefix() == prefix))

    if service do
      mod = service.module
      current = mod.enabled?()
      set_enabled(mod, !current)
    end

    {:noreply, socket |> put_flash(:info, "Service updated") |> load_services()}
  end

  defp load_services(socket) do
    tools = safe_call(fn -> ToolRegistry.list_all() end, [])

    services =
      Enum.map(@managed_services, fn svc ->
        mod = svc.module
        prefix = mod.prefix()
        enabled = mod.enabled?()
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

  defp set_enabled(Backplane.Services.Day = mod, enabled) do
    Settings.set("services.day.enabled", enabled)
    sync_registry(mod, enabled)
  end

  defp set_enabled(Backplane.Services.WebFetch = mod, enabled) do
    Settings.set("services.web.enabled", enabled)
    sync_registry(mod, enabled)
  end

  defp set_enabled(Backplane.Services.Math, enabled), do: MathConfig.save(%{enabled: enabled})

  defp sync_registry(mod, true), do: ToolRegistry.register_managed(mod.prefix(), mod.tools())
  defp sync_registry(mod, false), do: ToolRegistry.deregister_managed(mod.prefix())

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
            <div class="flex w-full items-center justify-between gap-4">
              <div class="flex items-center gap-4">
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
                phx-value-prefix={service.prefix}
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
