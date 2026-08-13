defmodule Backplane.Admin.MemoryConfigLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_page_header: 1]

  alias Backplane.Memory.Config

  @impl true
  def mount(params, session, socket) do
    if connected?(socket), do: Backplane.Settings.subscribe()
    params = if is_map(params), do: params, else: %{}
    query = params |> Map.get("q", "") |> String.trim()

    {:ok,
     assign(socket,
       current_path: "/memory/config",
       query: query,
       entries: entries(query),
       authorized?: Map.get(session, "memory_config_authorized", false) == true,
       mutation_error: nil,
       mutation_success: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = params |> Map.get("q", "") |> String.trim()
    {:noreply, assign(socket, query: query, entries: entries(query))}
  end

  @impl true
  def handle_event("filter", %{"filters" => %{"q" => query}}, socket) do
    query = String.trim(query || "")
    path = if query == "", do: ~p"/memory/config", else: ~p"/memory/config?#{%{"q" => query}}"
    {:noreply,
     socket
     |> assign(query: query, entries: entries(query))
     |> push_patch(to: path, replace: true)}
  end

  def handle_event(
        "set-setting",
        %{"setting" => %{"key" => key, "value" => value}},
        %{assigns: %{authorized?: true}} = socket
      ) do
    request_id = Ecto.UUID.generate()

    case Config.update_setting(key, value, %{
           actor: "trusted-admin:memory-config",
           request_id: request_id,
           correlation_id: request_id
         }) do
      {:ok, _value} ->
        {:noreply,
         assign(socket,
           entries: entries(socket.assigns.query),
           mutation_error: nil,
           mutation_success: "Setting saved and audited."
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           mutation_error: setting_error(reason),
           mutation_success: nil
         )}
    end
  end

  def handle_event("set-setting", _params, socket) do
    {:noreply,
     assign(socket,
       mutation_error: "This route is not authorized to change Memory settings.",
       mutation_success: nil
     )}
  end

  @impl true
  def handle_info({:setting_changed, "memory." <> _rest, _value}, socket) do
    {:noreply, assign(socket, entries: entries(socket.assigns.query))}
  end

  def handle_info({:setting_changed, _key, _value}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-config">
      <.memory_page_header title="Config" subtitle="Effective typed Memory V2 runtime configuration" />
      <.form id="memory-config-filter" for={%{}} as={:filters} phx-change="filter" phx-submit="filter" class="max-w-xl"><.dm_input id="memory-config-query" name="filters[q]" label="Filter settings" value={@query} phx-debounce="300" /></.form>
      <.dm_alert :if={!@authorized?} id="config-unauthorized" variant="warning" title="Read-only configuration" class="mt-4">This LiveView was not mounted through the trusted Memory operator route.</.dm_alert>
      <.dm_alert :if={@mutation_error} id="config-mutation-error" variant="error" title="Setting not saved" class="mt-4">{@mutation_error}</.dm_alert>
      <.dm_alert :if={@mutation_success} id="config-mutation-success" variant="success" title="Setting saved" class="mt-4">{@mutation_success}</.dm_alert>
      <.dm_card :if={@entries == []} id="config-empty" variant="bordered" padding="lg" class="mt-4"><h2 class="text-lg font-semibold">No configuration matches</h2></.dm_card>
      <div class="mt-4 overflow-x-auto"><.dm_table :if={@entries != []} id="memory-config-table" data={@entries} compact hover zebra><:col :let={entry} label="Setting"><span class="font-medium">{entry.label}</span><code class="block text-xs text-on-surface-variant">{entry.key}</code></:col><:col :let={entry} label="Configured"><code>{display(entry.configured)}</code></:col><:col :let={entry} label="Effective"><code>{display(entry.effective)}</code></:col><:col :let={entry} label="Update"><.form id={"memory-config-form-#{form_id(entry.key)}"} for={%{}} phx-submit="set-setting" class="flex min-w-72 items-end gap-2"><input type="hidden" name="setting[key]" value={entry.key} /><select :if={entry.type == :boolean} id={"memory-config-value-#{form_id(entry.key)}"} name="setting[value]" disabled={!@authorized?} class="rounded border border-outline bg-surface px-2 py-1"><option value="true" selected={entry.configured == true}>true</option><option value="false" selected={entry.configured == false}>false</option></select><input :if={entry.type != :boolean} id={"memory-config-value-#{form_id(entry.key)}"} name="setting[value]" type="number" step={if entry.type == :float, do: "any", else: "1"} min={entry.minimum} max={entry.maximum} value={entry.configured} disabled={!@authorized?} class="w-36 rounded border border-outline bg-surface px-2 py-1" /><.dm_btn type="submit" size="sm" disabled={!@authorized?}>Save</.dm_btn></.form></:col></.dm_table></div>
      <div class="mt-5 flex gap-3 text-sm"><.link navigate={~p"/memory/pipeline"} class="text-primary underline">Pipeline controls</.link><.link navigate={~p"/memory/audit"} class="text-primary underline">Audit</.link></div>
    </div>
    """
  end

  defp entries(query) do
    normalized = String.downcase(query || "")

    Enum.filter(Config.editable_settings(), fn entry ->
      normalized == "" or String.contains?(String.downcase(entry.label), normalized) or
        String.contains?(entry.key, normalized)
    end)
  end

  defp display(value) when is_binary(value), do: value
  defp display(value), do: inspect(value)
  defp form_id(key), do: String.replace(key, ".", "-")
  defp setting_error(:invalid_value), do: "The value is outside the typed setting bounds."
  defp setting_error(:unknown_setting), do: "The submitted setting is not editable here."
  defp setting_error(_reason), do: "The setting could not be saved."
end
