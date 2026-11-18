defmodule Backplane.Admin.ProviderNewLive do
  use Backplane.Admin, :live_view

  alias Backplane.LLM.{HostServices, Provider, ProviderApi, ProviderPreset}
  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  @default_preset "deepseek"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/llama/providers",
       presets: ProviderPreset.all(),
       selected_preset: ProviderPreset.fetch!(@default_preset),
       form: form_for_preset(ProviderPreset.fetch!(@default_preset), %{}),
       credential_options: [],
       host_service_options: [],
       errors: %{}
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    preset =
      ProviderPreset.get(params["preset"] || @default_preset) ||
        ProviderPreset.fetch!(@default_preset)

    {:noreply, assign_preset_form(socket, preset, socket.assigns[:form_params] || %{})}
  end

  @impl true
  def handle_event("select_preset", %{"preset" => key}, socket) do
    preset = ProviderPreset.get(key) || socket.assigns.selected_preset

    {:noreply, assign_preset_form(socket, preset, %{})}
  end

  def handle_event("validate", %{"provider" => params}, socket) do
    {:noreply,
     assign(socket,
       form: to_form(params, as: :provider),
       form_params: params,
       errors: validate_params(socket.assigns.selected_preset, params)
     )}
  end

  def handle_event("save", %{"provider" => params}, socket) do
    errors = validate_params(socket.assigns.selected_preset, params)

    if map_size(errors) > 0 do
      {:noreply,
       assign(socket, form: to_form(params, as: :provider), form_params: params, errors: errors)}
    else
      case create_provider(socket.assigns.selected_preset, params) do
        {:ok, provider} ->
          Backplane.Admin.Audit.record("provider.create", "provider", provider.id)

          {:noreply,
           socket
           |> put_flash(:info, dgettext("admin", "Provider %{name} created", name: provider.name))
           |> push_navigate(to: ~p"/llama/providers")}

        {:error, errors} ->
          {:noreply,
           assign(socket,
             form: to_form(params, as: :provider),
             form_params: params,
             errors: errors
           )}
      end
    end
  end

  defp create_provider(preset, params) do
    Repo.transaction(fn ->
      with {:ok, provider} <-
             Provider.create(%{
               name: params["name"],
               base_url: params["base_url"],
               preset_key: preset.key,
               credential: params["credential"],
               host_service_id: blank_to_nil(params["host_service_id"]),
               rpm_limit: parse_optional_integer(params["rpm_limit"])
             }),
           :ok <- create_apis(provider.id, preset, params) do
        provider
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          Repo.rollback(changeset_errors(changeset))

        {:error, reason} when is_map(reason) ->
          Repo.rollback(reason)

        {:error, reason} ->
          Repo.rollback(%{base: inspect(reason)})
      end
    end)
  end

  defp create_apis(provider_id, preset, params) do
    preset
    |> ProviderPreset.surfaces()
    |> Enum.reduce_while(:ok, fn {surface, _defaults}, :ok ->
      case create_api(provider_id, preset, surface, params) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp create_api(provider_id, preset, surface, params) do
    defaults = ProviderPreset.surfaces(preset)[surface]
    base_url = api_base_url(preset, defaults, params["base_url"])

    if not blank?(defaults.base_url) or defaults.enabled or
         (surface == :openai and not blank?(params["host_service_id"])) do
      attrs = %{
        provider_id: provider_id,
        api_surface: surface,
        native_protocols: [],
        base_url: base_url,
        enabled: true,
        default_headers: %{},
        model_discovery_enabled: false,
        model_discovery_path: nil,
        responses_websocket: false,
        backend_config: %{}
      }

      case ProviderApi.create(attrs) do
        {:ok, _api} -> :ok
        {:error, changeset} -> {:error, changeset_errors(changeset)}
      end
    else
      :ok
    end
  end

  defp form_for_preset(preset, params) do
    to_form(
      Map.merge(
        %{
          "name" => preset.default_name,
          "base_url" => preset.default_base_url,
          "credential" => "",
          "host_service_id" => "",
          "rpm_limit" => ""
        },
        params
      ),
      as: :provider
    )
  end

  defp api_base_url(preset, defaults, base_url) do
    cond do
      blank?(defaults.base_url) ->
        base_url

      preset.default_base_url != "" and
          String.starts_with?(defaults.base_url, preset.default_base_url) ->
        String.trim_trailing(base_url || "", "/") <>
          String.replace_prefix(defaults.base_url, preset.default_base_url, "")

      true ->
        defaults.base_url
    end
  end

  defp validate_params(preset, params) do
    %{}
    |> require_field(params, "name", dgettext("errors", "Name is required"))
    |> require_credential(params)
    |> require_allowed_credential(preset, params)
    |> require_base_url(params)
  end

  defp assign_preset_form(socket, preset, params) do
    credential_options = credential_options(preset)

    params =
      Map.put_new(
        params,
        "credential",
        default_credential(preset, credential_options)
      )

    assign(socket,
      selected_preset: preset,
      form: form_for_preset(preset, params),
      credential_options: credential_options,
      host_service_options: [{"", dgettext("admin", "Direct HTTP")} | HostServices.options()],
      errors: %{}
    )
  end

  defp credential_options(preset) do
    creds = safe_call(fn -> Credentials.list() end, [])

    [
      {"", dgettext("admin", "Select a credential...")}
      | creds
        |> Enum.filter(&credential_allowed?(preset, &1))
        |> Enum.map(fn cred -> {cred.name, credential_label(cred)} end)
    ]
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp credential_allowed?(preset, cred) do
    cred.kind == preset.credential_kind and credential_auth_type_allowed?(preset, cred)
  end

  defp credential_auth_type_allowed?(%{credential_auth_type: nil}, _cred), do: true

  defp credential_auth_type_allowed?(preset, cred) do
    credential_auth_type(cred) == preset.credential_auth_type
  end

  defp credential_auth_type(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "auth_type") || Map.get(metadata, :auth_type) || "api_key"
  end

  defp credential_auth_type(_cred), do: "api_key"

  defp credential_label(cred) do
    auth_type = credential_auth_type(cred)
    suffix = if auth_type == "api_key", do: cred.kind, else: auth_type

    "#{cred.name} (#{suffix})"
  end

  defp default_credential(%{default_credential: name}, options) when is_binary(name) do
    if Enum.any?(options, fn {value, _label} -> value == name end), do: name, else: ""
  end

  defp default_credential(_preset, _options), do: ""

  defp require_credential(errors, params) do
    if blank?(params["host_service_id"]),
      do:
        require_field(errors, params, "credential", dgettext("errors", "Credential is required")),
      else: errors
  end

  defp require_allowed_credential(errors, preset, params) do
    credential = params["credential"]

    if blank?(credential) do
      errors
    else
      allowed =
        safe_call(
          fn ->
            Credentials.list()
            |> Enum.any?(&(&1.name == credential and credential_allowed?(preset, &1)))
          end,
          false
        )

      if allowed do
        errors
      else
        Map.put(errors, "credential", credential_error(preset))
      end
    end
  end

  defp credential_error(%{credential_auth_type: auth_type}) when is_binary(auth_type) do
    dgettext("errors", "Credential must use %{auth_type} auth type", auth_type: auth_type)
  end

  defp credential_error(preset),
    do:
      dgettext("errors", "Credential must be a %{kind} credential", kind: preset.credential_kind)

  defp require_base_url(errors, params) do
    if blank?(params["host_service_id"]),
      do: require_field(errors, params, "base_url", dgettext("errors", "Base URL is required")),
      else: errors
  end

  defp require_field(errors, params, field, message) do
    if blank?(params[field]), do: Map.put(errors, field, message), else: errors
  end

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp parse_optional_integer(value) when value in [nil, ""], do: nil

  defp parse_optional_integer(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      :error -> nil
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Map.new(fn {key, messages} -> {Atom.to_string(key), Enum.join(messages, ", ")} end)
  end

  defp error(assigns) do
    ~H"""
    <div :if={@errors[@field]} class="mt-1 text-xs text-error">{@errors[@field]}</div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full min-w-0 max-w-7xl">
      <div class="mb-6 flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-bold">{dgettext("admin", "Add Provider")}</h1>
          <p class="mt-1 text-sm text-on-surface-variant">
            {dgettext("admin", "Choose a provider preset and configure its connection and credential. Configure conversation APIs separately in LLM.")}
          </p>
        </div>

        <.dm_btn navigate={~p"/llama/providers"} size="sm">{dgettext("common", "Cancel")}</.dm_btn>
      </div>

      <div class="mb-6 grid grid-cols-1 gap-3 md:grid-cols-3">
        <button
          :for={preset <- @presets}
          type="button"
          phx-click="select_preset"
          phx-value-preset={preset.key}
          class={[
            "rounded-md border p-4 text-left transition",
            if(@selected_preset.key == preset.key,
              do: "border-primary bg-primary-container text-on-primary-container",
              else: "border-outline-variant bg-surface-container text-on-surface hover:border-primary"
            )
          ]}
        >
          <div class="mb-2 flex items-center justify-between gap-2">
            <span class="font-semibold">{preset.name}</span>
            <span class="text-xs uppercase tracking-normal">{preset.key}</span>
          </div>
          <div class="truncate text-xs opacity-80" title={preset.default_base_url}>
            {preset.default_base_url}
          </div>
        </button>
      </div>

      <.form for={@form} id="provider-form" phx-submit="save" phx-change="validate" class="space-y-6">
        <.dm_card variant="bordered">
          <:title>{dgettext("admin", "Provider")}</:title>
          <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
            <div>
              <.dm_input
                id="provider-name"
                name="provider[name]"
                label={dgettext("common", "Name")}
                value={@form[:name].value}
                placeholder="deepseek"
              />
              <.error errors={@errors} field="name" />
            </div>

            <div>
              <.dm_select
                id="provider-credential"
                name="provider[credential]"
                label={dgettext("admin", "Credential")}
                options={@credential_options}
                value={@form[:credential].value || ""}
              />
              <p class="mt-1 text-xs text-on-surface-variant">
                {dgettext("admin", "Select an LLM credential from the")} <.link
                  navigate={~p"/system/credentials"}
                  class="text-primary underline"
                >{dgettext("admin", "credential store")}</.link>.
              </p>
              <.error errors={@errors} field="credential" />
            </div>

            <div>
              <.dm_select id="provider-host-service" name="provider[host_service_id]" label={dgettext("admin", "Host API Service")}
                options={@host_service_options} value={@form[:host_service_id].value || ""} />
              <p class="mt-1 text-xs text-on-surface-variant">{dgettext("admin", "Select Custom for host APIs. Endpoint URLs come from the service; credentials are optional for unauthenticated local services.")}</p>
              <.error errors={@errors} field="host_service_id" />
            </div>

            <div>
              <.dm_input
                id="provider-rpm-limit"
                name="provider[rpm_limit]"
                label={dgettext("admin", "RPM Limit")}
                value={@form[:rpm_limit].value}
                placeholder="60"
              />
            </div>
          </div>
        </.dm_card>

        <.dm_input id="provider-base-url" field={@form[:base_url]} label={dgettext("admin", "Base URL")} />
        <.error errors={@errors} field="base_url" />
        <p class="text-sm text-on-surface-variant">{dgettext("admin", "Default address for new API configurations. Configure protocol URLs and headers in LLM.")}</p>

        <div class="flex gap-2">
          <.dm_btn type="submit" variant="primary" phx-disable-with={dgettext("admin", "Creating…")}>{dgettext("admin", "Create Provider")}</.dm_btn>
          <.dm_btn navigate={~p"/llama/providers"}>{dgettext("common", "Cancel")}</.dm_btn>
        </div>
      </.form>
    </div>
    """
  end
end
