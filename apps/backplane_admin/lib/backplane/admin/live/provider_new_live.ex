defmodule Backplane.Admin.ProviderNewLive do
  use Backplane.Admin, :live_view

  alias Backplane.LLM.{Provider, ProviderApi, ProviderPreset}
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
          {:noreply,
           socket
           |> put_flash(:info, "Provider #{provider.name} created")
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
               preset_key: preset.key,
               credential: params["credential"],
               rpm_limit: parse_optional_integer(params["rpm_limit"]),
               default_headers: decode_json_map(params["default_headers"])
             }),
           :ok <- create_api(provider.id, :openai, params),
           :ok <- create_api(provider.id, :anthropic, params) do
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

  defp create_api(provider_id, surface, params) do
    prefix = Atom.to_string(surface)

    if truthy?(params["#{prefix}_enabled"]) or not blank?(params["#{prefix}_base_url"]) do
      attrs = %{
        provider_id: provider_id,
        api_surface: surface,
        base_url: params["#{prefix}_base_url"],
        enabled: truthy?(params["#{prefix}_enabled"]),
        default_headers: decode_json_map(params["#{prefix}_default_headers"]),
        model_discovery_enabled: truthy?(params["#{prefix}_model_discovery_enabled"]),
        model_discovery_path: blank_to_nil(params["#{prefix}_model_discovery_path"])
      }

      case ProviderApi.create(attrs) do
        {:ok, _api} -> :ok
        {:error, changeset} -> {:error, prefixed_errors(prefix, changeset)}
      end
    else
      :ok
    end
  end

  defp form_for_preset(preset, params) do
    root = Map.get(params, "base_url", preset.default_base_url)

    params =
      %{
        "name" => preset.default_name,
        "credential" => "",
        "base_url" => root,
        "rpm_limit" => "",
        "default_headers" => "{}",
        "openai_enabled" => checkbox_value(preset.openai.enabled),
        "openai_base_url" => Map.get(params, "openai_base_url", preset.openai.base_url),
        "openai_model_discovery_enabled" => checkbox_value(!is_nil(preset.openai.discovery_path)),
        "openai_model_discovery_path" => preset.openai.discovery_path || "",
        "openai_default_headers" => "{}",
        "anthropic_enabled" => checkbox_value(preset.anthropic.enabled),
        "anthropic_base_url" => Map.get(params, "anthropic_base_url", preset.anthropic.base_url),
        "anthropic_model_discovery_enabled" =>
          checkbox_value(!is_nil(preset.anthropic.discovery_path)),
        "anthropic_model_discovery_path" => preset.anthropic.discovery_path || "",
        "anthropic_default_headers" => "{}"
      }
      |> Map.merge(params)

    to_form(params, as: :provider)
  end

  defp validate_params(preset, params) do
    %{}
    |> require_field(params, "name", "Name is required")
    |> require_field(params, "credential", "Credential is required")
    |> require_allowed_credential(preset, params)
    |> require_surface(params, "openai")
    |> require_surface(params, "anthropic")
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
      errors: %{}
    )
  end

  defp credential_options(preset) do
    creds = safe_call(fn -> Credentials.list() end, [])

    [
      {"", "Select a credential..."}
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
    "Credential must use #{auth_type} auth type"
  end

  defp credential_error(preset), do: "Credential must be a #{preset.credential_kind} credential"

  defp require_surface(errors, params, surface) do
    if truthy?(params["#{surface}_enabled"]) do
      require_field(
        errors,
        params,
        "#{surface}_base_url",
        "#{surface_label(surface)} base URL is required"
      )
    else
      errors
    end
  end

  defp require_field(errors, params, field, message) do
    if blank?(params[field]), do: Map.put(errors, field, message), else: errors
  end

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp truthy?(value) when value in [true, "true", "on", "1", 1], do: true
  defp truthy?(_), do: false

  defp checkbox_value(true), do: "true"
  defp checkbox_value(false), do: "false"

  defp surface_label("openai"), do: "OpenAI-compatible"
  defp surface_label("anthropic"), do: "Anthropic Messages"

  defp parse_optional_integer(value) when value in [nil, ""], do: nil

  defp parse_optional_integer(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      :error -> nil
    end
  end

  defp decode_json_map(value) when value in [nil, ""], do: %{}

  defp decode_json_map(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
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

  defp prefixed_errors(prefix, changeset) do
    changeset
    |> changeset_errors()
    |> Map.new(fn {field, message} -> {"#{prefix}_#{field}", message} end)
  end

  defp error(assigns) do
    ~H"""
    <div :if={@errors[@field]} class="mt-1 text-xs text-error">{@errors[@field]}</div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6 flex items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-bold">Add LLM Provider</h1>
          <p class="mt-1 text-sm text-on-surface-variant">
            Choose a provider preset, select a credential, then adjust OpenAI and Anthropic API surfaces.
          </p>
        </div>
        <.link navigate={~p"/llama/providers"} class="no-underline">
          <.dm_btn size="sm">Cancel</.dm_btn>
        </.link>
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
          <div class="text-xs opacity-80">{preset.default_base_url}</div>
        </button>
      </div>

      <.form for={@form} phx-submit="save" phx-change="validate" class="space-y-6">
        <.dm_card variant="bordered">
          <:title>Provider</:title>
          <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
            <div>
              <.dm_input
                id="provider-name"
                name="provider[name]"
                label="Name"
                value={@form[:name].value}
                placeholder="deepseek"
              />
              <.error errors={@errors} field="name" />
            </div>

            <div>
              <.dm_select
                id="provider-credential"
                name="provider[credential]"
                label="Credential"
                options={@credential_options}
                value={@form[:credential].value || ""}
              />
              <p class="mt-1 text-xs text-on-surface-variant">
                Select an LLM credential from the <.link
                  navigate={~p"/system/credentials"}
                  class="text-primary underline"
                >credential store</.link>.
              </p>
              <.error errors={@errors} field="credential" />
            </div>

            <div>
              <.dm_input
                id="provider-base-url"
                name="provider[base_url]"
                label="Base URL"
                value={@form[:base_url].value}
                placeholder={@selected_preset.default_base_url}
              />
            </div>

            <div>
              <.dm_input
                id="provider-rpm-limit"
                name="provider[rpm_limit]"
                label="RPM Limit"
                value={@form[:rpm_limit].value}
                placeholder="60"
              />
            </div>
          </div>
        </.dm_card>

        <div class="grid grid-cols-1 gap-4 xl:grid-cols-2">
          <.api_surface_section
            form={@form}
            errors={@errors}
            key="openai"
            title="OpenAI-compatible API"
            badge="OpenAI"
            description="Used by clients calling /api/v1."
          />

          <.api_surface_section
            form={@form}
            errors={@errors}
            key="anthropic"
            title="Anthropic Messages API"
            badge="Anthropic"
            description="Used by clients calling /api/anthropic."
          />
        </div>

        <.dm_card variant="bordered">
          <:title>Advanced Headers</:title>
          <.dm_textarea
            id="provider-default-headers"
            name="provider[default_headers]"
            label="Provider Default Headers"
            rows={3}
            value={@form[:default_headers].value}
            class="font-mono"
          />
        </.dm_card>

        <div class="flex gap-2">
          <.dm_btn type="submit" variant="primary">Create Provider</.dm_btn>
          <.link navigate={~p"/llama/providers"} class="no-underline">
            <.dm_btn type="button">Cancel</.dm_btn>
          </.link>
        </div>
      </.form>
    </div>
    """
  end

  defp api_surface_section(assigns) do
    ~H"""
    <.dm_card variant="bordered">
      <:title>
        <div class="flex items-center justify-between gap-3">
          <span>{@title}</span>
          <.dm_badge variant={if @key == "openai", do: "info", else: "tertiary"} size="sm">
            {@badge}
          </.dm_badge>
        </div>
      </:title>
      <p class="mb-4 text-sm text-on-surface-variant">{@description}</p>

      <div class="space-y-4">
        <input type="hidden" name={"provider[#{@key}_enabled]"} value="false" />
        <.dm_checkbox
          id={"provider-#{@key}-enabled"}
          name={"provider[#{@key}_enabled]"}
          label={"Enable #{surface_title(@key)}"}
          value="true"
          checked={field_value(@form, @key, "enabled") in [true, "true", "on"]}
        />

        <div>
          <.dm_input
            id={"provider-#{@key}-base-url"}
            name={"provider[#{@key}_base_url]"}
            label="Base URL"
            value={field_value(@form, @key, "base_url")}
          />
          <.error errors={@errors} field={"#{@key}_base_url"} />
        </div>

        <input type="hidden" name={"provider[#{@key}_model_discovery_enabled]"} value="false" />
        <.dm_checkbox
          id={"provider-#{@key}-discovery-enabled"}
          name={"provider[#{@key}_model_discovery_enabled]"}
          label="Enable model discovery"
          value="true"
          checked={field_value(@form, @key, "model_discovery_enabled") in [true, "true", "on"]}
        />

        <.dm_input
          id={"provider-#{@key}-discovery-path"}
          name={"provider[#{@key}_model_discovery_path]"}
          label="Model Discovery Path"
          value={field_value(@form, @key, "model_discovery_path")}
          placeholder={if @key == "openai", do: "/models", else: "/v1/models"}
        />

        <.dm_textarea
          id={"provider-#{@key}-default-headers"}
          name={"provider[#{@key}_default_headers]"}
          label="Default Headers"
          rows={3}
          value={field_value(@form, @key, "default_headers")}
          class="font-mono"
        />
      </div>
    </.dm_card>
    """
  end

  defp surface_title("openai"), do: "OpenAI-compatible API"
  defp surface_title("anthropic"), do: "Anthropic Messages API"

  defp field_value(form, key, suffix) do
    form[String.to_atom("#{key}_#{suffix}")].value
  end
end
