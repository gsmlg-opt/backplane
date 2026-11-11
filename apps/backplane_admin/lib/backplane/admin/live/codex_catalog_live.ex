defmodule Backplane.Admin.CodexCatalogLive do
  @moduledoc "Administer the imported Codex model catalog."
  use Backplane.Admin, :live_view

  alias Backplane.LLM.{CodexCatalog, CodexCatalogEntry}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/llama/codex-catalog",
       entries: [],
       saved_count: 0,
       published_count: 0,
       provider_rows: [],
       invalid_entries: [],
       providers: [],
       import_provider_id: "",
       busy: nil,
       preview: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("select_provider", %{"import" => %{"provider_id" => id}}, socket),
    do: {:noreply, assign(socket, import_provider_id: id)}

  def handle_event(
        "import",
        %{"import" => %{"provider_id" => id}},
        %{assigns: %{busy: nil}} = socket
      ) do
    if Enum.any?(socket.assigns.providers, &(&1.id == id)) do
      {:noreply,
       socket
       |> assign(import_provider_id: id, busy: {:import, id})
       |> start_async({:import, id}, fn -> CodexCatalog.import_provider(id) end)}
    else
      {:noreply, put_flash(socket, :error, dgettext("errors", "Select a configured Codex provider"))}
    end
  end

  def handle_event("import", _params, socket), do: {:noreply, socket}

  def handle_event("refresh_provider", %{"id" => id}, %{assigns: %{busy: nil}} = socket) do
    if Enum.any?(socket.assigns.provider_rows, &(&1.provider.id == id)) do
      {:noreply,
       socket
       |> assign(busy: {:refresh, id})
       |> start_async({:refresh, id}, fn -> CodexCatalog.import_provider(id) end)}
    else
      {:noreply, put_flash(socket, :error, dgettext("errors", "Select a configured Codex provider"))}
    end
  end

  def handle_event("refresh_provider", _params, socket), do: {:noreply, socket}

  def handle_event("toggle", %{"id" => id}, %{assigns: %{busy: nil}} = socket) do
    with %CodexCatalogEntry{} = entry <- CodexCatalog.get(id),
         true <- imported?(entry) or entry.enabled,
         {:ok, updated} <- CodexCatalog.toggle(entry) do
      Backplane.Admin.Audit.record("codex_catalog.toggle", "codex_catalog_entry", updated.id)
      {:noreply, load(socket)}
    else
      nil ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Catalog entry not found"))}

      false ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Only imported Codex models can be enabled"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Could not change model exposure"))}
    end
  end

  def handle_event("toggle", _params, socket), do: {:noreply, socket}

  def handle_event("delete", %{"id" => id}, %{assigns: %{busy: nil}} = socket) do
    with %CodexCatalogEntry{} = entry <- CodexCatalog.get(id),
         {:ok, _} <- CodexCatalog.delete(entry) do
      Backplane.Admin.Audit.record("codex_catalog.delete", "codex_catalog_entry", entry.id)
      {:noreply, load(socket)}
    else
      nil -> {:noreply, put_flash(socket, :error, dgettext("errors", "Catalog entry not found"))}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, dgettext("errors", "Could not remove catalog entry"))}
    end
  end

  def handle_event("delete", _params, socket), do: {:noreply, socket}

  def handle_event("preview", _params, socket) do
    {response, invalid} = CodexCatalog.response()

    {:noreply,
     assign(socket,
       preview: Jason.encode!(response, pretty: true),
       invalid_entries: invalid
     )}
  end

  @impl true
  def handle_async({:import, provider_id}, {:ok, {:ok, counts}}, socket) do
    Backplane.Admin.Audit.record("codex_catalog.import", "llm_provider", provider_id)

    {:noreply,
     socket
     |> assign(busy: nil)
     |> put_flash(
       :info,
       dgettext(
         "admin",
         "Codex models imported: %{created} new, %{refreshed} refreshed, %{retained} retained",
         created: counts.created,
         refreshed: counts.refreshed,
         retained: counts.retained
       )
     )
     |> load()}
  end

  def handle_async({:refresh, provider_id}, {:ok, {:ok, counts}}, socket) do
    Backplane.Admin.Audit.record("codex_catalog.refresh", "llm_provider", provider_id)

    {:noreply,
     socket
     |> assign(busy: nil)
     |> put_flash(
       :info,
       dgettext(
         "admin",
         "Codex models refreshed: %{created} new, %{updated} updated, %{retained} retained",
         created: counts.created,
         updated: counts.refreshed,
         retained: counts.retained
       )
     )
     |> load()}
  end

  def handle_async({:import, _id}, {:ok, {:error, {:model_conflict, slug}}}, socket) do
    async_failure(
      socket,
      dgettext("errors", "Model %{slug} is already assigned to another provider", slug: slug)
    )
  end

  def handle_async({action, _id}, {:ok, {:error, _reason}}, socket)
      when action in [:import, :refresh],
      do: async_failure(socket, failure_message(action))

  def handle_async({action, _id}, {:exit, _reason}, socket)
      when action in [:import, :refresh],
      do: async_failure(socket, failure_message(action))

  defp async_failure(socket, message),
    do: {:noreply, socket |> assign(busy: nil) |> put_flash(:error, message) |> load()}

  defp failure_message(:import),
    do: dgettext("errors", "Could not import Codex models. Check the provider and try again.")

  defp failure_message(:refresh),
    do: dgettext("errors", "Could not refresh Codex models. The saved models were kept.")

  defp load(socket) do
    {published, invalid_entries} = CodexCatalog.effective()
    all_entries = CodexCatalog.list()
    providers = CodexCatalog.providers()

    provider_rows =
      providers
      |> Enum.map(fn provider ->
        count =
          Enum.count(
            all_entries,
            &(imported?(&1) and source_provider(&1.source_model) == provider.name)
          )

        %{provider: provider, count: count}
      end)
      |> Enum.filter(&(&1.count > 0))

    assign(socket,
      entries: all_entries,
      saved_count: length(all_entries),
      published_count: length(published),
      provider_rows: provider_rows,
      invalid_entries: invalid_entries,
      providers: providers
    )
  end

  defp imported?(%{metadata: %{"codex_raw" => raw}}) when is_map(raw), do: true
  defp imported?(_entry), do: false

  defp status(entry, invalid_entries) do
    cond do
      not imported?(entry) -> dgettext("admin", "Legacy entry")
      Enum.any?(invalid_entries, fn {invalid, _} -> invalid.id == entry.id end) ->
        dgettext("admin", "Unavailable")
      entry.enabled -> dgettext("admin", "Exposed")
      true -> dgettext("admin", "Hidden")
    end
  end

  defp context_window(%{metadata: %{"codex_raw" => %{"context_window" => value}}}),
    do: to_string(value)

  defp context_window(_entry), do: dgettext("admin", "Unknown")

  defp source_provider(source_model) do
    case String.split(source_model, "/", parts: 2) do
      [provider, _model] -> provider
      _ -> dgettext("admin", "Alias")
    end
  end

  defp reasoning_summary(%{metadata: %{"codex_raw" => %{"supported_reasoning_levels" => levels}}})
       when is_list(levels),
       do: Enum.map_join(levels, ", ", &reasoning_effort/1)

  defp reasoning_summary(_entry), do: dgettext("admin", "Unknown")

  defp reasoning_effort(%{"effort" => effort}) when is_binary(effort), do: effort
  defp reasoning_effort(effort) when is_binary(effort), do: effort
  defp reasoning_effort(_effort), do: "?"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 class="text-xl font-semibold">{dgettext("admin", "Codex Model Catalog")}</h1>
          <p class="text-xs text-on-surface-variant">
            {dgettext("admin", "%{saved} saved · %{published} published", saved: @saved_count, published: @published_count)}
          </p>
        </div>
        <.dm_modal id="codex-catalog-preview-dialog" size="xl">
          <:trigger :let={id}>
            <.dm_btn type="button" size="sm" variant="outline" command="show-modal" commandfor={id} phx-click="preview">
              <.dm_mdi name="code-json" class="h-4 w-4" /> {dgettext("admin", "Preview JSON")}
            </.dm_btn>
          </:trigger>
          <:title>{dgettext("admin", "Effective Codex catalog preview")}</:title>
          <:body>
            <p class="mb-3 text-sm text-on-surface-variant">{dgettext("admin", "%{count} models will be published.", count: @published_count)}</p>
            <pre id="codex-catalog-preview" class="max-h-[65vh] overflow-auto rounded-lg bg-surface-container p-4 text-on-surface text-xs whitespace-pre-wrap break-all">{@preview || dgettext("admin", "Loading preview…")}</pre>
          </:body>
          <:footer>
            <.dm_btn type="button" variant="outline" command="close" commandfor="codex-catalog-preview-dialog">{dgettext("common", "Close")}</.dm_btn>
          </:footer>
        </.dm_modal>
      </div>

      <.dm_card variant="bordered">
        <:title>{dgettext("admin", "Import models")}</:title>
        <div class="space-y-3">
          <.form for={%{}} as={:import} id="codex-provider-import-form" phx-change="select_provider" phx-submit="import" class="flex flex-wrap items-end gap-3">
            <.dm_select id="codex-import-provider" name="import[provider_id]" label={dgettext("admin", "Codex provider")} value={@import_provider_id} prompt={dgettext("admin", "Select a Codex provider")} options={Enum.map(@providers, &{&1.id, &1.name})} disabled={@busy != nil} />
            <.dm_btn type="submit" size="sm" variant="primary" disabled={@busy != nil or @providers == []}>
              {if @busy && elem(@busy, 0) == :import, do: dgettext("admin", "Importing…"), else: dgettext("admin", "Import Models")}
            </.dm_btn>
          </.form>
          <div :if={@provider_rows != []} class="divide-y divide-outline-variant rounded-lg border border-outline-variant">
            <div :for={row <- @provider_rows} class="flex flex-wrap items-center justify-between gap-2 px-3 py-2">
              <div class="min-w-0 text-sm">
                <span class="font-medium">{row.provider.name}</span>
                <span class="ml-2 text-xs text-on-surface-variant">{dgettext("admin", "%{count} saved", count: row.count)}</span>
              </div>
              <.dm_btn id={"refresh-codex-provider-#{row.provider.id}"} type="button" size="xs" variant="outline" phx-click="refresh_provider" phx-value-id={row.provider.id} disabled={@busy != nil}>
                {if @busy == {:refresh, row.provider.id}, do: dgettext("admin", "Refreshing…"), else: dgettext("admin", "Refresh Models")}
              </.dm_btn>
            </div>
          </div>
        </div>
        <p :if={@providers == []} class="mt-3 text-sm text-on-surface-variant">
          {dgettext("admin", "Add and configure an OpenAI Codex provider in Llama Providers before importing models.")}
        </p>
      </.dm_card>

      <.dm_card variant="bordered">
        <:title>{dgettext("admin", "Saved Codex models")}</:title>
        <div class="overflow-x-auto">
          <.dm_table id="codex-catalog-table" data={@entries} hover zebra>
            <:col :let={entry} label={dgettext("admin", "Model")}>
              <div class="min-w-40 font-medium">{entry.public_model_id}</div>
              <div class="text-xs text-on-surface-variant">{entry.display_name || dgettext("admin", "No display name")}</div>
            </:col>
            <:col :let={entry} label={dgettext("admin", "Provider")}>
              <div class="min-w-40">{source_provider(entry.source_model)}</div>
              <code class="text-xs text-on-surface-variant">{entry.source_model}</code>
            </:col>
            <:col :let={entry} label={dgettext("admin", "Context")}>{context_window(entry)}</:col>
            <:col :let={entry} label={dgettext("admin", "Reasoning")}><span class="text-xs">{reasoning_summary(entry)}</span></:col>
            <:col :let={entry} label={dgettext("admin", "Exposure")}>
              <div class="flex items-center gap-2">
                <.dm_tooltip :let={tooltip_attrs} content={if entry.enabled, do: dgettext("common", "Disable"), else: dgettext("common", "Enable")} position="bottom">
                  <.dm_btn {tooltip_attrs} type="button" size="xs" shape="circle" variant={if entry.enabled, do: "success", else: "outline"} phx-click="toggle" phx-value-id={entry.id} disabled={@busy != nil or (not imported?(entry) and not entry.enabled)} aria-label={if entry.enabled, do: dgettext("admin", "Disable %{name}", name: entry.public_model_id), else: dgettext("admin", "Enable %{name}", name: entry.public_model_id)}>
                    <.dm_mdi name={if entry.enabled, do: "check", else: "minus"} class="h-4 w-4" />
                  </.dm_btn>
                </.dm_tooltip>
                <span class="text-xs whitespace-nowrap">{status(entry, @invalid_entries)}</span>
              </div>
            </:col>
            <:col :let={entry} label={dgettext("common", "Actions")}>
              <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Remove")} position="bottom">
                <.dm_btn {tooltip_attrs} type="button" size="xs" shape="circle" variant="error" phx-click="delete" phx-value-id={entry.id} disabled={@busy != nil} data-confirm={dgettext("admin", "Remove this Codex catalog entry?")} aria-label={dgettext("admin", "Remove %{name}", name: entry.public_model_id)}>
                  <.dm_mdi name="delete" class="h-4 w-4" />
                </.dm_btn>
              </.dm_tooltip>
            </:col>
          </.dm_table>
        </div>
        <p :if={@entries == []} class="py-6 text-sm text-on-surface-variant">
          {dgettext("admin", "No saved Codex models. Select a Codex provider above and import its models.")}
        </p>
        <div :if={@invalid_entries != []} class="mt-4 space-y-2">
          <.dm_alert :for={{entry, _reason} <- @invalid_entries} id={"codex-invalid-#{entry.id}"} variant="warning" title={entry.public_model_id}>
            {dgettext("admin", "This saved model is unavailable and is not published.")}
          </.dm_alert>
        </div>
      </.dm_card>

    </div>
    """
  end
end
