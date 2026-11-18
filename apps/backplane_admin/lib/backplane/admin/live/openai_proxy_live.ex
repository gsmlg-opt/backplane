defmodule Backplane.Admin.OpenAIProxyLive do
  use Backplane.Admin, :live_view

  alias Backplane.Admin.Audit
  alias Backplane.LLM.OpenAI.Service
  alias Backplane.LLM.{Provider, ProviderApi}
  alias Backplane.Settings.Credentials

  defp page(:decisions) do
    %{
      title: dgettext("admin", "OpenAI Decisions"),
      description:
        dgettext(
          "admin",
          "Route classification, choice and scoring requests to an explicitly configured model."
        ),
      endpoints: ["POST /v1/decisions"],
      example: "gpt-6-luna"
    }
  end

  defp page(:images) do
    %{
      title: dgettext("admin", "OpenAI Images"),
      description:
        dgettext(
          "admin",
          "Configure native image generation and editing, including image uploads."
        ),
      endpoints: ["POST /v1/images/generations", "POST /v1/images/edits"],
      example: dgettext("admin", "Enter the image model IDs available to your account")
    }
  end

  defp page(:speech) do
    %{
      title: dgettext("admin", "OpenAI Text to Speech"),
      description:
        dgettext(
          "admin",
          "Configure the native Speech API and its audio or event stream output."
        ),
      endpoints: ["POST /v1/audio/speech"],
      example: dgettext("admin", "Enter the Speech API model IDs available to your account")
    }
  end

  defp page(:transcription) do
    %{
      title: dgettext("admin", "OpenAI Transcription"),
      description:
        dgettext(
          "admin",
          "Configure recorded-audio uploads and native transcription results or events."
        ),
      endpoints: ["POST /v1/audio/transcriptions"],
      example: "gpt-transcribe"
    }
  end

  defp page(:realtime) do
    %{
      title: dgettext("admin", "OpenAI Realtime"),
      description:
        dgettext(
          "admin",
          "Configure bidirectional WebSocket sessions and browser WebRTC setup."
        ),
      endpoints: [
        "GET /v1/realtime (WebSocket)",
        "POST /v1/realtime/calls",
        "POST /v1/realtime/client_secrets"
      ],
      example: "gpt-realtime-2.1"
    }
  end

  defp page(:embeddings) do
    %{
      title: dgettext("admin", "Embeddings"),
      description:
        dgettext("admin", "Configure embedding APIs using an existing provider connection."),
      endpoints: ["POST /v1/embeddings"],
      example: "text-embedding-3-small"
    }
  end

  @limits ~w(request_timeout_ms max_request_bytes max_response_bytes max_session_ms)
  @policy ~w(model_policy image_generation_enabled image_edit_enabled)

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(_params, _uri, socket) do
    kind = socket.assigns.live_action

    {:noreply,
     socket
     |> assign(
       kind: kind,
       page: page(kind),
       current_path:
         if(kind == :embeddings, do: "/llama/embedding", else: "/llama/openai/#{kind}"),
       editing_id: nil,
       modal_open: false,
       errors: [],
       form: to_form(defaults(kind), as: :service)
     )
     |> load()}
  end

  @impl true
  def handle_event("add", _params, socket) do
    {:noreply, socket |> reset_form() |> assign(modal_open: true) |> load()}
  end

  def handle_event("validate", %{"service" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :service))}
  end

  def handle_event("save", %{"service" => params}, socket) do
    attrs =
      params
      |> Map.take(~w(provider_id default_model) ++ @limits ++ @policy)
      |> Map.put("kind", to_string(socket.assigns.kind))
      |> Map.put("models", split_models(params["models_text"]))

    result =
      case scoped_service(socket, socket.assigns.editing_id) do
        nil when is_nil(socket.assigns.editing_id) -> Service.create(attrs)
        nil -> {:error, :not_found}
        service -> Service.update(service, attrs)
      end

    case result do
      {:ok, service} ->
        action = if socket.assigns.editing_id, do: "update", else: "create"
        Audit.record("openai_service.#{action}", "openai_service", service.id)

        {:noreply,
         socket
         |> reset_form()
         |> load()
         |> put_flash(:info, dgettext("admin", "API proxy configuration saved"))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           form: to_form(params, as: :service),
           errors: errors(changeset)
         )}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, dgettext("errors", "Configuration is no longer available"))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case scoped_service(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Configuration not found"))}

      service ->
        values =
          defaults(socket.assigns.kind)
          |> Map.merge(Map.new(@limits, &{&1, Map.get(service, String.to_existing_atom(&1))}))
          |> Map.merge(%{
            "provider_id" => service.provider_id,
            "model_policy" => to_string(service.model_policy),
            "image_generation_enabled" => service.image_generation_enabled,
            "image_edit_enabled" => service.image_edit_enabled,
            "models_text" => Enum.join(service.models, "\n"),
            "default_model" => service.default_model || ""
          })

        {:noreply,
         assign(socket,
           editing_id: service.id,
           modal_open: true,
           form: to_form(values, as: :service),
           errors: []
         )}
    end
  end

  def handle_event("cancel", _params, socket), do: {:noreply, reset_form(socket)}

  def handle_event("delete", %{"id" => id}, socket) do
    with %Service{} = service <- scoped_service(socket, id),
         {:ok, _} <- Service.delete(service) do
      Audit.record("openai_service.delete", "openai_service", id)

      {:noreply,
       socket
       |> reset_form()
       |> load()
       |> put_flash(:info, dgettext("admin", "Configuration deleted"))}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, dgettext("errors", "Configuration could not be deleted"))}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with %Service{} = service <- scoped_service(socket, id),
         {:ok, _} <- Service.update(service, %{enabled: not service.enabled}) do
      Audit.record("openai_service.toggle", "openai_service", id)
      {:noreply, load(socket)}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, dgettext("errors", "Configuration could not be changed"))}
    end
  end

  defp load(socket) do
    credentials = Map.new(Credentials.list(), &{&1.name, &1})

    providers =
      Provider.list()
      |> Enum.filter(fn provider ->
        credential = credentials[provider.credential]

        is_nil(provider.host_service_id) and credential != nil and
          credential.kind in ["llm", "service"] and
          Map.get(credential.metadata || %{}, "auth_type") in [nil, "api_key"] and
          Enum.any?(provider.apis, &(&1.api_surface == :openai))
      end)

    assign(socket,
      services: Service.list(socket.assigns.kind),
      legacy_providers:
        if(socket.assigns.kind == :embeddings,
          do: Enum.filter(Backplane.Embedding.list_providers(), &is_nil(&1.llm_provider_id)),
          else: []
        ),
      providers: providers,
      provider_options: [
        {"", dgettext("admin", "Select a provider")} | Enum.map(providers, &{&1.id, &1.name})
      ]
    )
  end

  defp scoped_service(_socket, nil), do: nil

  defp scoped_service(socket, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Service{kind: kind} = service <- Service.get(id),
         true <- kind == socket.assigns.kind do
      service
    else
      _ -> nil
    end
  end

  defp reset_form(socket) do
    assign(socket,
      modal_open: false,
      editing_id: nil,
      errors: [],
      form: to_form(defaults(socket.assigns.kind), as: :service)
    )
  end

  defp defaults(_kind) do
    %{
      "provider_id" => "",
      "model_policy" => "passthrough",
      "image_generation_enabled" => true,
      "image_edit_enabled" => true,
      "models_text" => "",
      "default_model" => "",
      "request_timeout_ms" => "120000",
      "max_request_bytes" => "50000000",
      "max_response_bytes" => "100000000",
      "max_session_ms" => "3600000"
    }
  end

  defp split_models(value) when is_binary(value) do
    value |> String.split(~r/[\r\n,]+/, trim: true) |> Enum.map(&String.trim/1) |> Enum.uniq()
  end

  defp split_models(_), do: []

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, text ->
        if is_binary(value) or is_number(value),
          do: String.replace(text, "%{#{key}}", to_string(value)),
          else: text
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
  end

  defp status(service) do
    api =
      Enum.find(ProviderApi.list_for_provider(service.provider_id), &(&1.api_surface == :openai))

    cond do
      not service.enabled ->
        dgettext("admin", "Disabled")

      not is_nil(service.provider.deleted_at) ->
        dgettext("admin", "Provider deleted")

      not service.provider.enabled ->
        dgettext("admin", "Provider disabled")

      is_nil(api) ->
        dgettext("admin", "OpenAI API unavailable")

      not api.enabled ->
        dgettext("admin", "OpenAI API disabled")

      not Service.eligible_provider?(service.provider) ->
        dgettext("admin", "API-key credential or direct connection required")

      true ->
        dgettext("admin", "Configured")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full min-w-0 max-w-7xl space-y-6">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 class="text-3xl font-bold">{@page.title}</h1>
          <p class="mt-2 text-sm text-on-surface-variant">{@page.description}</p>
          <div class="mt-3 flex flex-wrap gap-2">
            <code :for={endpoint <- @page.endpoints} class="text-xs">{endpoint}</code>
          </div>
        </div>
        <div class="flex flex-wrap gap-2">
          <.dm_btn
            :if={@kind == :embeddings}
            id="manage-embedding-connections"
            navigate={~p"/llama/embedding/connections"}
            variant="outline"
          >
            {dgettext("admin", "Manage embedding connections")}
          </.dm_btn>
          <.dm_btn id="add-openai-service" type="button" variant="primary" phx-click={JS.push("add") |> JS.push_focus()}>
            {dgettext("common", "Add")}
          </.dm_btn>
        </div>
      </div>

      <.dm_alert :if={@kind == :speech} variant="warning" id="speech-deprecation">
        {dgettext(
          "admin",
          "OpenAI lists tts-1, tts-1-hd and gpt-4o-mini-tts for shutdown on January 6, 2027. Configure Realtime separately for the replacement workflow."
        )}
      </.dm_alert>

      <.dm_card variant="bordered">
        <:title>{dgettext("admin", "Configured routes")}</:title>
        <p :if={@services == []} id="openai-services-empty" class="text-sm text-on-surface-variant">
          {dgettext("admin", "No routes configured for this API. Click Add to select a provider. Models can be supplied by clients.")}
        </p>
        <div :if={@services != []} class="overflow-x-auto">
          <.dm_table style="min-width: 42rem" id="openai-services-table" data={@services} hover zebra>
            <:col :let={service} label={dgettext("admin", "Provider")}>
              <div class="break-all font-medium">{service.provider.name}</div>
              <div class="break-all text-xs text-on-surface-variant">{dgettext("admin", "Credential: %{name}", name: service.provider.credential)}</div>
            </:col>
            <:col :let={service} label={dgettext("admin", "Models")}>
              <p :if={service.model_policy == :passthrough} class="text-sm">{dgettext("admin", "Client-supplied model")}</p>
              <code :if={service.model_policy == :allowlist} :for={model <- service.models} class="block break-all text-xs">
                {service.provider.name}/{model}
              </code>
              <p :if={service.default_model} class="mt-1 text-xs text-on-surface-variant">
                {dgettext("admin", "Default: %{model}", model: service.default_model)}
              </p>
            </:col>
            <:col :let={service} label={dgettext("common", "Status")}>
              <.dm_badge variant={if status(service) == dgettext("admin", "Configured"), do: "info", else: "neutral"}>
                {status(service)}
              </.dm_badge>
              <p :if={service.kind == :images} class="mt-1 text-xs text-on-surface-variant">
                {dgettext("admin", "Generation: %{state}", state: if(service.image_generation_enabled, do: "On", else: "Off"))}
                · {dgettext("admin", "Edit: %{state}", state: if(service.image_edit_enabled, do: "On", else: "Off"))}
              </p>
            </:col>
            <:col :let={service} label={dgettext("common", "Actions")}>
              <div class="flex items-center gap-1">
                <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Edit")} position="bottom">
                  <.dm_btn {tooltip_attrs}
                    id={"edit-service-#{service.id}"}
                    type="button"
                    size="xs"
                    shape="circle"
                    variant="outline"
                    aria-label={dgettext("admin", "Edit %{name} route", name: service.provider.name)}
                    phx-click={JS.push("edit", value: %{id: service.id}) |> JS.push_focus()}
                  >
                    <.dm_mdi name="pencil" class="h-4 w-4" />
                    <span class="sr-only">{dgettext("common", "Edit")}</span>
                  </.dm_btn>
                </.dm_tooltip>
                <.dm_tooltip :let={tooltip_attrs} content={
                    if service.enabled,
                      do: dgettext("common", "Disable"),
                      else: dgettext("common", "Enable")
                  } position="bottom">
                  <.dm_btn {tooltip_attrs}
                    id={"toggle-service-#{service.id}"}
                    type="button"
                    size="xs"
                    shape="circle"
                    variant="ghost"
                    aria-label={
                      if service.enabled,
                        do: dgettext("admin", "Disable %{name} route", name: service.provider.name),
                        else: dgettext("admin", "Enable %{name} route", name: service.provider.name)
                    }
                    phx-click="toggle"
                    phx-value-id={service.id}
                  >
                    <.dm_mdi name={if service.enabled, do: "pause", else: "play"} class="h-4 w-4" />
                    <span class="sr-only">
                      {if service.enabled,
                        do: dgettext("common", "Disable"),
                        else: dgettext("common", "Enable")}
                    </span>
                  </.dm_btn>
                </.dm_tooltip>
                <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Delete")} position="bottom">
                  <.dm_btn {tooltip_attrs}
                    id={"delete-service-#{service.id}"}
                    type="button"
                    size="xs"
                    shape="circle"
                    variant="error"
                    aria-label={dgettext("admin", "Delete %{name} route", name: service.provider.name)}
                    phx-click="delete"
                    phx-value-id={service.id}
                    data-confirm={dgettext("admin", "Delete this API proxy configuration?")}
                  >
                    <.dm_mdi name="delete" class="h-4 w-4" />
                    <span class="sr-only">{dgettext("common", "Delete")}</span>
                  </.dm_btn>
                </.dm_tooltip>
              </div>
            </:col>
          </.dm_table>
        </div>
      </.dm_card>

      <.dm_modal
        :if={@modal_open}
        id="openai-service-modal"
        size="xl"
        phx-hook="OpenAIServiceModal"
        phx-remove={JS.pop_focus()}
      >
        <:title>
          {if @editing_id,
            do: dgettext("admin", "Edit route"),
            else: dgettext("admin", "Add route")}
        </:title>
        <:body>
          <p class="mb-4 text-sm text-on-surface-variant">
            {dgettext("admin", "The provider owns the API endpoint and credential. API enablement and optional model restrictions are configured here.")}
            <.link navigate={~p"/llama/providers"} class="text-primary underline">{dgettext("admin", "Manage providers")}</.link>
          </p>
          <.dm_alert :if={@providers == []} variant="info">
            {dgettext("admin", "Add a provider with an OpenAI API surface and an API-key credential first.")}
          </.dm_alert>
          <div :if={@errors != []} id="openai-service-errors" role="alert" class="mb-4 text-sm text-error">
            <p :for={error <- @errors}>{error}</p>
          </div>
          <.form for={@form} id="openai-service-form" phx-submit="save" phx-change="validate" class="space-y-4">
            <.dm_select field={@form[:provider_id]} label={dgettext("admin", "Provider")} options={@provider_options} autofocus />
            <div :if={@kind == :images} class="grid grid-cols-1 gap-3 sm:grid-cols-2">
              <.dm_checkbox field={@form[:image_generation_enabled]} label={dgettext("admin", "Image Generation")} />
              <.dm_checkbox field={@form[:image_edit_enabled]} label={dgettext("admin", "Image Edit")} />
            </div>
            <p class="text-sm text-on-surface-variant">
              {dgettext("admin", "Clients supply the model. No conversation model registration is required. Configured status does not verify upstream account access.")}
            </p>
            <details id="openai-service-advanced" phx-mounted={JS.ignore_attributes(["open"])} class="rounded-md border border-outline-variant p-3">
              <summary class="cursor-pointer font-medium">{dgettext("admin", "Advanced API settings")}</summary>
              <div class="mt-3 space-y-4">
                <.dm_select field={@form[:model_policy]} label={dgettext("admin", "Model policy")} options={[
                  {"passthrough", dgettext("admin", "Use the client's model")},
                  {"allowlist", dgettext("admin", "Restrict to allowed models")}
                ]} />
                <.dm_textarea field={@form[:models_text]} label={dgettext("admin", "Allowed model IDs (one per line)")} placeholder={@page.example} rows={3} />
                <.dm_input field={@form[:default_model]} label={dgettext("admin", "Default model (optional)")} />
                <p class="text-xs text-on-surface-variant">{dgettext("admin", "Send provider/model to select a route explicitly. An omitted model requires an unambiguous configured default.")}</p>
                <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
                  <.dm_input field={@form[:request_timeout_ms]} type="number" label={dgettext("admin", "Request timeout (ms)")} min="1000" />
                  <.dm_input field={@form[:max_request_bytes]} type="number" label={dgettext("admin", "Maximum upload (bytes)")} min="1" />
                  <.dm_input field={@form[:max_response_bytes]} type="number" label={dgettext("admin", "Maximum output (bytes)")} min="1" />
                  <.dm_input :if={@kind == :realtime} field={@form[:max_session_ms]} type="number" label={dgettext("admin", "Session lifetime (ms)")} min="1000" />
                </div>
                <p :if={@kind == :realtime} class="text-xs text-on-surface-variant">{dgettext("admin", "Traffic limits apply cumulatively to WebSocket sessions. WebRTC media travels directly to OpenAI.")}</p>
              </div>
            </details>
            <div class="flex gap-2">
              <.dm_btn type="submit" variant="primary" phx-disable-with={dgettext("admin", "Saving…")}>{dgettext("admin", "Save configuration")}</.dm_btn>
              <.dm_btn id="cancel-openai-service" type="button" variant="ghost" command="close" commandfor="openai-service-modal">{dgettext("common", "Cancel")}</.dm_btn>
            </div>
          </.form>
        </:body>
      </.dm_modal>

      <.dm_card :if={@legacy_providers != []} variant="bordered">
        <:title>{dgettext("admin", "Existing embedding connections")}</:title>
        <p class="mb-3 text-sm text-on-surface-variant">{dgettext("admin", "These existing connections retain their model and Host Agent routing.")}</p>
        <div class="overflow-x-auto">
          <.dm_table id="legacy-embedding-models-table" data={@legacy_providers}>
            <:col :let={provider} label={dgettext("admin", "Provider")}><span class="break-all">{provider.name}</span></:col>
            <:col :let={provider} label={dgettext("admin", "Models")}><code :for={model <- provider.models} class="block break-all text-xs">{provider.name}/{model.model}</code></:col>
            <:col :let={provider} label={dgettext("common", "Status")}>{if provider.enabled, do: dgettext("admin", "Enabled"), else: dgettext("admin", "Disabled")}</:col>
          </.dm_table>
        </div>
      </.dm_card>
    </div>
    """
  end
end
