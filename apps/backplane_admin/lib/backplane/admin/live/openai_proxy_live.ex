defmodule Backplane.Admin.OpenAIProxyLive do
  use Backplane.Admin, :live_view

  alias Backplane.Admin.Audit
  alias Backplane.LLM.OpenAI.Service
  alias Backplane.LLM.Provider
  alias Backplane.Settings.Credentials

  @pages %{
    decisions: %{
      title: "OpenAI Decisions",
      description:
        "Route classification, choice and scoring requests to an explicitly configured model.",
      endpoints: ["POST /v1/decisions"],
      example: "gpt-6-luna"
    },
    images: %{
      title: "OpenAI Images",
      description: "Configure native image generation and editing, including image uploads.",
      endpoints: ["POST /v1/images/generations", "POST /v1/images/edits"],
      example: "Enter the image model IDs available to your account"
    },
    speech: %{
      title: "OpenAI Text to Speech",
      description: "Configure the native Speech API and its audio or event stream output.",
      endpoints: ["POST /v1/audio/speech"],
      example: "Enter the Speech API model IDs available to your account"
    },
    transcription: %{
      title: "OpenAI Transcription",
      description: "Configure recorded-audio uploads and native transcription results or events.",
      endpoints: ["POST /v1/audio/transcriptions"],
      example: "gpt-transcribe"
    },
    realtime: %{
      title: "OpenAI Realtime",
      description: "Configure bidirectional WebSocket sessions and browser WebRTC setup.",
      endpoints: [
        "GET /v1/realtime (WebSocket)",
        "POST /v1/realtime/calls",
        "POST /v1/realtime/client_secrets"
      ],
      example: "gpt-realtime-2.1"
    }
  }

  @limits ~w(request_timeout_ms max_request_bytes max_response_bytes max_session_ms)

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(_params, _uri, socket) do
    kind = socket.assigns.live_action

    {:noreply,
     socket
     |> assign(
       kind: kind,
       page: Map.fetch!(@pages, kind),
       current_path: "/llama/openai/#{kind}",
       editing_id: nil,
       modal_open: false,
       errors: [],
       form: to_form(defaults(), as: :service)
     )
     |> load()}
  end

  @impl true
  def handle_event("add", _params, socket) do
    {:noreply, socket |> reset_form() |> assign(modal_open: true) |> load()}
  end

  def handle_event("save", %{"service" => params}, socket) do
    attrs =
      params
      |> Map.take(~w(provider_id default_model) ++ @limits)
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
         |> put_flash(:info, "API proxy configuration saved")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           form: to_form(params, as: :service),
           errors: errors(changeset)
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Configuration is no longer available")}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case scoped_service(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Configuration not found")}

      service ->
        values =
          defaults()
          |> Map.merge(Map.new(@limits, &{&1, Map.get(service, String.to_existing_atom(&1))}))
          |> Map.merge(%{
            "provider_id" => service.provider_id,
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
      {:noreply, socket |> reset_form() |> load() |> put_flash(:info, "Configuration deleted")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Configuration could not be deleted")}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with %Service{} = service <- scoped_service(socket, id),
         {:ok, _} <- Service.update(service, %{enabled: not service.enabled}) do
      Audit.record("openai_service.toggle", "openai_service", id)
      {:noreply, load(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Configuration could not be changed")}
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
      providers: providers,
      provider_options: [{"", "Select a provider"} | Enum.map(providers, &{&1.id, &1.name})]
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
      form: to_form(defaults(), as: :service)
    )
  end

  defp defaults do
    %{
      "provider_id" => "",
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

  defp endpoint(provider) do
    case Enum.find(provider.apis, &(&1.api_surface == :openai)) do
      nil -> "OpenAI API unavailable"
      api -> api.base_url
    end
  end

  defp available_api?(providers, provider_id) do
    Enum.any?(providers, fn provider ->
      provider.id == provider_id and
        Enum.any?(provider.apis, &(&1.api_surface == :openai and &1.enabled))
    end)
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
        <.dm_btn id="add-openai-service" type="button" variant="primary" phx-click={JS.push("add") |> JS.push_focus()}>
          Add
        </.dm_btn>
      </div>

      <.dm_alert :if={@kind == :speech} variant="warning" id="speech-deprecation">
        OpenAI lists tts-1, tts-1-hd and gpt-4o-mini-tts for shutdown on January 6, 2027.
        Configure Realtime separately for the replacement workflow.
      </.dm_alert>

      <.dm_card variant="bordered">
        <:title>Configured routes</:title>
        <p :if={@services == []} id="openai-services-empty" class="text-sm text-on-surface-variant">
          No routes configured for this API. Click Add to select a provider and allowed models.
        </p>
        <div :if={@services != []} class="overflow-x-auto">
          <.dm_table style="min-width: 42rem" id="openai-services-table" data={@services} hover zebra>
            <:col :let={service} label="Provider">
              <div class="font-medium">{service.provider.name}</div>
              <div class="text-xs text-on-surface-variant">Credential: {service.provider.credential}</div>
            </:col>
            <:col :let={service} label="Models">
              <code :for={model <- service.models} class="block text-xs">
                {service.provider.name}/{model}
              </code>
              <p :if={service.default_model} class="mt-1 text-xs text-on-surface-variant">
                Default: {service.default_model}
              </p>
            </:col>
            <:col :let={service} label="Status">
              <.dm_badge variant={if service.enabled, do: "success", else: "neutral"}>
                {if service.enabled, do: "Enabled", else: "Disabled"}
              </.dm_badge>
              <p :if={not service.provider.enabled} class="mt-1 text-xs text-on-surface-variant">
                Provider disabled
              </p>
              <p :if={not available_api?(@providers, service.provider_id)} class="mt-1 text-xs text-on-surface-variant">
                OpenAI API or credential unavailable
              </p>
            </:col>
            <:col :let={service} label="Actions">
              <div class="flex items-center gap-1">
                <.dm_tooltip :let={tooltip_attrs} content="Edit" position="bottom">
                  <.dm_btn {tooltip_attrs}
                    id={"edit-service-#{service.id}"}
                    type="button"
                    size="xs"
                    shape="circle"
                    variant="outline"
                    aria-label={"Edit #{service.provider.name} route"}
                    phx-click={JS.push("edit", value: %{id: service.id}) |> JS.push_focus()}
                  >
                    <.dm_mdi name="pencil" class="h-4 w-4" />
                    <span class="sr-only">Edit</span>
                  </.dm_btn>
                </.dm_tooltip>
                <.dm_tooltip :let={tooltip_attrs} content={if service.enabled, do: "Disable", else: "Enable"} position="bottom">
                  <.dm_btn {tooltip_attrs}
                    id={"toggle-service-#{service.id}"}
                    type="button"
                    size="xs"
                    shape="circle"
                    variant="ghost"
                    aria-label={"#{if service.enabled, do: "Disable", else: "Enable"} #{service.provider.name} route"}
                    phx-click="toggle"
                    phx-value-id={service.id}
                  >
                    <.dm_mdi name={if service.enabled, do: "pause", else: "play"} class="h-4 w-4" />
                    <span class="sr-only">{if service.enabled, do: "Disable", else: "Enable"}</span>
                  </.dm_btn>
                </.dm_tooltip>
                <.dm_tooltip :let={tooltip_attrs} content="Delete" position="bottom">
                  <.dm_btn {tooltip_attrs}
                    id={"delete-service-#{service.id}"}
                    type="button"
                    size="xs"
                    shape="circle"
                    variant="error"
                    aria-label={"Delete #{service.provider.name} route"}
                    phx-click="delete"
                    phx-value-id={service.id}
                    data-confirm="Delete this API proxy configuration?"
                  >
                    <.dm_mdi name="delete" class="h-4 w-4" />
                    <span class="sr-only">Delete</span>
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
        <:title>{if @editing_id, do: "Edit route", else: "Add route"}</:title>
        <:body>
          <p class="mb-4 text-sm text-on-surface-variant">
            The provider owns the API endpoint and credential. Each API has its own allowed models and enablement.
            <.link navigate={~p"/llama/providers"} class="text-primary underline">Manage providers</.link>
          </p>
          <.dm_alert :if={@providers == []} variant="info">
            Add a provider with an OpenAI API surface and an API-key credential first.
          </.dm_alert>
          <div :if={@errors != []} id="openai-service-errors" role="alert" class="mb-4 text-sm text-error">
            <p :for={error <- @errors}>{error}</p>
          </div>
          <.form for={@form} id="openai-service-form" phx-submit="save" class="space-y-4">
            <.dm_select field={@form[:provider_id]} label="Provider" options={@provider_options} autofocus />
            <.dm_textarea field={@form[:models_text]} label="Allowed model IDs (one per line)" placeholder={@page.example} rows={3} />
            <.dm_input field={@form[:default_model]} label="Default model (optional)" />
            <p class="text-xs text-on-surface-variant">
              Send provider/model to select a route explicitly. An omitted model requires an unambiguous configured default.
            </p>
            <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
              <.dm_input field={@form[:request_timeout_ms]} type="number" label="Request timeout (ms)" min="1000" />
              <.dm_input field={@form[:max_request_bytes]} type="number" label="Maximum upload (bytes)" min="1024" />
              <.dm_input field={@form[:max_response_bytes]} type="number" label="Maximum output (bytes)" min="1024" />
              <.dm_input :if={@kind == :realtime} field={@form[:max_session_ms]} type="number" label="Session lifetime (ms)" min="1000" />
            </div>
            <p :if={@kind == :realtime} class="text-xs text-on-surface-variant">
              Upload and output limits apply to cumulative WebSocket traffic per session. WebRTC media travels directly to OpenAI.
              Request timeout applies to HTTP setup; WebSocket connection and write deadlines are fixed.
            </p>
            <input :if={@kind != :realtime} type="hidden" name="service[max_session_ms]" value={@form[:max_session_ms].value} />
            <div class="flex gap-2">
              <.dm_btn type="submit" variant="primary">Save configuration</.dm_btn>
              <.dm_btn id="cancel-openai-service" type="button" variant="ghost" command="close" commandfor="openai-service-modal">Cancel</.dm_btn>
            </div>
          </.form>
        </:body>
      </.dm_modal>

      <.dm_card :if={@providers != []} variant="bordered">
        <:title>Provider connections</:title>
        <div :for={provider <- @providers} class="mb-3 text-sm">
          <span class="font-medium">{provider.name}</span>
          <span class="text-on-surface-variant"> · {provider.credential}</span>
          <code class="mt-1 block break-all text-xs">{endpoint(provider)}</code>
        </div>
      </.dm_card>
    </div>
    """
  end
end
