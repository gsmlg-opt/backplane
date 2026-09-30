defmodule Backplane.Admin.CodexCatalogLive do
  @moduledoc "Administer the explicit Codex model exposure policy."

  use Backplane.Admin, :live_view

  alias Backplane.LLM.{CodexCatalog, CodexCatalogEntry}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/llama/codex-catalog",
       entries: [],
       invalid_entries: [],
       candidates: [],
       search: "",
       editing: nil,
       form: to_form(defaults(), as: :catalog),
       preview: nil,
       preview_entries: []
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("search", %{"filters" => %{"search" => search}}, socket) do
    {:noreply, assign(socket, search: search) |> load()}
  end

  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, editing: nil, form: to_form(defaults(), as: :catalog))}
  end

  def handle_event("select_candidate", %{"source" => source}, socket) do
    params = Map.put(socket.assigns.form.params || %{}, "source_model", source)

    {:noreply, assign(socket, form: to_form(params, as: :catalog))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case CodexCatalog.get(id) do
      %CodexCatalogEntry{} = entry ->
        {:noreply,
         assign(socket, editing: entry, form: to_form(form_values(entry), as: :catalog))}

      nil ->
        {:noreply, put_flash(socket, :error, "Catalog entry not found")}
    end
  end

  def handle_event("validate", %{"catalog" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :catalog, action: :validate))}
  end

  def handle_event("save", %{"catalog" => params}, socket) do
    params = normalize_form_params(params)

    result =
      case socket.assigns.editing do
        %CodexCatalogEntry{} = entry -> CodexCatalog.update(entry, params)
        nil -> CodexCatalog.create(params)
      end

    case result do
      {:ok, entry} ->
        Backplane.Admin.Audit.record(
          if(socket.assigns.editing, do: "codex_catalog.update", else: "codex_catalog.create"),
          "codex_catalog_entry",
          entry.id
        )

        {:noreply,
         socket
         |> put_flash(:info, "Codex catalog entry saved")
         |> assign(editing: nil, form: to_form(defaults(), as: :catalog))
         |> load()}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           form: to_form(params, as: :catalog, errors: changeset.errors, action: :validate)
         )}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with %CodexCatalogEntry{} = entry <- CodexCatalog.get(id),
         {:ok, updated} <- CodexCatalog.toggle(entry) do
      Backplane.Admin.Audit.record("codex_catalog.toggle", "codex_catalog_entry", updated.id)
      {:noreply, load(socket)}
    else
      nil -> {:noreply, put_flash(socket, :error, "Catalog entry not found")}
      {:error, changeset} -> {:noreply, put_flash(socket, :error, inspect(changeset.errors))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %CodexCatalogEntry{} = entry <- CodexCatalog.get(id),
         {:ok, _} <- CodexCatalog.delete(entry) do
      Backplane.Admin.Audit.record("codex_catalog.delete", "codex_catalog_entry", entry.id)
      {:noreply, load(socket)}
    else
      nil -> {:noreply, put_flash(socket, :error, "Catalog entry not found")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  def handle_event("preview", _params, socket) do
    {response, invalid} = CodexCatalog.response()
    {preview_entries, _} = CodexCatalog.effective()

    {:noreply,
     assign(socket,
       preview: Jason.encode!(response, pretty: true),
       preview_entries: preview_entries,
       invalid_entries: invalid
     )}
  end

  defp load(socket) do
    {_, invalid_entries} = CodexCatalog.effective()
    entries = filter_entries(CodexCatalog.list(), socket.assigns.search)

    assign(socket,
      entries: entries,
      invalid_entries: invalid_entries,
      candidates: CodexCatalog.candidates()
    )
  rescue
    _ -> assign(socket, entries: [], invalid_entries: [], candidates: [])
  end

  defp filter_entries(entries, ""), do: entries

  defp filter_entries(entries, search) do
    query = String.downcase(search)

    Enum.filter(entries, fn entry ->
      Enum.any?([entry.public_model_id, entry.source_model, entry.display_name], fn value ->
        is_binary(value) and String.contains?(String.downcase(value), query)
      end)
    end)
  end

  defp defaults do
    %{
      "public_model_id" => "",
      "source_model" => "",
      "display_name" => "",
      "description" => "",
      "priority" => "100",
      "enabled" => "false",
      "context_window_override" => "",
      "reasoning_levels" => ""
    }
  end

  defp form_values(entry) do
    %{
      "public_model_id" => entry.public_model_id,
      "source_model" => entry.source_model,
      "display_name" => entry.display_name || "",
      "description" => entry.description || "",
      "priority" => to_string(entry.priority),
      "enabled" => to_string(entry.enabled),
      "context_window_override" =>
        entry.context_window_override && to_string(entry.context_window_override),
      "reasoning_levels" => reasoning_levels(entry.reasoning_metadata)
    }
  end

  defp reasoning_levels(%{"supported_reasoning_levels" => levels}) when is_list(levels) do
    Enum.map_join(levels, ",", fn
      %{"effort" => effort} -> effort
      effort when is_binary(effort) -> effort
      _ -> ""
    end)
  end

  defp reasoning_levels(_), do: ""

  defp normalize_form_params(params) do
    levels =
      params
      |> Map.get("reasoning_levels", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    params
    |> Map.put("enabled", Map.get(params, "enabled") in ["true", "1", true])
    |> Map.put("priority", Map.get(params, "priority", "100"))
    |> Map.put("reasoning_metadata", %{"supported_reasoning_levels" => levels})
    |> Map.delete("reasoning_levels")
  end

  defp status(entry, invalid_entries) do
    if Enum.any?(invalid_entries, fn {invalid, _} -> invalid.id == entry.id end),
      do: "Invalid route",
      else: if(entry.enabled, do: "Exposed", else: "Hidden")
  end

  defp context_override(%{context_window_override: nil}), do: "Inherited"
  defp context_override(%{context_window_override: value}), do: to_string(value)

  defp source_provider(source_model) do
    case String.split(source_model, "/", parts: 2) do
      [provider, _model] -> provider
      _ -> "Alias"
    end
  end

  defp reasoning_summary(%{reasoning_metadata: %{"supported_reasoning_levels" => levels}})
       when is_list(levels),
       do: Enum.map_join(levels, ", ", &reasoning_effort/1)

  defp reasoning_summary(_entry), do: "Inherited"

  defp reasoning_effort(%{"effort" => effort}) when is_binary(effort), do: effort
  defp reasoning_effort(effort) when is_binary(effort), do: effort
  defp reasoning_effort(_effort), do: "?"

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6 flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 class="text-2xl font-bold">Codex Model Catalog</h1>
          <p class="mt-1 text-sm text-on-surface-variant">
            Explicitly choose which routable Backplane models Codex can discover.
          </p>
        </div>
        <div class="flex gap-2">
          <.dm_btn type="button" variant="outline" phx-click="preview">
            <.dm_mdi name="code-json" class="h-4 w-4" /> Preview JSON
          </.dm_btn>
          <.dm_btn type="button" variant="primary" phx-click="new">
            <.dm_mdi name="plus" class="h-4 w-4" /> Add model
          </.dm_btn>
        </div>
      </div>

      <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_22rem]">
        <.dm_card variant="bordered">
          <:title>Exposure policy</:title>
          <.form for={%{}} as={:filters} id="codex-catalog-search-form" phx-change="search" class="mb-4 max-w-xl">
            <.dm_input id="codex-catalog-search" name="filters[search]" label="Search catalog" value={@search} phx-debounce="250" />
          </.form>
          <.dm_table id="codex-catalog-table" data={@entries} hover zebra>
            <:col :let={entry} label="Enabled">
              <.dm_btn type="button" size="xs" shape="circle" variant={if entry.enabled, do: "success", else: "outline"} phx-click="toggle" phx-value-id={entry.id} aria-label={if entry.enabled, do: "Disable #{entry.public_model_id}", else: "Enable #{entry.public_model_id}"}>
                <.dm_mdi name={if entry.enabled, do: "check", else: "minus"} class="h-4 w-4" />
              </.dm_btn>
            </:col>
            <:col :let={entry} label="Codex model">
              <div class="font-medium">{entry.public_model_id}</div>
              <div class="text-xs text-on-surface-variant">{entry.display_name || "No display name"}</div>
            </:col>
            <:col :let={entry} label="Routing target"><code class="text-xs">{entry.source_model}</code></:col>
            <:col :let={entry} label="Source provider">{source_provider(entry.source_model)}</:col>
            <:col :let={entry} label="Context">{context_override(entry)}</:col>
            <:col :let={entry} label="Reasoning">{reasoning_summary(entry)}</:col>
            <:col :let={entry} label="Priority">{entry.priority}</:col>
            <:col :let={entry} label="Status">{status(entry, @invalid_entries)}</:col>
            <:col :let={entry} label="Actions">
              <div class="flex gap-1">
                <.dm_btn type="button" size="xs" variant="outline" phx-click="edit" phx-value-id={entry.id} aria-label={"Edit #{entry.public_model_id}"}><.dm_mdi name="pencil" class="h-4 w-4" /></.dm_btn>
                <.dm_btn type="button" size="xs" variant="error" phx-click="delete" phx-value-id={entry.id} data-confirm="Remove this Codex catalog entry?" aria-label={"Remove #{entry.public_model_id}"}><.dm_mdi name="delete" class="h-4 w-4" /></.dm_btn>
              </div>
            </:col>
          </.dm_table>
          <p :if={@entries == []} class="py-6 text-sm text-on-surface-variant">No catalog entries configured.</p>
          <div :if={@invalid_entries != []} class="mt-4 space-y-2">
            <.dm_alert :for={{entry, reason} <- @invalid_entries} id={"codex-invalid-#{entry.id}"} variant="warning" title={entry.public_model_id}>
              This enabled entry is not published: {inspect(reason)}.
            </.dm_alert>
          </div>

          <div id="codex-catalog-candidates" class="mt-6 border-t border-outline-variant pt-4">
            <h3 class="text-sm font-semibold">Routable model candidates</h3>
            <p :if={@candidates == []} class="mt-2 text-sm text-on-surface-variant">
              No enabled OpenAI Responses models are available.
            </p>
            <div :if={@candidates != []} class="mt-3 space-y-2">
              <div
                :for={candidate <- @candidates}
                id={"codex-candidate-#{candidate.source_model}"}
                class="flex flex-wrap items-center justify-between gap-3 rounded border border-outline-variant px-3 py-2"
              >
                <div class="min-w-0">
                  <div class="font-medium">{candidate.display_name}</div>
                  <div class="text-xs text-on-surface-variant">{candidate.provider}</div>
                  <code class="block truncate text-xs text-on-surface-variant">{candidate.source_model}</code>
                </div>
                <.dm_btn
                  type="button"
                  size="xs"
                  variant="outline"
                  phx-click="select_candidate"
                  phx-value-source={candidate.source_model}
                >
                  Use
                </.dm_btn>
              </div>
            </div>
          </div>
        </.dm_card>

        <.dm_card variant="bordered">
          <:title>{if @editing, do: "Edit catalog entry", else: "Add catalog entry"}</:title>
          <.form for={@form} id="codex-catalog-form" phx-change="validate" phx-submit="save" class="space-y-3">
            <.dm_input id="codex-public-id" name="catalog[public_model_id]" label="Codex model ID" value={@form[:public_model_id].value} required />
            <.dm_input id="codex-source-model" name="catalog[source_model]" label="Routing target (provider/model or alias)" value={@form[:source_model].value} required />
            <.dm_input id="codex-display-name" name="catalog[display_name]" label="Display name" value={@form[:display_name].value} />
            <.dm_input id="codex-description" name="catalog[description]" label="Description" value={@form[:description].value} />
            <div class="grid grid-cols-2 gap-3">
              <.dm_input id="codex-priority" name="catalog[priority]" type="number" label="Priority" value={@form[:priority].value} min="0" required />
              <.dm_input id="codex-context" name="catalog[context_window_override]" type="number" label="Context override" value={@form[:context_window_override].value} min="1" />
            </div>
            <.dm_input id="codex-reasoning" name="catalog[reasoning_levels]" label="Reasoning efforts (comma-separated)" value={@form[:reasoning_levels].value} placeholder="low,medium,high" />
            <label class="flex items-center gap-2 text-sm"><input type="checkbox" name="catalog[enabled]" value="true" checked={@form[:enabled].value in [true, "true", "1"]} /> Expose in Codex</label>
            <div :if={@form.errors != []} class="space-y-1 text-sm text-error">
              <p :for={{field, {message, _opts}} <- @form.errors}>{field}: {message}</p>
            </div>
            <div class="flex gap-2 pt-2">
              <.dm_btn type="submit" variant="primary">Save</.dm_btn>
              <.dm_btn type="button" variant="outline" phx-click="new">Clear</.dm_btn>
            </div>
          </.form>
        </.dm_card>
      </div>

      <.dm_card :if={@preview} variant="bordered" class="mt-6">
        <:title>Effective Codex catalog preview</:title>
        <p class="mb-3 text-sm text-on-surface-variant">
          {length(@preview_entries)} models will be published.
        </p>
        <div :if={@preview_entries != []} class="mb-4 overflow-x-auto">
          <table id="codex-catalog-preview-summary" class="table table-zebra">
            <thead>
              <tr><th>Codex model</th><th>Display name</th><th>Source provider</th><th>Routing target</th><th>Context</th><th>Reasoning</th><th>Priority</th></tr>
            </thead>
            <tbody>
              <tr :for={item <- @preview_entries}>
                <td>{item.entry.public_model_id}</td>
                <td>{item.descriptor["display_name"]}</td>
                <td>{source_provider(item.entry.source_model)}</td>
                <td><code>{item.entry.source_model}</code></td>
                <td>{item.metadata["context_window"] || "Unknown"}</td>
                <td>{preview_reasoning(item.metadata["supported_reasoning_levels"])}</td>
                <td>{item.entry.priority}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <pre id="codex-catalog-preview" class="max-h-[32rem] overflow-auto whitespace-pre-wrap text-xs">{@preview}</pre>
      </.dm_card>
    </div>
    """
  end

  defp preview_reasoning(levels) when is_list(levels),
    do: Enum.map_join(levels, ", ", &reasoning_effort/1)

  defp preview_reasoning(_levels), do: "None"
end
