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
      module: Backplane.Services.Web,
      name: "Web",
      description: "Fetch HTTP(S) pages, search the web, run live LLM web search, and search X"
    },
    %{
      module: Backplane.Services.Math,
      name: "Math",
      description: "Evaluate math expressions with the native math engine"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/admin/mcp/managed", loading: true)}
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
    safe_call(fn -> refresh_managed_registry() end, :ok)
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
          tools: Enum.filter(tools, fn t -> t.origin == {:managed, prefix} end),
          settings_path: "/admin/mcp/managed/#{prefix}"
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

  defp set_enabled(Backplane.Services.Web = mod, enabled) do
    Settings.set("services.web.enabled", enabled)
    sync_registry(mod, enabled)
  end

  defp set_enabled(Backplane.Services.Math, enabled), do: MathConfig.save(%{enabled: enabled})

  defp refresh_managed_registry do
    Enum.each(@managed_services, fn svc ->
      mod = svc.module
      sync_registry(mod, mod.enabled?())
    end)
  end

  defp sync_registry(mod, true) do
    ToolRegistry.deregister_managed(mod.prefix())
    ToolRegistry.register_managed(mod.prefix(), mod.tools())
  end

  defp sync_registry(mod, false) do
    ToolRegistry.deregister_managed(mod.prefix())
  end

  defp tool_short_name(tool_name) do
    case String.split(tool_name, "::", parts: 2) do
      [_prefix, short] -> short
      _ -> tool_name
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center gap-3 mb-6">
        <h1 class="text-2xl font-bold">Managed Services</h1>
      </div>

      <div class="overflow-x-auto">
        <table class="min-w-full text-sm">
          <thead class="bg-surface-container-high text-on-surface">
            <tr>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Service</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Prefix</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Description</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Status</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Tools</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Actions</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-outline-variant">
            <tr :for={service <- @services} class="hover:bg-surface-container-high">
              <td class="px-3 py-1.5 align-middle font-medium">{service.name}</td>
              <td class="px-3 py-1.5 align-middle">
                <span class="font-mono text-on-surface-variant">{service.prefix}::</span>
              </td>
              <td class="px-3 py-1.5 align-middle text-on-surface-variant">{service.description}</td>
              <td class="px-3 py-1.5 align-middle">
                <.dm_badge variant={if service.enabled, do: "success", else: "ghost"}>
                  {if service.enabled, do: "Enabled", else: "Disabled"}
                </.dm_badge>
              </td>
              <td class="px-3 py-1.5 align-middle">
                <span :if={!service.enabled or service.tools == []} class="text-on-surface-variant">
                  {service.tool_count} tools
                </span>
                <div :if={service.enabled and service.tools != []} class="flex flex-wrap gap-1">
                  <.link
                    :for={tool <- service.tools}
                    navigate={"/admin/mcp/managed/#{service.prefix}/tool/#{tool_short_name(tool.name)}"}
                  >
                    <.dm_badge variant="ghost" class="cursor-pointer hover:bg-surface-container-high transition-colors">
                      {tool.name}
                    </.dm_badge>
                  </.link>
                </div>
              </td>
              <td class="px-3 py-1.5 align-middle">
                <div class="flex items-center gap-1">
                  <.dm_tooltip content="Settings" position="bottom">
                    <.link navigate={service.settings_path}>
                      <.dm_btn size="xs" variant="outline" shape="circle">
                        <.dm_mdi name="cog" class="w-4 h-4" />
                      </.dm_btn>
                    </.link>
                  </.dm_tooltip>
                  <.dm_tooltip content={if service.enabled, do: "Disable", else: "Enable"} position="bottom">
                    <.dm_btn
                      size="xs"
                      shape="circle"
                      variant={if service.enabled, do: "warning", else: "primary"}
                      phx-click="toggle"
                      phx-value-prefix={service.prefix}
                    >
                      <.dm_mdi
                        name={if service.enabled, do: "pause", else: "play"}
                        class="w-4 h-4"
                      />
                    </.dm_btn>
                  </.dm_tooltip>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
