defmodule Backplane.Admin.SystemConfigLive do
  use Backplane.Admin, :live_view

  alias Backplane.Admin.Audit
  alias Backplane.Monitor.ApiAccounts
  alias Backplane.Settings

  @setting "monitor.api_usage.enabled"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Settings.subscribe()

    {:ok,
     assign(socket,
       current_path: "/system/config",
       fetching_enabled: ApiAccounts.fetching_enabled?()
     )}
  end

  @impl true
  def handle_event("set-fetching", %{"config" => %{"enabled" => value}}, socket)
      when value in [true, false, "true", "false"] do
    enabled = value in [true, "true"]

    case ApiAccounts.set_fetching_enabled(enabled) do
      :ok ->
        socket = assign(socket, fetching_enabled: ApiAccounts.fetching_enabled?())

        case Audit.record("system_setting.update", "system_setting", @setting) do
          {:ok, _event} ->
            {:noreply,
             socket
             |> clear_flash()
             |> put_flash(:info, "API information fetching updated.")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> clear_flash()
             |> put_flash(:error, "Setting updated, but the audit record could not be saved.")}
        end

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(fetching_enabled: ApiAccounts.fetching_enabled?())
         |> clear_flash()
         |> put_flash(:error, "Could not update API information fetching. Please try again.")}
    end
  end

  def handle_event("set-fetching", _params, socket) do
    {:noreply,
     socket
     |> clear_flash()
     |> put_flash(:error, "Invalid API fetching setting.")}
  end

  @impl true
  def handle_info({:setting_changed, @setting, _value}, socket) do
    {:noreply, assign(socket, fetching_enabled: ApiAccounts.fetching_enabled?())}
  end

  def handle_info({:setting_changed, _key, _value}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="system-config" class="space-y-6">
      <div>
        <h1 class="text-2xl font-bold">System Config</h1>
        <p class="mt-1 text-on-surface-variant">Global operational settings</p>
      </div>

      <.dm_card id="api-fetching-config" variant="bordered">
        <:title>API Usage fetching</:title>
        <div class="space-y-4">
          <.form
            id="api-fetching-config-form"
            for={%{}}
            phx-change="set-fetching"
            phx-submit="set-fetching"
          >
            <.dm_switch
              id="api-information-fetching"
              name="config[enabled]"
              label="API information fetching"
              checked={@fetching_enabled}
              helper="Enabled by default. Changes are saved immediately."
            />
          </.form>

          <.dm_badge id="api-fetching-status" variant={if @fetching_enabled, do: "success", else: "warning"}>
            {if @fetching_enabled, do: "Fetching enabled", else: "Fetching disabled"}
          </.dm_badge>

          <p class="text-on-surface-variant">
            This global switch controls automatic and manual API information fetching.
            Disabling cancels in-flight requests and preserves cached successful snapshots.
            Re-enabling refreshes active accounts.
          </p>
          <p class="text-on-surface-variant">
            Subscription Plan Usage is independent and unaffected. The per-account active
            flags still apply; enabling this switch does not resume paused accounts.
          </p>

          <div class="flex flex-wrap gap-4">
            <.dm_link navigate="/system/monitor/api-usage">Configure API accounts</.dm_link>
            <.dm_link navigate="/dashboard/usage/api">View API Usage dashboard</.dm_link>
          </div>
        </div>
      </.dm_card>
    </div>
    """
  end
end
