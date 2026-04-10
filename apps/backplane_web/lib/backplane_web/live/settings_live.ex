defmodule BackplaneWeb.SettingsLive do
  use BackplaneWeb, :live_view

  alias Backplane.Settings
  alias Backplane.Settings.Credentials

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/admin/settings", active_tab: "settings")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = params["tab"] || "settings"

    socket =
      socket
      |> assign(active_tab: tab)
      |> load_data(tab)

    {:noreply, socket}
  end

  defp load_data(socket, "settings") do
    definitions = Settings.list_definitions()

    groups =
      definitions
      |> Enum.group_by(fn d ->
        d.key |> String.split(".") |> List.first()
      end)
      |> Enum.sort_by(fn {group, _} -> group end)

    assign(socket,
      settings_groups: groups,
      editing_key: nil,
      edit_value: nil
    )
  end

  defp load_data(socket, "credentials") do
    credentials = Credentials.list()

    assign(socket,
      credentials: credentials,
      show_add_form: false,
      cred_name: "",
      cred_kind: "llm",
      cred_secret: ""
    )
  end

  defp load_data(socket, _), do: socket

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/settings?tab=#{tab}")}
  end

  def handle_event("edit_setting", %{"key" => key}, socket) do
    current = Settings.get(key)
    {:noreply, assign(socket, editing_key: key, edit_value: to_string(current || ""))}
  end

  def handle_event("cancel_edit", _, socket) do
    {:noreply, assign(socket, editing_key: nil, edit_value: nil)}
  end

  def handle_event("save_setting", %{"key" => key, "value" => value}, socket) do
    parsed = parse_setting_value(key, value)

    case Settings.set(key, parsed) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Setting '#{key}' updated")
         |> assign(editing_key: nil, edit_value: nil)
         |> load_data("settings")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update setting")}
    end
  end

  def handle_event("toggle_add_form", _, socket) do
    {:noreply, assign(socket, show_add_form: !socket.assigns.show_add_form)}
  end

  def handle_event("update_cred_field", params, socket) do
    assigns =
      Enum.reduce(params, [], fn
        {"name", v}, acc -> [{:cred_name, v} | acc]
        {"kind", v}, acc -> [{:cred_kind, v} | acc]
        {"secret", v}, acc -> [{:cred_secret, v} | acc]
        _, acc -> acc
      end)

    {:noreply, assign(socket, assigns)}
  end

  def handle_event("add_credential", _, socket) do
    %{cred_name: name, cred_kind: kind, cred_secret: secret} = socket.assigns

    if name != "" and secret != "" do
      case Credentials.store(name, secret, kind) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Credential '#{name}' stored")
           |> assign(show_add_form: false, cred_name: "", cred_kind: "llm", cred_secret: "")
           |> load_data("credentials")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to store credential")}
      end
    else
      {:noreply, put_flash(socket, :error, "Name and secret are required")}
    end
  end

  def handle_event("delete_credential", %{"name" => name}, socket) do
    case Credentials.delete(name) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Credential '#{name}' deleted")
         |> load_data("credentials")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete credential")}
    end
  end

  defp parse_setting_value(key, value) do
    definitions = Settings.list_definitions()
    definition = Enum.find(definitions, fn d -> d.key == key end)

    case definition && definition.value_type do
      "boolean" -> value in ["true", "1", "yes"]
      "integer" -> String.to_integer(value)
      _ -> value
    end
  rescue
    _ -> value
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-2xl font-bold mb-6">Settings</h1>

      <div class="flex gap-2 mb-6">
        <.dm_btn
          variant={if @active_tab == "settings", do: "primary", else: nil}
          phx-click="switch_tab"
          phx-value-tab="settings"
        >
          Settings
        </.dm_btn>
        <.dm_btn
          variant={if @active_tab == "credentials", do: "primary", else: nil}
          phx-click="switch_tab"
          phx-value-tab="credentials"
        >
          Credentials
        </.dm_btn>
      </div>

      <div :if={@active_tab == "settings"}>
        <div :for={{group, settings} <- @settings_groups} class="mb-8">
          <h2 class="text-lg font-semibold mb-3 capitalize">{group}</h2>
          <.dm_card variant="bordered">
            <div class="divide-y divide-outline-variant">
              <div :for={setting <- settings} class="py-3 px-4 flex items-center justify-between">
                <div class="flex-1">
                  <div class="font-mono text-sm">{setting.key}</div>
                  <div class="text-xs text-on-surface-variant">{setting.description}</div>
                </div>
                <div :if={@editing_key == setting.key} class="flex items-center gap-2">
                  <form phx-submit="save_setting" class="flex items-center gap-2">
                    <input type="hidden" name="key" value={setting.key} />
                    <input
                      type="text"
                      name="value"
                      value={@edit_value}
                      class="px-2 py-1 text-sm border rounded bg-surface-container text-on-surface"
                      autofocus
                    />
                    <.dm_btn type="submit" variant="primary" size="sm">Save</.dm_btn>
                    <.dm_btn type="button" size="sm" phx-click="cancel_edit">
                      Cancel
                    </.dm_btn>
                  </form>
                </div>
                <div :if={@editing_key != setting.key} class="flex items-center gap-2">
                  <span class="text-sm font-mono">
                    {inspect(setting.value)}
                  </span>
                  <.dm_btn
                    size="sm"
                    phx-click="edit_setting"
                    phx-value-key={setting.key}
                  >
                    Edit
                  </.dm_btn>
                </div>
              </div>
            </div>
          </.dm_card>
        </div>
      </div>

      <div :if={@active_tab == "credentials"}>
        <div class="mb-4">
          <.dm_btn variant="primary" phx-click="toggle_add_form">
            {if @show_add_form, do: "Cancel", else: "Add Credential"}
          </.dm_btn>
        </div>

        <div :if={@show_add_form} class="mb-6">
          <.dm_card variant="bordered">
            <:title>New Credential</:title>
            <form phx-submit="add_credential" class="space-y-4">
              <div>
                <label class="block text-sm font-medium mb-1">Name</label>
                <input
                  type="text"
                  name="name"
                  value={@cred_name}
                  phx-change="update_cred_field"
                  placeholder="e.g. anthropic-prod-key"
                  class="w-full px-3 py-2 border rounded bg-surface-container text-on-surface"
                />
              </div>
              <div>
                <label class="block text-sm font-medium mb-1">Kind</label>
                <select
                  name="kind"
                  phx-change="update_cred_field"
                  class="w-full px-3 py-2 border rounded bg-surface-container text-on-surface"
                >
                  <option value="llm" selected={@cred_kind == "llm"}>LLM Provider</option>
                  <option value="upstream" selected={@cred_kind == "upstream"}>Upstream MCP</option>
                  <option value="service" selected={@cred_kind == "service"}>Service</option>
                  <option value="admin" selected={@cred_kind == "admin"}>Admin</option>
                  <option value="custom" selected={@cred_kind == "custom"}>Custom</option>
                </select>
              </div>
              <div>
                <label class="block text-sm font-medium mb-1">Secret</label>
                <input
                  type="password"
                  name="secret"
                  value={@cred_secret}
                  phx-change="update_cred_field"
                  placeholder="API key or token"
                  class="w-full px-3 py-2 border rounded bg-surface-container text-on-surface"
                />
              </div>
              <.dm_btn type="submit" variant="primary">Store Credential</.dm_btn>
            </form>
          </.dm_card>
        </div>

        <.dm_card variant="bordered">
          <:title>Stored Credentials</:title>
          <div :if={@credentials == []} class="py-8 text-center text-on-surface-variant">
            No credentials stored yet.
          </div>
          <div :if={@credentials != []} class="divide-y divide-outline-variant">
            <div :for={cred <- @credentials} class="py-3 px-4 flex items-center justify-between">
              <div>
                <div class="font-mono text-sm">{cred.name}</div>
                <div class="text-xs text-on-surface-variant">
                  <.dm_badge variant="neutral">{cred.kind}</.dm_badge>
                  <span class="ml-2">Updated: {Calendar.strftime(cred.updated_at, "%Y-%m-%d %H:%M")}</span>
                </div>
              </div>
              <div class="flex items-center gap-3">
                <span class="text-sm text-on-surface-variant">••••••••</span>
                <.dm_btn
                  variant="error"
                  size="sm"
                  phx-click="delete_credential"
                  phx-value-name={cred.name}
                  data-confirm={"Delete credential '#{cred.name}'?"}
                >
                  Delete
                </.dm_btn>
              </div>
            </div>
          </div>
        </.dm_card>
      </div>
    </div>
    """
  end
end
