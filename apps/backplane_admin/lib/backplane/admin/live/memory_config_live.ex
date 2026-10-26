defmodule Backplane.Admin.MemoryConfigLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_page_header: 1]

  alias Backplane.Memory.Config

  @embedding_model_key "memory.embed_model"

  @impl true
  def mount(params, session, socket) do
    if connected?(socket) do
      Backplane.Settings.subscribe()
      Backplane.PubSubBroadcaster.subscribe(Backplane.PubSubBroadcaster.llm_providers_topic())
    end

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
        Backplane.Admin.Audit.record("memory_setting.update", "memory_setting")

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

  def handle_info({:llm_providers_changed, _payload}, socket),
    do: {:noreply, assign(socket, entries: entries(socket.assigns.query))}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-config">
      <.memory_page_header title="Config" subtitle="Capture, processing, and retrieval settings with their effective runtime state" />
      <.form id="memory-config-filter" for={%{}} as={:filters} phx-change="filter" phx-submit="filter" class="max-w-xl"><.dm_input id="memory-config-query" name="filters[q]" label="Filter settings" value={@query} phx-debounce="300" /></.form>
      <.dm_alert :if={!@authorized?} id="config-unauthorized" variant="warning" title="Read-only configuration" class="mt-4">This LiveView was not mounted through the trusted Memory operator route.</.dm_alert>
      <.dm_alert :if={@mutation_error} id="config-mutation-error" variant="error" title="Setting not saved" class="mt-4">{@mutation_error}</.dm_alert>
      <.dm_alert :if={@mutation_success} id="config-mutation-success" variant="success" title="Setting saved" class="mt-4">{@mutation_success}</.dm_alert>
      <.dm_card :if={@entries == []} id="config-empty" variant="bordered" padding="lg" class="mt-4"><h2 class="text-lg font-semibold">No configuration matches</h2></.dm_card>
      <.dm_alert id="memory-config-policy" variant="info" title="Persistent central policy" class="mt-4">
        Changes are stored centrally. Provider resolution below confirms routing, not a successful provider request.
        Host capture paths and local limits are configured in the standalone YAML. A host applies central sync policy during negotiation;
        check its last report on the host page and treat disconnected reports as stale.
      </.dm_alert>
      <p class="mt-5 mb-3 text-sm text-on-surface-variant">{length(@entries)} settings</p>
      <div :if={@entries != []} id="memory-config-table" class="space-y-3">
        <section :for={entry <- @entries} class="memory-setting" aria-label={entry.label}>
          <div>
            <h2 class="font-semibold">{entry.label}</h2>
            <code class="mt-1 block text-xs text-on-surface-variant">{entry.key}</code>
            <p class="mt-3 text-xs text-on-surface-variant">Configured: <code class="text-on-surface">{display(entry.configured)}</code></p>
          </div>
          <div>
            <h3 class="memory-eyebrow mb-2">Effective state</h3>
            <code class="text-sm">{display(entry.effective)}</code>
            <p class="mt-1 text-xs text-on-surface-variant">{entry.reason}</p>
            <p :if={entry.type == :model} class="mt-1 text-sm" id={"route-" <> form_id(entry.key)}>{entry.route_status}</p>
            <p class="mt-2 text-xs text-on-surface-variant">{entry.apply_mode}</p>
          </div>
          <.form id={"memory-config-form-#{form_id(entry.key)}"} for={%{}} phx-submit="set-setting" class="flex min-w-0 items-end gap-2">
            <input type="hidden" name="setting[key]" value={entry.key} />
            <div class="min-w-0 flex-1">
              <.dm_select :if={entry.type in [:boolean, :model, :credential]}
                id={"memory-config-value-#{form_id(entry.key)}"} name="setting[value]"
                label={entry.label} options={entry.options} value={form_value(entry.configured)} disabled={!@authorized?} />
              <.dm_input :if={entry.type in [:integer, :float]}
                id={"memory-config-value-#{form_id(entry.key)}"} name="setting[value]" label={entry.label}
                type="number" step={if entry.type == :float, do: "any", else: "1"}
                min={entry.minimum} max={entry.maximum} value={entry.configured} disabled={!@authorized?} />
            </div>
            <.dm_btn type="submit" native_submit variant="secondary" size="sm" disabled={!@authorized?}>Save</.dm_btn>
          </.form>
        </section>
      </div>
      <div class="mt-5 flex gap-3 text-sm"><.link navigate={~p"/memory/pipeline"} class="text-primary underline">Pipeline controls</.link><.link navigate={~p"/memory/audit"} class="text-primary underline">Audit</.link></div>
    </div>
    """
  end

  defp entries(query) do
    normalized = String.downcase(query || "")

    models = model_options()
    credentials = credential_options()

    Config.editable_settings()
    |> Enum.map(fn entry ->
      options =
        case entry.type do
          :boolean ->
            [{"true", "true"}, {"false", "false"}]

          :model ->
            choices = if entry.key == @embedding_model_key, do: embedding_options(), else: models
            with_current(choices, entry.configured)

          :credential ->
            with_current(credentials, entry.configured)

          _ ->
            []
        end

      entry |> Map.put(:options, options) |> Map.put(:route_status, route_status(entry))
    end)
    |> Enum.filter(fn entry ->
      normalized == "" or String.contains?(String.downcase(entry.label), normalized) or
        String.contains?(entry.key, normalized)
    end)
  end

  defp model_options do
    routes =
      Backplane.LLM.ProviderModelSurface.list_enabled(:openai)
      |> Enum.map(fn surface ->
        model = surface.provider_model
        value = model.provider.name <> "/" <> model.model
        {value, value}
      end)

    aliases = Enum.map(Backplane.LLM.ModelAlias.list(), &{&1.alias, &1.alias <> " (alias)"})
    [{"", "No model"} | Enum.sort(Enum.uniq(routes ++ aliases))]
  end

  defp credential_options do
    names =
      Backplane.Settings.Credentials.list()
      |> Enum.filter(
        &(&1.kind == "service" and (&1.metadata || %{})["auth_type"] in [nil, "api_key"])
      )
      |> Enum.map(&{&1.name, &1.name})

    [{"", "No resource credential"} | names]
  end

  defp embedding_options do
    models =
      Backplane.Embedding.list_enabled_models()
      |> Enum.map(fn model ->
        value = Backplane.Embedding.model_id(model)
        {value, value}
      end)

    [{"", "No model"} | models]
  end

  defp with_current(options, current) when is_binary(current) and current != "" do
    if Enum.any?(options, &(elem(&1, 0) == current)),
      do: options,
      else: options ++ [{current, current <> " (unavailable)"}]
  end

  defp with_current(options, _), do: options

  defp route_status(%{key: key, effective: model})
       when key == @embedding_model_key and is_binary(model) do
    case Backplane.Embedding.resolve_model(model) do
      {:ok, provider, raw_model} ->
        "Route resolved: " <> provider.name <> " / " <> raw_model <> "; request health unverified"

      _ ->
        "Blocked: selected model has no enabled embedding provider route"
    end
  end

  defp route_status(%{type: :model, effective: model}) when is_binary(model) do
    case Backplane.LLM.ModelResolver.resolve(:openai, model) do
      {:ok, provider, raw_model} ->
        "Route resolved: " <> provider.name <> " / " <> raw_model <> "; request health unverified"

      _ ->
        "Blocked: selected model has no enabled OpenAI-compatible provider route"
    end
  end

  defp route_status(_), do: nil
  defp form_value(nil), do: ""
  defp form_value(value), do: to_string(value)

  defp display(value) when is_binary(value), do: value
  defp display(value), do: inspect(value)
  defp form_id(key), do: String.replace(key, ".", "-")

  defp setting_error(:invalid_value), do: "The value is outside the typed setting bounds."
  defp setting_error(:unknown_setting), do: "The submitted setting is not editable here."
  defp setting_error(_reason), do: "The setting could not be saved."
end
