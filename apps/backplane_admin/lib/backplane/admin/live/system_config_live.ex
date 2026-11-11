defmodule Backplane.Admin.SystemConfigLive do
  use Backplane.Admin, :live_view

  alias Backplane.Admin.Audit
  alias Backplane.Monitor.ApiAccounts
  alias Backplane.SecretHub.{Sync, SyncWorker}
  alias Backplane.Settings

  @setting "monitor.api_usage.enabled"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Settings.subscribe()

    {:ok,
     socket
     |> assign(
       current_path: "/system/config",
       fetching_enabled: ApiAccounts.fetching_enabled?()
     )
     |> assign_secrethub()}
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

  def handle_event("set-secrethub", %{"secrethub" => %{"enabled" => value}}, socket)
      when value in [true, false, "true", "false"] do
    update_setting(socket, Sync.enabled_key(), value in [true, "true"], "SecretHub sync updated.")
  end

  def handle_event("set-secrethub", _params, socket),
    do: {:noreply, socket |> clear_flash() |> put_flash(:error, "Invalid SecretHub sync setting.")}

  def handle_event("save-secrethub-socket", %{"secrethub" => %{"socket_path" => raw}}, socket)
      when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        update_setting(socket, Sync.socket_key(), nil, "SecretHub Agent socket reset to default.")

      "/" <> _ = path ->
        update_setting(socket, Sync.socket_key(), path, "SecretHub Agent socket updated.")

      _ ->
        {:noreply,
         socket
         |> clear_flash()
         |> put_flash(:error, "The SecretHub Agent socket must be an absolute path.")}
    end
  end

  def handle_event("secrethub-sync-now", _params, socket) do
    socket = clear_flash(socket)

    case SyncWorker.enqueue() do
      {:ok, _job} ->
        {:noreply, socket |> assign_secrethub() |> put_flash(:info, "SecretHub sync queued.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not queue a SecretHub sync. Please try again.")}
    end
  end

  @impl true
  def handle_info({:setting_changed, @setting, _value}, socket) do
    {:noreply, assign(socket, fetching_enabled: ApiAccounts.fetching_enabled?())}
  end

  def handle_info({:setting_changed, key, _value}, socket) do
    if key in [Sync.enabled_key(), Sync.socket_key()],
      do: {:noreply, assign_secrethub(socket)},
      else: {:noreply, socket}
  end

  defp update_setting(socket, key, value, message) do
    socket = clear_flash(socket)

    case Settings.set(key, value) do
      :ok ->
        socket = assign_secrethub(socket)

        case Audit.record("system_setting.update", "system_setting", key) do
          {:ok, _event} ->
            {:noreply, put_flash(socket, :info, message)}

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, "Setting updated, but the audit record could not be saved.")}
        end

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign_secrethub()
         |> put_flash(:error, "Could not update the SecretHub setting. Please try again.")}
    end
  end

  # Status reads the database, so only connected renders load it.
  defp assign_secrethub(socket) do
    assign(socket,
      secrethub_enabled: Sync.enabled?(),
      secrethub_socket: Settings.get(Sync.socket_key()) || "",
      secrethub_status: if(connected?(socket), do: Sync.status())
    )
  end

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

      <.dm_card id="secrethub-sync-config" variant="bordered">
        <:title>SecretHub sync</:title>
        <div class="space-y-4">
          <.form id="secrethub-sync-form" for={%{}} phx-change="set-secrethub" phx-submit="set-secrethub">
            <.dm_switch
              id="secrethub-sync-enabled"
              name="secrethub[enabled]"
              label="Publish API keys to SecretHub"
              checked={@secrethub_enabled}
              helper="Disabled by default. Changes are saved immediately."
            />
          </.form>

          <.form id="secrethub-socket-form" for={%{}} phx-submit="save-secrethub-socket">
            <.dm_input
              id="secrethub-socket-path"
              name="secrethub[socket_path]"
              label="SecretHub Agent socket"
              value={@secrethub_socket}
              placeholder="Default: $SECRET_HUB_AGENT_SOCKET_PATH or /var/run/secrethub/agent.sock"
            />
            <.dm_btn type="submit" native_submit variant="primary" size="sm">Save socket</.dm_btn>
          </.form>

          <div :if={@secrethub_status} id="secrethub-sync-status" class="space-y-2">
            <div class="flex flex-wrap gap-2">
              <.dm_badge variant={if @secrethub_enabled, do: "success", else: "warning"}>
                {if @secrethub_enabled, do: "Sync enabled", else: "Sync disabled"}
              </.dm_badge>
              <.dm_badge variant="info">{@secrethub_status.published} published</.dm_badge>
              <.dm_badge :if={@secrethub_status.failing > 0} variant="error">
                {@secrethub_status.failing} failing
              </.dm_badge>
            </div>
            <p :if={@secrethub_status.last_synced_at} class="text-on-surface-variant">
              Last published {Calendar.strftime(@secrethub_status.last_synced_at, "%Y-%m-%d %H:%M:%S UTC")}
            </p>
            <ul :if={@secrethub_status.errors != []} id="secrethub-sync-errors" class="list-disc pl-5">
              <li :for={error <- @secrethub_status.errors}>
                {error.credential_name}: {error.error}
              </li>
            </ul>
          </div>

          <.dm_btn
            id="secrethub-sync-now"
            phx-click="secrethub-sync-now"
            variant="secondary"
            size="sm"
            disabled={not @secrethub_enabled}
          >
            Sync now
          </.dm_btn>

          <p class="text-on-surface-variant">
            API key credentials (not OAuth or imported CLI sessions) are published to
            SecretHub at <code>backplane.&lt;kind&gt;.&lt;name&gt;</code> as <code>api_key</code>
            through the local SecretHub Agent. Saving credentials never depends on SecretHub:
            failures are retried and reconciled every five minutes. Disabling stops
            publication but does not remove published secrets.
          </p>
        </div>
      </.dm_card>
    </div>
    """
  end
end
