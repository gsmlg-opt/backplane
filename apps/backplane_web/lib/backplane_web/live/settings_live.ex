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

  # --- Data Loading ---

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
    credentials =
      Credentials.list()
      |> Enum.map(fn cred ->
        Map.put(cred, :hint, Credentials.fetch_hint(cred.name))
      end)

    assign(socket,
      credentials: credentials,
      cred_form_mode: nil,
      cred_editing_name: nil,
      cred_name: "",
      cred_kind: "llm",
      cred_secret: ""
    )
  end

  defp load_data(socket, _), do: socket

  # --- Settings Events ---

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

  # --- Credentials Events ---

  def handle_event("show_add_form", _, socket) do
    {:noreply,
     assign(socket,
       cred_form_mode: :add,
       cred_editing_name: nil,
       cred_name: "",
       cred_kind: "llm",
       cred_secret: ""
     )}
  end

  def handle_event("show_edit_form", %{"name" => name}, socket) do
    cred = Enum.find(socket.assigns.credentials, &(&1.name == name))

    {:noreply,
     assign(socket,
       cred_form_mode: :edit,
       cred_editing_name: name,
       cred_name: name,
       cred_kind: (cred && cred.kind) || "llm",
       cred_secret: ""
     )}
  end

  def handle_event("show_rotate_form", %{"name" => name}, socket) do
    {:noreply,
     assign(socket,
       cred_form_mode: :rotate,
       cred_editing_name: name,
       cred_name: name,
       cred_kind: "",
       cred_secret: ""
     )}
  end

  def handle_event("cancel_cred_form", _, socket) do
    {:noreply, assign(socket, cred_form_mode: nil, cred_editing_name: nil)}
  end

  def handle_event("save_credential", params, socket) do
    case socket.assigns.cred_form_mode do
      :add -> handle_add_credential(params, socket)
      :edit -> handle_edit_credential(params, socket)
      :rotate -> handle_rotate_credential(params, socket)
      _ -> {:noreply, socket}
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

  # --- Credential Form Handlers ---

  defp handle_add_credential(params, socket) do
    name = params["name"] || ""
    kind = params["kind"] || "llm"
    secret = params["secret"] || ""

    if name == "" or secret == "" do
      {:noreply, put_flash(socket, :error, "Name and secret are required")}
    else
      case Credentials.store(name, secret, kind) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Credential '#{name}' created")
           |> assign(cred_form_mode: nil)
           |> load_data("credentials")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to store credential")}
      end
    end
  end

  defp handle_edit_credential(params, socket) do
    name = socket.assigns.cred_editing_name
    kind = params["kind"] || "llm"
    secret = params["secret"] || ""

    # Update kind
    case Credentials.update(name, %{kind: kind}) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end

    # Rotate secret if provided
    if secret != "" do
      case Credentials.rotate(name, secret) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Credential '#{name}' updated")
           |> assign(cred_form_mode: nil)
           |> load_data("credentials")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update credential")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:info, "Credential '#{name}' updated")
       |> assign(cred_form_mode: nil)
       |> load_data("credentials")}
    end
  end

  defp handle_rotate_credential(params, socket) do
    name = socket.assigns.cred_editing_name
    secret = params["secret"] || ""

    if secret == "" do
      {:noreply, put_flash(socket, :error, "New secret is required")}
    else
      case Credentials.rotate(name, secret) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Credential '#{name}' rotated")
           |> assign(cred_form_mode: nil)
           |> load_data("credentials")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to rotate credential")}
      end
    end
  end

  # --- Helpers ---

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

  # --- Render ---

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

      <%= if @active_tab == "settings" do %>
        <.render_settings_tab {assigns} />
      <% else %>
        <.render_credentials_tab {assigns} />
      <% end %>
    </div>
    """
  end

  defp render_settings_tab(assigns) do
    ~H"""
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
                <.dm_btn type="button" size="sm" phx-click="cancel_edit">Cancel</.dm_btn>
              </form>
            </div>
            <div :if={@editing_key != setting.key} class="flex items-center gap-2">
              <span class="text-sm font-mono">{inspect(setting.value)}</span>
              <.dm_btn size="sm" phx-click="edit_setting" phx-value-key={setting.key}>
                Edit
              </.dm_btn>
            </div>
          </div>
        </div>
      </.dm_card>
    </div>
    """
  end

  defp render_credentials_tab(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-lg font-semibold">Credential Store</h2>
        <.dm_btn
          :if={@cred_form_mode == nil}
          variant="primary"
          phx-click="show_add_form"
        >
          Add Credential
        </.dm_btn>
      </div>

      <.render_cred_form :if={@cred_form_mode != nil} {assigns} />

      <.dm_card variant="bordered">
        <div :if={@credentials == []} class="py-8 text-center text-on-surface-variant">
          No credentials stored yet. Click "Add Credential" to create one.
        </div>
        <div :if={@credentials != []} class="divide-y divide-outline-variant">
          <div :for={cred <- @credentials} class="py-3 px-4">
            <div class="flex items-center justify-between">
              <div class="flex-1">
                <div class="flex items-center gap-2">
                  <span class="font-mono text-sm font-medium">{cred.name}</span>
                  <.dm_badge variant="neutral">{cred.kind}</.dm_badge>
                </div>
                <div class="text-xs text-on-surface-variant mt-1">
                  <span class="font-mono">{cred.hint}</span>
                  <span class="mx-2">&middot;</span>
                  <span>Updated {Calendar.strftime(cred.updated_at, "%Y-%m-%d %H:%M")}</span>
                </div>
              </div>
              <div class="flex items-center gap-2">
                <.dm_btn
                  size="sm"
                  phx-click="show_edit_form"
                  phx-value-name={cred.name}
                >
                  Edit
                </.dm_btn>
                <.dm_btn
                  size="sm"
                  variant="warning"
                  phx-click="show_rotate_form"
                  phx-value-name={cred.name}
                >
                  Rotate
                </.dm_btn>
                <.dm_btn
                  size="sm"
                  variant="error"
                  phx-click="delete_credential"
                  phx-value-name={cred.name}
                  data-confirm={"Delete credential '#{cred.name}'? This cannot be undone."}
                >
                  Delete
                </.dm_btn>
              </div>
            </div>
          </div>
        </div>
      </.dm_card>
    </div>
    """
  end

  defp render_cred_form(assigns) do
    ~H"""
    <div class="mb-6">
      <.dm_card variant="bordered">
        <:title>
          <%= case @cred_form_mode do %>
            <% :add -> %>New Credential
            <% :edit -> %>Edit Credential: {@cred_editing_name}
            <% :rotate -> %>Rotate Secret: {@cred_editing_name}
          <% end %>
        </:title>
        <form phx-submit="save_credential" class="space-y-4 p-4">
          <%= if @cred_form_mode == :add do %>
            <div>
              <label class="block text-sm font-medium mb-1">Name</label>
              <input
                type="text"
                name="name"
                value={@cred_name}
                placeholder="e.g. anthropic-prod-key"
                class="w-full px-3 py-2 border rounded bg-surface-container text-on-surface"
                required
              />
            </div>
          <% end %>

          <%= if @cred_form_mode in [:add, :edit] do %>
            <div>
              <label class="block text-sm font-medium mb-1">Kind</label>
              <select
                name="kind"
                class="w-full px-3 py-2 border rounded bg-surface-container text-on-surface"
              >
                <option value="llm" selected={@cred_kind == "llm"}>LLM Provider</option>
                <option value="upstream" selected={@cred_kind == "upstream"}>Upstream MCP</option>
                <option value="service" selected={@cred_kind == "service"}>Service</option>
                <option value="admin" selected={@cred_kind == "admin"}>Admin</option>
                <option value="custom" selected={@cred_kind == "custom"}>Custom</option>
              </select>
            </div>
          <% end %>

          <div>
            <label class="block text-sm font-medium mb-1">
              <%= if @cred_form_mode == :rotate, do: "New Secret", else: "Secret" %>
            </label>
            <input
              type="password"
              name="secret"
              placeholder={if @cred_form_mode == :edit, do: "Leave empty to keep current secret", else: "API key or token"}
              class="w-full px-3 py-2 border rounded bg-surface-container text-on-surface"
              {if @cred_form_mode in [:add, :rotate], do: [required: true], else: []}
            />
            <p :if={@cred_form_mode == :edit} class="text-xs text-on-surface-variant mt-1">
              Leave empty to keep the current secret. Enter a new value to rotate it.
            </p>
          </div>

          <div class="flex gap-2">
            <.dm_btn type="submit" variant="primary">
              <%= case @cred_form_mode do %>
                <% :add -> %>Store Credential
                <% :edit -> %>Save Changes
                <% :rotate -> %>Rotate Secret
              <% end %>
            </.dm_btn>
            <.dm_btn type="button" phx-click="cancel_cred_form">Cancel</.dm_btn>
          </div>
        </form>
      </.dm_card>
    </div>
    """
  end
end
