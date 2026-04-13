defmodule BackplaneWeb.SettingsLive do
  @moduledoc "Settings page with system settings editor and credentials management."

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

    case Credentials.update(name, %{kind: kind}) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end

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

  @kind_options [
    {"LLM Provider", "llm"},
    {"Upstream MCP", "upstream"},
    {"Service", "service"},
    {"Admin", "admin"},
    {"Custom", "custom"}
  ]

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-2xl font-bold mb-6">Settings</h1>

      <.dm_tab id="settings-tabs" active_tab_index={if @active_tab == "credentials", do: 1, else: 0}>
        <:tab name="settings">
          <.link patch={~p"/admin/settings?tab=settings"}>Settings</.link>
        </:tab>
        <:tab name="credentials">
          <.link patch={~p"/admin/settings?tab=credentials"}>Credentials</.link>
        </:tab>
        <:tab_content name="settings">
          <.render_settings_tab {assigns} />
        </:tab_content>
        <:tab_content name="credentials">
          <.render_credentials_tab {assigns} />
        </:tab_content>
      </.dm_tab>
    </div>
    """
  end

  defp render_settings_tab(assigns) do
    ~H"""
    <div class="space-y-6 mt-4">
      <div :for={{group, settings} <- @settings_groups}>
        <.dm_collapse id={"settings-group-#{group}"} open variant="bordered">
          <:trigger>
            <span class="capitalize text-lg font-semibold">{group}</span>
          </:trigger>
          <:content>
            <div class="divide-y divide-outline-variant">
              <div :for={setting <- settings} class="py-3 flex items-center justify-between gap-4">
                <div class="flex-1 min-w-0">
                  <div class="font-mono text-sm text-on-surface">{setting.key}</div>
                  <div class="text-xs text-on-surface-variant">{setting.description}</div>
                </div>
                <div :if={@editing_key == setting.key}>
                  <form phx-submit="save_setting" class="flex items-center gap-2">
                    <input type="hidden" name="key" value={setting.key} />
                    <.dm_input
                      id={"edit-#{setting.key}"}
                      name="value"
                      value={@edit_value}
                      size="sm"
                    />
                    <.dm_btn type="submit" variant="primary" size="sm">Save</.dm_btn>
                    <.dm_btn variant="error" size="sm" phx-click="cancel_edit">Cancel</.dm_btn>
                  </form>
                </div>
                <div :if={@editing_key != setting.key} class="flex items-center gap-2 shrink-0">
                  <code class="text-sm">{inspect(setting.value)}</code>
                  <.dm_btn size="sm" phx-click="edit_setting" phx-value-key={setting.key}>
                    Edit
                  </.dm_btn>
                </div>
              </div>
            </div>
          </:content>
        </.dm_collapse>
      </div>
    </div>
    """
  end

  defp render_credentials_tab(assigns) do
    assigns = assign(assigns, :kind_options, @kind_options)

    ~H"""
    <div class="mt-4">
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

      <.render_cred_form :if={@cred_form_mode != nil} kind_options={@kind_options} {assigns} />

      <.dm_card variant="bordered">
        <div :if={@credentials == []} class="py-8 text-center text-on-surface-variant">
          No credentials stored yet. Click "Add Credential" to create one.
        </div>
        <div :if={@credentials != []}>
          <.dm_table id="credentials-table" data={@credentials} hover zebra>
            <:col :let={cred} label="Name">
              <code>{cred.name}</code>
            </:col>
            <:col :let={cred} label="Kind">
              <.dm_badge variant="neutral">{cred.kind}</.dm_badge>
            </:col>
            <:col :let={cred} label="Hint">
              <code class="text-on-surface-variant">{cred.hint}</code>
            </:col>
            <:col :let={cred} label="Updated">
              {Calendar.strftime(cred.updated_at, "%Y-%m-%d %H:%M")}
            </:col>
            <:col :let={cred} label="Actions">
              <div class="flex items-center gap-1">
                <.dm_btn size="sm" phx-click="show_edit_form" phx-value-name={cred.name}>
                  Edit
                </.dm_btn>
                <.dm_btn size="sm" variant="warning" phx-click="show_rotate_form" phx-value-name={cred.name}>
                  Rotate
                </.dm_btn>
                <.dm_btn
                  size="sm"
                  variant="error"
                  confirm={"Delete credential '#{cred.name}'? This cannot be undone."}
                  phx-click="delete_credential"
                  phx-value-name={cred.name}
                >
                  Delete
                </.dm_btn>
              </div>
            </:col>
          </.dm_table>
        </div>
      </.dm_card>
    </div>
    """
  end

  defp render_cred_form(assigns) do
    ~H"""
    <.dm_card variant="bordered" class="mb-6">
      <:title>
        <%= case @cred_form_mode do %>
          <% :add -> %>New Credential
          <% :edit -> %>Edit Credential: {@cred_editing_name}
          <% :rotate -> %>Rotate Secret: {@cred_editing_name}
        <% end %>
      </:title>
      <form phx-submit="save_credential" class="space-y-4">
        <%= if @cred_form_mode == :add do %>
          <.dm_input
            id="cred-name"
            name="name"
            label="Name"
            value={@cred_name}
            placeholder="e.g. anthropic-prod-key"
            required
          />
        <% end %>

        <%= if @cred_form_mode in [:add, :edit] do %>
          <.dm_select
            id="cred-kind"
            name="kind"
            label="Kind"
            options={@kind_options}
            value={@cred_kind}
          />
        <% end %>

        <.dm_input
          id="cred-secret"
          name="secret"
          type="password"
          label={if @cred_form_mode == :rotate, do: "New Secret", else: "Secret"}
          placeholder={if @cred_form_mode == :edit, do: "Leave empty to keep current", else: "API key or token"}
          {if @cred_form_mode in [:add, :rotate], do: [required: true], else: []}
        />
        <p :if={@cred_form_mode == :edit} class="text-xs text-on-surface-variant -mt-2">
          Leave empty to keep the current secret. Enter a new value to rotate it.
        </p>

        <div class="flex gap-2 pt-2">
          <.dm_btn type="submit" variant="primary">
            <%= case @cred_form_mode do %>
              <% :add -> %>Store Credential
              <% :edit -> %>Save Changes
              <% :rotate -> %>Rotate Secret
            <% end %>
          </.dm_btn>
          <.dm_btn phx-click="cancel_cred_form">Cancel</.dm_btn>
        </div>
      </form>
    </.dm_card>
    """
  end
end
