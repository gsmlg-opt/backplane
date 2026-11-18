defmodule Backplane.Admin.LLMLive do
  use Backplane.Admin, :live_view

  alias Backplane.LLM.{ModelDiscovery, Provider, ProviderApi, ProviderPreset}
  alias Backplane.Repo

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/llama/llm",
       editing: nil,
       errors: [],
       form: to_form(%{}, as: :llm)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = socket |> load() |> assign(editing: nil, errors: [])

    case socket.assigns.live_action do
      :new ->
        {:noreply, open_form(socket, List.first(socket.assigns.available_providers), true)}

      :edit ->
        case Enum.find(socket.assigns.configured_providers, &(&1.id == params["id"])) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, dgettext("admin", "LLM configuration not found"))
             |> push_patch(to: ~p"/llama/llm")}

          provider ->
            {:noreply, open_form(socket, provider, false)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_provider", %{"llm" => %{"provider_id" => id}}, socket) do
    case Enum.find(socket.assigns.available_providers, &(&1.id == id)) do
      nil -> {:noreply, socket}
      provider -> {:noreply, open_form(socket, provider, true)}
    end
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/llama/llm")}

  def handle_event("delete", %{"id" => id}, socket) do
    with %Provider{} = provider <- Enum.find(socket.assigns.configured_providers, &(&1.id == id)),
         {:ok, _} <-
           Repo.transaction(fn ->
             for api <- configured_apis(provider) do
               update_api!(api, %{
                 native_protocols: [],
                 model_discovery_enabled: false,
                 responses_websocket: false,
                 responses_lifecycle: false
               })
             end
           end) do
      Backplane.Admin.Audit.record("llm.delete", "provider", id)

      {:noreply,
       socket |> load() |> put_flash(:info, dgettext("admin", "LLM configuration removed"))}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, dgettext("errors", "LLM configuration could not be removed"))}
    end
  end

  def handle_event("save", %{"llm" => params}, socket) do
    case socket.assigns.editing do
      %Provider{} = provider ->
        case save_configuration(provider, params) do
          {:ok, _} ->
            Backplane.Admin.Audit.record("llm.configure", "provider", provider.id)

            {:noreply,
             socket
             |> put_flash(:info, dgettext("admin", "LLM configuration saved"))
             |> push_patch(to: ~p"/llama/llm")}

          {:error, error} ->
            {:noreply,
             assign(socket, errors: form_errors(error), form: to_form(params, as: :llm))}
        end

      nil ->
        {:noreply, socket}
    end
  end

  defp load(socket) do
    {configured, available} =
      Provider.list()
      |> Enum.reject(&(&1.apis == []))
      |> Enum.split_with(&(configured_apis(&1) != []))

    assign(socket, configured_providers: configured, available_providers: available)
  end

  defp configured_apis(provider), do: Enum.filter(provider.apis, &(&1.native_protocols != []))

  defp open_form(socket, nil, _new?) do
    assign(socket, editing: nil, form: to_form(%{}, as: :llm))
  end

  defp open_form(socket, provider, new?) do
    apis = Map.new(provider.apis, &{to_string(&1.api_surface), api_values(provider, &1, new?)})

    values = %{
      "provider_default_headers" => Formata.JSON.encode!(provider.default_headers || %{}),
      "models_path" => models_path(provider, new?),
      "apis" => apis
    }

    assign(socket,
      editing: provider,
      form: to_form(values, as: :llm),
      errors: []
    )
  end

  defp api_values(provider, api, new?) do
    defaults = preset_defaults(provider, api)

    selected =
      cond do
        not new? -> api.native_protocols
        defaults[:enabled] == false -> []
        true -> protocols(provider, api)
      end

    %{
      "path" => url_path(api.base_url),
      "default_headers" => Formata.JSON.encode!(api.default_headers || %{}),
      "project_id" => (api.backend_config || %{})["project_id"] || "",
      "user_agent" => (api.backend_config || %{})["user_agent"] || "",
      "client_version" => (api.backend_config || %{})["client_version"] || "",
      "responses_websocket" =>
        to_string(
          if(new?,
            do: Map.get(defaults, :responses_websocket, false),
            else: api.responses_websocket
          )
        ),
      "responses_lifecycle" => to_string(api.responses_lifecycle),
      "responses_route_ttl_seconds" => to_string(api.responses_route_ttl_seconds)
    }
    |> Map.merge(Map.new(protocols(provider, api), &{to_string(&1), to_string(&1 in selected)}))
  end

  defp save_configuration(provider, params) do
    shared = Map.get(params, "provider_default_headers")
    api_params = Map.get(params, "apis", %{})
    api_params = if is_map(api_params), do: api_params, else: %{}

    Repo.transaction(fn ->
      if Map.has_key?(params, "provider_default_headers") do
        headers = parse_headers!(shared)

        if headers != (provider.default_headers || %{}) do
          case Provider.update(provider, %{default_headers: headers}) do
            {:ok, _} -> :ok
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end
      end

      updates =
        Map.new(provider.apis, fn api ->
          fields = Map.get(api_params, to_string(api.api_surface))
          {api.id, if(is_map(fields), do: api_attrs(provider, api, fields), else: %{})}
        end)

      discovery = discovery_updates(provider, updates, params["models_path"])

      for api <- provider.apis do
        attrs = Map.merge(updates[api.id], Map.get(discovery, api.id, %{}))
        if map_size(attrs) > 0, do: update_api!(api, attrs)
      end
    end)
  end

  defp models_path(provider, new?) do
    case ModelDiscovery.discovery_api(provider) do
      %ProviderApi{} = api ->
        api |> ModelDiscovery.discovery_url() |> url_path()

      nil when new? ->
        provider.apis
        |> Enum.filter(& &1.enabled)
        |> Enum.sort_by(&ModelDiscovery.discovery_priority/1)
        |> Enum.find_value("", fn api ->
          defaults = preset_defaults(provider, api)

          if defaults[:enabled] and defaults[:discovery_path] do
            %{api | model_discovery_path: defaults.discovery_path}
            |> ModelDiscovery.discovery_url()
            |> url_path()
          end
        end)

      nil ->
        ""
    end
  end

  defp discovery_updates(provider, updates, path) do
    apis =
      Enum.filter(provider.apis, fn api ->
        api.enabled and Map.get(updates[api.id], :native_protocols, api.native_protocols) != []
      end)

    current = ModelDiscovery.discovery_api(provider)

    source =
      if current in apis,
        do: current,
        else: Enum.min_by(apis, &ModelDiscovery.discovery_priority/1, fn -> nil end)

    path = blank_to_nil(path)
    old_url = if current, do: ModelDiscovery.discovery_url(current)

    target =
      if source && is_nil(provider.host_service_id) && path,
        do: resolve_path!(provider, path, old_url)

    Map.new(provider.apis, fn api ->
      attrs =
        if target && api.id == source.id do
          %{model_discovery_enabled: true, model_discovery_path: target}
        else
          %{model_discovery_enabled: false}
        end

      {api.id, attrs}
    end)
  end

  defp url_path(nil), do: ""

  defp url_path(url) do
    uri = URI.parse(url)
    URI.to_string(%URI{path: uri.path || "/", query: uri.query})
  end

  defp resolve_path!(provider, path, current_url) do
    path = String.trim(path)
    uri = URI.parse(path)

    cond do
      uri.scheme || uri.authority || uri.fragment || String.contains?(path, "\\") ->
        Repo.rollback(dgettext("admin", "Use a relative path for API and model discovery URLs"))

      current_url && path == url_path(current_url) ->
        current_url

      true ->
        base =
          provider.base_url ||
            provider.apis
            |> Enum.min_by(&ModelDiscovery.discovery_priority/1)
            |> Map.fetch!(:base_url)

        base
        |> URI.parse()
        |> then(
          &%{
            &1
            | path: String.trim_trailing(&1.path || "", "/") <> "/",
              query: nil,
              fragment: nil
          }
        )
        |> URI.merge(uri)
        |> URI.to_string()
    end
  end

  defp api_url(provider, %{base_url: current}, %{"path" => path})
       when is_binary(path) and is_nil(provider.host_service_id) do
    case String.trim(path) do
      "" -> Repo.rollback(dgettext("admin", "API path is required"))
      path -> resolve_path!(provider, path, current)
    end
  end

  defp api_url(_provider, api, _params), do: api.base_url

  defp api_attrs(provider, api, params) do
    protocols = Enum.filter(protocols(provider, api), &(params[to_string(&1)] == "true"))

    attrs = %{
      base_url: api_url(provider, api, params),
      backend_config: backend_config(api, params),
      native_protocols: protocols,
      responses_websocket:
        protocols != [] and api.api_surface == :openai and params["responses_websocket"] == "true",
      responses_lifecycle:
        protocols != [] and api.api_surface == :openai and params["responses_lifecycle"] == "true",
      responses_route_ttl_seconds:
        params["responses_route_ttl_seconds"] || api.responses_route_ttl_seconds
    }

    case Map.fetch(params, "default_headers") do
      {:ok, headers} -> Map.put(attrs, :default_headers, parse_headers!(headers))
      :error -> attrs
    end
  end

  defp update_api!(api, attrs) do
    case ProviderApi.update(api, attrs) do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp parse_headers!(value) do
    case parse_headers(value) do
      {:ok, headers} -> headers
      {:error, message} -> Repo.rollback(message)
    end
  end

  defp form_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
  end

  defp form_errors(message), do: [message]

  defp parse_headers(value) when is_binary(value) do
    case Formata.JSON.decode(value) do
      {:ok, headers} when is_map(headers) -> {:ok, headers}
      _ -> {:error, dgettext("admin", "Default Headers must be a JSON object")}
    end
  end

  defp parse_headers(_value),
    do: {:error, dgettext("admin", "Default Headers must be a JSON object")}

  defp backend_config(%{api_surface: :antigravity} = api, params) do
    Enum.reduce(~w(project_id user_agent client_version), api.backend_config || %{}, fn field,
                                                                                        config ->
      if Map.has_key?(params, field),
        do: Map.put(config, field, blank_to_nil(params[field])),
        else: config
    end)
  end

  defp backend_config(api, _params), do: api.backend_config || %{}

  defp preset_defaults(provider, api) do
    case ProviderPreset.get(provider.preset_key || "custom") do
      nil -> %{}
      preset -> ProviderPreset.surface(preset, api.api_surface) || %{}
    end
  end

  defp protocols(provider, api) do
    defaults =
      Map.get(
        preset_defaults(provider, api),
        :native_protocols,
        supported_protocols(api.api_surface)
      )

    Enum.uniq(defaults ++ api.native_protocols)
  end

  defp api_form(form, api) do
    surface = to_string(api.api_surface)
    values = Map.get(form.params, "apis", %{}) |> Map.get(surface, %{})
    to_form(values, as: "llm[apis][#{surface}]")
  end

  defp surface_label(:openai), do: "OpenAI-compatible API"
  defp surface_label(:anthropic), do: "Anthropic Messages API"
  defp surface_label(:google), do: "Google GenerateContent API"
  defp surface_label(:antigravity), do: "Google Antigravity API"

  defp supported_protocols(:openai), do: [:openai_chat_completions, :openai_responses]
  defp supported_protocols(:anthropic), do: [:anthropic_messages]
  defp supported_protocols(:google), do: [:google_generate_content]
  defp supported_protocols(:antigravity), do: [:google_antigravity]

  defp protocol_label(:openai_chat_completions), do: "OpenAI Chat Completions"
  defp protocol_label(:openai_responses), do: "OpenAI Responses (HTTP)"
  defp protocol_label(:anthropic_messages), do: "Anthropic Messages"
  defp protocol_label(:google_generate_content), do: "Google GenerateContent"
  defp protocol_label(:google_antigravity), do: "Google Antigravity"

  defp selected?(form, field), do: form.params[to_string(field)] in [true, "true"]
  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp status(provider) do
    cond do
      not provider.enabled ->
        dgettext("admin", "Provider disabled")

      Enum.all?(configured_apis(provider), &(not &1.enabled)) ->
        dgettext("admin", "Connection disabled")

      true ->
        dgettext("admin", "Configured")
    end
  end

  defp protocol_statuses(provider) do
    protocols =
      supported_protocols(:openai) ++
        supported_protocols(:anthropic) ++
        Enum.flat_map(provider.apis, &protocols(provider, &1))

    enabled_apis = Enum.filter(provider.apis, &(provider.enabled and &1.enabled))
    enabled_protocols = Enum.flat_map(enabled_apis, & &1.native_protocols)

    tags = Enum.map(Enum.uniq(protocols), &{protocol_label(&1), &1 in enabled_protocols})
    openai = Enum.find(enabled_apis, &(&1.api_surface == :openai))

    if openai && :openai_responses in openai.native_protocols do
      tags ++
        [
          {"Responses WebSocket", openai.responses_websocket},
          {"Responses lifecycle", openai.responses_lifecycle}
        ]
    else
      tags
    end
  end

  defp protocol_tag(assigns) do
    ~H"""
    <.dm_badge variant={if @enabled, do: "success", else: "neutral"} size="sm">
      <.dm_mdi name={if @enabled, do: "check", else: "minus"} class="h-3.5 w-3.5" aria-hidden="true" />
      {@label}
      <span class="sr-only">{if @enabled, do: dgettext("common", "Enabled"), else: dgettext("common", "Disabled")}</span>
    </.dm_badge>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@live_action == :index} class="mx-auto w-full min-w-0 max-w-7xl space-y-6">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 class="text-3xl font-bold">{dgettext("admin", "LLM")}</h1>
          <p class="mt-2 text-sm text-on-surface-variant">{dgettext("admin", "Configure conversation APIs and model discovery using an existing Provider connection.")}</p>
        </div>
        <.dm_btn id="add-llm" patch={~p"/llama/llm/new"} variant="primary">{dgettext("common", "Add")}</.dm_btn>
      </div>
      <p class="text-sm text-on-surface-variant">{dgettext("admin", "Each Provider has one LLM configuration. Manage its conversation APIs together here.")}</p>
      <p :if={@configured_providers == []} class="text-sm text-on-surface-variant">{dgettext("admin", "No LLM configurations. Choose Add to configure a Provider.")}</p>
      <div :if={@configured_providers != []} class="overflow-x-auto">
        <.dm_table id="llm-configurations" data={@configured_providers} hover zebra>
          <:col :let={provider} label={dgettext("admin", "Provider")}>
            <span class="break-all font-medium">{provider.name}</span>
          </:col>
          <:col :let={provider} label={dgettext("admin", "Conversation APIs")}>
            <div class="flex flex-wrap gap-1">
              <.protocol_tag :for={{label, enabled} <- protocol_statuses(provider)} label={label} enabled={enabled} />
            </div>
          </:col>
          <:col :let={provider} label={dgettext("admin", "Model discovery")}>
            <%= if api = ModelDiscovery.discovery_api(provider) do %>
              <code class="break-all">{url_path(ModelDiscovery.discovery_url(api))}</code>
            <% else %>
              {dgettext("common", "Disabled")}
            <% end %>
          </:col>
          <:col :let={provider} label={dgettext("common", "Status")}><.dm_badge variant="neutral">{status(provider)}</.dm_badge></:col>
          <:col :let={provider} label={dgettext("common", "Actions")}>
            <div class="flex gap-1">
              <.dm_tooltip :let={attrs} content={dgettext("common", "Edit")} position="bottom">
                <.dm_btn {attrs} id={"edit-llm-#{provider.id}"} patch={~p"/llama/llm/#{provider.id}/edit"} size="xs" shape="circle" variant="outline" aria-label={"Edit #{provider.name} LLM"}>
                  <.dm_mdi name="pencil" class="h-4 w-4" />
                </.dm_btn>
              </.dm_tooltip>
              <.dm_tooltip :let={attrs} content={dgettext("admin", "Manage models")} position="bottom">
                <.dm_btn {attrs} id={"models-llm-#{provider.id}"} navigate={~p"/llama/llm/#{provider.id}/models"} size="xs" shape="circle" variant="outline" aria-label={"Manage #{provider.name} models"}>
                  <.dm_mdi name="format-list-bulleted" class="h-4 w-4" />
                </.dm_btn>
              </.dm_tooltip>
              <.dm_tooltip :let={attrs} content={dgettext("common", "Delete")} position="bottom">
                <.dm_btn {attrs} id={"delete-llm-#{provider.id}"} size="xs" shape="circle" variant="error" aria-label={"Delete #{provider.name} LLM configuration"} phx-click="delete" phx-value-id={provider.id} data-confirm={dgettext("admin", "Remove all conversation APIs from this Provider's LLM configuration?")}>
                  <.dm_mdi name="delete" class="h-4 w-4" />
                </.dm_btn>
              </.dm_tooltip>
            </div>
          </:col>
        </.dm_table>
      </div>
    </div>

    <div :if={@live_action in [:new, :edit]} id="llm-configuration-page" class="mx-auto w-full min-w-0 max-w-7xl space-y-6">
      <.link patch={~p"/llama/llm"} class="text-sm text-primary underline">{dgettext("navigation", "Back to LLM")}</.link>
      <h1 class="text-2xl font-bold">
        {if @live_action == :new, do: dgettext("admin", "Add LLM configuration"), else: dgettext("admin", "Edit LLM configuration")}
      </h1>
      <p :if={is_nil(@editing)}>
        {dgettext("admin", "Configure a Provider connection first, or edit its existing LLM configuration.")}
        <.link navigate={~p"/llama/providers"} class="text-primary underline">{dgettext("admin", "Manage providers")}</.link>
      </p>
      <div :if={@errors != []} id="llm-errors" role="alert" class="text-sm text-error">
        <p :for={error <- @errors}>{error}</p>
      </div>
      <.form :if={@editing} for={@form} id="llm-form" phx-submit="save" class="space-y-6">
        <.dm_select :if={@live_action == :new} id="llm-provider" name="llm[provider_id]" label={dgettext("admin", "Provider")} options={Enum.map(@available_providers, &{&1.id, &1.name})} value={@editing.id} phx-change="select_provider" />
        <p :if={@live_action == :edit} class="font-medium">{@editing.name}</p>
        <.dm_input :if={is_nil(@editing.host_service_id)} id="llm-models-path" field={@form[:models_path]} label={dgettext("admin", "Models path")} placeholder="/models" />
        <p :if={is_nil(@editing.host_service_id)} class="text-xs text-on-surface-variant">{dgettext("admin", "Paths are relative to the Provider Base URL. Leave Models path blank to disable model discovery.")}</p>
        <details id="llm-shared-headers" phx-mounted={JS.ignore_attributes(["open"])}>
          <summary class="cursor-pointer text-sm">{dgettext("admin", "Shared headers (all APIs for this Provider)")}</summary>
          <.dm_textarea id="llm-provider-default-headers" field={@form[:provider_default_headers]} label={dgettext("admin", "Shared Provider Headers")} rows={3} class="mt-3 font-mono" />
          <p class="text-xs text-on-surface-variant">{dgettext("admin", "Protocol Default Headers override shared headers with the same name.")}</p>
        </details>
        <div class={["grid gap-4", length(@editing.apis) > 1 && "xl:grid-cols-2"]}>
          <.api_fields :for={api <- @editing.apis} api={api} provider={@editing} form={api_form(@form, api)} />
        </div>
        <div class="flex gap-2">
          <.dm_btn type="submit" variant="primary" phx-disable-with={dgettext("admin", "Saving…")}>{dgettext("common", "Save")}</.dm_btn>
          <.dm_btn type="button" phx-click="cancel">{dgettext("common", "Cancel")}</.dm_btn>
        </div>
      </.form>
      <.dm_btn :if={is_nil(@editing)} type="button" phx-click="cancel">{dgettext("common", "Cancel")}</.dm_btn>
    </div>
    """
  end

  defp api_fields(assigns) do
    ~H"""
    <fieldset class="space-y-4 rounded-md border border-outline-variant p-4">
      <legend class="px-1 font-medium">{surface_label(@api.api_surface)}</legend>
      <.dm_input :if={is_nil(@provider.host_service_id)} id={"llm-#{@api.api_surface}-path"} field={@form[:path]} label={dgettext("admin", "API path")} />
      <p :if={@provider.host_service_id} class="text-xs text-on-surface-variant">{dgettext("admin", "The Host API Service supplies this endpoint.")}</p>
      <.dm_textarea id={"llm-#{@api.api_surface}-default-headers"} field={@form[:default_headers]} label={dgettext("admin", "Default Headers")} rows={3} class="font-mono" />
      <div :if={@api.api_surface == :antigravity} class="space-y-4">
        <.dm_input id={"llm-#{@api.api_surface}-project-id"} field={@form[:project_id]} label={dgettext("admin", "Project ID")} />
        <.dm_input id={"llm-#{@api.api_surface}-user-agent"} field={@form[:user_agent]} label={dgettext("admin", "User Agent")} />
        <.dm_input id={"llm-#{@api.api_surface}-client-version"} field={@form[:client_version]} label={dgettext("admin", "Client Version")} />
      </div>
      <div class="space-y-2">
        <div :for={protocol <- protocols(@provider, @api)}>
          <input type="hidden" name={@form[protocol].name} value="false" />
          <.dm_checkbox id={"llm-#{protocol}"} name={@form[protocol].name} value="true" label={protocol_label(protocol)} checked={selected?(@form, protocol)} />
        </div>
      </div>
      <div :if={@api.api_surface == :openai} class="space-y-2">
        <input type="hidden" name={@form[:responses_websocket].name} value="false" />
        <.dm_checkbox id={"llm-#{@api.api_surface}-responses-websocket"} name={@form[:responses_websocket].name} label="Responses WebSocket" value="true" checked={selected?(@form, :responses_websocket)} />
        <input type="hidden" name={@form[:responses_lifecycle].name} value="false" />
        <.dm_checkbox id={"llm-#{@api.api_surface}-responses-lifecycle"} name={@form[:responses_lifecycle].name} label="Responses lifecycle" value="true" checked={selected?(@form, :responses_lifecycle)} />
        <.dm_input id="llm-responses-route-ttl" field={@form[:responses_route_ttl_seconds]} type="number" label={dgettext("admin", "Responses route retention (seconds)")} min="60" max="2592000" />
      </div>
    </fieldset>
    """
  end
end
