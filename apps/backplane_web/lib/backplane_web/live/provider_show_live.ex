defmodule BackplaneWeb.ProviderShowLive do
  use BackplaneWeb, :live_view

  alias Backplane.LLM.{
    ModelDiscovery,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface
  }

  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/providers",
       provider: nil,
       credential_options: [],
       provider_form: to_form(%{}, as: :provider),
       provider_errors: %{},
       model_form: to_form(model_defaults(), as: :model),
       model_errors: %{},
       editing_model: nil,
       edit_model_form: nil,
       edit_model_errors: %{}
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Provider.get(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Provider not found")
         |> push_navigate(to: ~p"/admin/providers")}

      provider ->
        {:noreply,
         socket
         |> assign_provider(provider)
         |> load_credentials()}
    end
  end

  @impl true
  def handle_event("validate_provider", %{"provider" => params}, socket) do
    {:noreply,
     assign(socket,
       provider_form: to_form(params, as: :provider),
       provider_errors: validate_provider_params(params)
     )}
  end

  def handle_event("save_provider", %{"provider" => params}, socket) do
    errors = validate_provider_params(params)

    if map_size(errors) > 0 do
      {:noreply,
       assign(socket,
         provider_form: to_form(params, as: :provider),
         provider_errors: errors
       )}
    else
      case update_provider(socket.assigns.provider, params) do
        {:ok, provider} ->
          {:noreply,
           socket
           |> put_flash(:info, "Provider updated")
           |> assign_provider(provider)}

        {:error, errors} ->
          {:noreply,
           assign(socket,
             provider_form: to_form(params, as: :provider),
             provider_errors: errors
           )}
      end
    end
  end

  def handle_event("reload_models", _params, socket) do
    provider = socket.assigns.provider

    result =
      provider
      |> then(&Provider.get(&1.id))
      |> ModelDiscovery.reload_provider()

    socket =
      if result.errors == [] do
        put_flash(
          socket,
          :info,
          "Reloaded #{result.discovered} model(s): #{result.created} new, #{result.updated} updated"
        )
      else
        put_flash(
          socket,
          :error,
          "Model reload finished with errors: #{Enum.join(result.errors, "; ")}"
        )
      end

    {:noreply, assign_provider(socket, Provider.get(provider.id))}
  end

  def handle_event("validate_model", %{"model" => params}, socket) do
    {:noreply,
     assign(socket,
       model_form: to_form(params, as: :model),
       model_errors: validate_model_params(socket.assigns.provider, params)
     )}
  end

  def handle_event("add_model", %{"model" => params}, socket) do
    provider = socket.assigns.provider
    errors = validate_model_params(provider, params)

    if map_size(errors) > 0 do
      {:noreply,
       assign(socket,
         model_form: to_form(params, as: :model),
         model_errors: errors
       )}
    else
      case create_model(provider, params) do
        {:ok, _model} ->
          {:noreply,
           socket
           |> put_flash(:info, "Model added")
           |> assign_provider(Provider.get(provider.id))
           |> assign(model_form: to_form(model_defaults(), as: :model), model_errors: %{})}

        {:error, errors} ->
          {:noreply,
           assign(socket,
             model_form: to_form(params, as: :model),
             model_errors: errors
           )}
      end
    end
  end

  def handle_event("edit_model", %{"id" => id}, socket) do
    provider = socket.assigns.provider

    case model_for_provider(provider, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Model not found")}

      model ->
        {:noreply,
         assign(socket,
           editing_model: model,
           edit_model_form: to_form(model_params(provider, model), as: :model),
           edit_model_errors: %{}
         )}
    end
  end

  def handle_event("cancel_edit_model", _params, socket) do
    {:noreply, assign(socket, editing_model: nil, edit_model_form: nil, edit_model_errors: %{})}
  end

  def handle_event("validate_edit_model", %{"model" => params}, socket) do
    {:noreply,
     assign(socket,
       edit_model_form: to_form(params, as: :model),
       edit_model_errors: validate_model_params(socket.assigns.provider, params)
     )}
  end

  def handle_event("update_model", %{"model" => params}, socket) do
    provider = socket.assigns.provider
    errors = validate_model_params(provider, params)

    if map_size(errors) > 0 do
      {:noreply,
       assign(socket,
         edit_model_form: to_form(params, as: :model),
         edit_model_errors: errors
       )}
    else
      case update_model(socket.assigns.editing_model, provider, params) do
        {:ok, _model} ->
          {:noreply,
           socket
           |> put_flash(:info, "Model updated")
           |> assign_provider(Provider.get(provider.id))
           |> assign(editing_model: nil, edit_model_form: nil, edit_model_errors: %{})}

        {:error, errors} ->
          {:noreply,
           assign(socket,
             edit_model_form: to_form(params, as: :model),
             edit_model_errors: errors
           )}
      end
    end
  end

  def handle_event("toggle_model", %{"id" => id}, socket) do
    provider = socket.assigns.provider

    case model_for_provider(provider, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Model not found")}

      model ->
        case ProviderModel.update(model, %{enabled: !model.enabled}) do
          {:ok, _updated} ->
            {:noreply, assign_provider(socket, Provider.get(provider.id))}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to update model")}
        end
    end
  end

  def handle_event("delete_model", %{"id" => id}, socket) do
    provider = socket.assigns.provider

    case model_for_provider(provider, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Model not found")}

      model ->
        case ProviderModel.delete(model) do
          {:ok, _deleted} ->
            {:noreply,
             socket
             |> put_flash(:info, "Model removed")
             |> assign_provider(Provider.get(provider.id))}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to remove model")}
        end
    end
  end

  defp assign_provider(socket, provider) do
    provider = normalize_provider(provider)

    assign(socket,
      provider: provider,
      provider_form: to_form(provider_params(provider), as: :provider),
      provider_errors: %{}
    )
  end

  defp normalize_provider(%Provider{} = provider) do
    %{
      provider
      | apis: Enum.sort_by(provider.apis || [], &to_string(&1.api_surface)),
        models:
          provider.models
          |> List.wrap()
          |> Enum.sort_by(& &1.model)
    }
  end

  defp load_credentials(socket) do
    provider = socket.assigns.provider
    creds = safe_call(fn -> Credentials.list() end, [])
    known_names = MapSet.new(creds, & &1.name)

    options =
      [
        {"", "Select a credential..."}
        | creds
          |> Enum.filter(&(&1.kind == "llm"))
          |> Enum.map(fn cred -> {cred.name, "#{cred.name} (#{cred.kind})"} end)
      ]

    options =
      if provider && provider.credential && not MapSet.member?(known_names, provider.credential) do
        options ++ [{provider.credential, "#{provider.credential} (missing)"}]
      else
        options
      end

    assign(socket, credential_options: options)
  end

  defp update_provider(provider, params) do
    Repo.transaction(fn ->
      with {:ok, updated_provider} <-
             Provider.update(provider, %{
               name: params["name"],
               credential: params["credential"],
               rpm_limit: parse_optional_integer(params["rpm_limit"]),
               enabled: truthy?(params["enabled"]),
               default_headers: decode_json_map(params["default_headers"])
             }),
           :ok <- upsert_api(updated_provider.id, :openai, params),
           :ok <- upsert_api(updated_provider.id, :anthropic, params) do
        Provider.get(updated_provider.id)
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset_errors(changeset))
        {:error, reason} when is_map(reason) -> Repo.rollback(reason)
        {:error, reason} -> Repo.rollback(%{base: inspect(reason)})
      end
    end)
  end

  defp upsert_api(provider_id, surface, params) do
    prefix = Atom.to_string(surface)
    existing = Enum.find(ProviderApi.list_for_provider(provider_id), &(&1.api_surface == surface))

    attrs = %{
      provider_id: provider_id,
      api_surface: surface,
      base_url: params["#{prefix}_base_url"],
      enabled: truthy?(params["#{prefix}_enabled"]),
      default_headers: decode_json_map(params["#{prefix}_default_headers"]),
      model_discovery_enabled: truthy?(params["#{prefix}_model_discovery_enabled"]),
      model_discovery_path: blank_to_nil(params["#{prefix}_model_discovery_path"])
    }

    cond do
      existing ->
        case ProviderApi.update(existing, attrs) do
          {:ok, _api} -> :ok
          {:error, changeset} -> {:error, prefixed_errors(prefix, changeset)}
        end

      truthy?(params["#{prefix}_enabled"]) or not blank?(params["#{prefix}_base_url"]) ->
        case ProviderApi.create(attrs) do
          {:ok, _api} -> :ok
          {:error, changeset} -> {:error, prefixed_errors(prefix, changeset)}
        end

      true ->
        :ok
    end
  end

  defp create_model(provider, params) do
    Repo.transaction(fn ->
      with {:ok, model} <-
             ProviderModel.create(%{
               provider_id: provider.id,
               model: params["model"],
               display_name: blank_to_nil(params["display_name"]),
               source: :manual,
               enabled: truthy?(params["enabled"]),
               metadata: decode_json_map(params["metadata"])
             }),
           :ok <- sync_model_surfaces(model, provider, params) do
        model
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset_errors(changeset))
        {:error, reason} when is_map(reason) -> Repo.rollback(reason)
        {:error, reason} -> Repo.rollback(%{base: inspect(reason)})
      end
    end)
  end

  defp update_model(model, provider, params) do
    Repo.transaction(fn ->
      with {:ok, updated_model} <-
             ProviderModel.update(model, %{
               model: params["model"],
               display_name: blank_to_nil(params["display_name"]),
               enabled: truthy?(params["enabled"]),
               metadata: decode_json_map(params["metadata"])
             }),
           :ok <- sync_model_surfaces(updated_model, provider, params) do
        updated_model
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset_errors(changeset))
        {:error, reason} when is_map(reason) -> Repo.rollback(reason)
        {:error, reason} -> Repo.rollback(%{base: inspect(reason)})
      end
    end)
  end

  defp sync_model_surfaces(model, provider, params) do
    Enum.reduce_while(provider.apis, :ok, fn api, :ok ->
      enabled = truthy?(params["surface_#{api.id}"])
      existing = ProviderModelSurface.get_by_model_and_api(model.id, api.id)

      attrs = %{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: enabled
      }

      result =
        cond do
          existing -> ProviderModelSurface.update(existing, attrs)
          enabled -> ProviderModelSurface.create(attrs)
          true -> {:ok, nil}
        end

      case result do
        {:ok, _surface} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp validate_provider_params(params) do
    %{}
    |> require_field(params, "name", "Name is required")
    |> require_field(params, "credential", "Credential is required")
    |> require_api_surface(params, "openai")
    |> require_api_surface(params, "anthropic")
  end

  defp require_api_surface(errors, params, surface) do
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

  defp validate_model_params(provider, params) do
    %{}
    |> require_field(params, "model", "Model is required")
    |> require_one_surface(provider, params)
  end

  defp require_one_surface(errors, provider, params) do
    if Enum.any?(provider.apis, &truthy?(params["surface_#{&1.id}"])) do
      errors
    else
      Map.put(errors, "surfaces", "Select at least one API surface")
    end
  end

  defp require_field(errors, params, field, message) do
    if blank?(params[field]), do: Map.put(errors, field, message), else: errors
  end

  defp provider_params(provider) do
    api_by_surface = Map.new(provider.apis, &{&1.api_surface, &1})

    %{
      "name" => provider.name,
      "credential" => provider.credential || "",
      "enabled" => checkbox_value(provider.enabled),
      "rpm_limit" => provider.rpm_limit && Integer.to_string(provider.rpm_limit),
      "default_headers" => encode_json_map(provider.default_headers),
      "openai_enabled" => api_enabled(api_by_surface[:openai]),
      "openai_base_url" => api_value(api_by_surface[:openai], :base_url),
      "openai_model_discovery_enabled" =>
        api_enabled(api_by_surface[:openai], :model_discovery_enabled),
      "openai_model_discovery_path" => api_value(api_by_surface[:openai], :model_discovery_path),
      "openai_default_headers" => encode_json_map(api_headers(api_by_surface[:openai])),
      "anthropic_enabled" => api_enabled(api_by_surface[:anthropic]),
      "anthropic_base_url" => api_value(api_by_surface[:anthropic], :base_url),
      "anthropic_model_discovery_enabled" =>
        api_enabled(api_by_surface[:anthropic], :model_discovery_enabled),
      "anthropic_model_discovery_path" =>
        api_value(api_by_surface[:anthropic], :model_discovery_path),
      "anthropic_default_headers" => encode_json_map(api_headers(api_by_surface[:anthropic]))
    }
  end

  defp model_defaults do
    %{
      "model" => "",
      "display_name" => "",
      "enabled" => "true",
      "metadata" => "{}"
    }
  end

  defp model_params(provider, model) do
    surface_api_ids = MapSet.new(model.surfaces || [], & &1.provider_api_id)

    provider.apis
    |> Enum.reduce(
      %{
        "model" => model.model,
        "display_name" => model.display_name || "",
        "enabled" => checkbox_value(model.enabled),
        "metadata" => encode_json_map(model.metadata)
      },
      fn api, params ->
        Map.put(
          params,
          "surface_#{api.id}",
          checkbox_value(MapSet.member?(surface_api_ids, api.id))
        )
      end
    )
  end

  defp model_for_provider(provider, id) do
    Enum.find(provider.models, &(&1.id == id))
  end

  defp surface_enabled?(model, api) do
    Enum.any?(model.surfaces || [], &(&1.provider_api_id == api.id and &1.enabled))
  end

  defp api_enabled(nil), do: "false"
  defp api_enabled(api), do: checkbox_value(api.enabled)
  defp api_enabled(nil, _field), do: "false"
  defp api_enabled(api, field), do: checkbox_value(Map.get(api, field))

  defp api_value(nil, _field), do: ""
  defp api_value(api, field), do: Map.get(api, field) || ""

  defp api_headers(nil), do: %{}
  defp api_headers(api), do: api.default_headers || %{}

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

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp truthy?(value) when value in [true, "true", "on", "1", 1], do: true
  defp truthy?(_), do: false

  defp checkbox_value(true), do: "true"
  defp checkbox_value(_), do: "false"

  defp parse_optional_integer(value) when value in [nil, ""], do: nil

  defp parse_optional_integer(value) do
    case Integer.parse(to_string(value)) do
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

  defp encode_json_map(value) when is_map(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      _ -> "{}"
    end
  end

  defp encode_json_map(_value), do: "{}"

  defp surface_label("openai"), do: "OpenAI-compatible"
  defp surface_label("anthropic"), do: "Anthropic Messages"

  defp api_label(:openai), do: "OpenAI"
  defp api_label(:anthropic), do: "Anthropic"
  defp api_label(other), do: to_string(other)

  defp badge_variant(:openai), do: "info"
  defp badge_variant(:anthropic), do: "tertiary"
  defp badge_variant(_), do: "neutral"

  defp enabled_variant(true), do: "success"
  defp enabled_variant(false), do: "neutral"

  defp enabled_text(true), do: "Enabled"
  defp enabled_text(false), do: "Disabled"

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
          <div class="mb-1">
            <.link navigate={~p"/admin/providers"} class="text-sm text-primary underline">
              Back to providers
            </.link>
          </div>
          <h1 class="text-2xl font-bold">{@provider.name}</h1>
          <div class="mt-1 flex flex-wrap items-center gap-2 text-sm text-on-surface-variant">
            <.dm_badge variant={enabled_variant(@provider.enabled)} size="sm">
              {enabled_text(@provider.enabled)}
            </.dm_badge>
            <span :if={@provider.preset_key}>Preset: {@provider.preset_key}</span>
            <span>Credential: <code>{@provider.credential}</code></span>
          </div>
        </div>
        <.dm_btn type="button" variant="secondary" phx-click="reload_models">
          Reload Models
        </.dm_btn>
      </div>

      <.dm_card variant="bordered" class="mb-6">
        <:title>Edit Provider</:title>
        <.form
          for={@provider_form}
          phx-submit="save_provider"
          phx-change="validate_provider"
          class="space-y-5"
        >
          <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
            <div>
              <.dm_input
                id="provider-name"
                name="provider[name]"
                label="Name"
                value={@provider_form[:name].value}
              />
              <.error errors={@provider_errors} field="name" />
            </div>

            <div>
              <.dm_select
                id="provider-credential"
                name="provider[credential]"
                label="Credential"
                options={@credential_options}
                value={@provider_form[:credential].value || ""}
              />
              <.error errors={@provider_errors} field="credential" />
            </div>

            <div>
              <input type="hidden" name="provider[enabled]" value="false" />
              <.dm_checkbox
                id="provider-enabled"
                name="provider[enabled]"
                label="Enable provider"
                value="true"
                checked={@provider_form[:enabled].value in [true, "true", "on"]}
              />
            </div>

            <div>
              <.dm_input
                id="provider-rpm-limit"
                name="provider[rpm_limit]"
                label="RPM Limit"
                value={@provider_form[:rpm_limit].value}
              />
            </div>
          </div>

          <div class="grid grid-cols-1 gap-4 xl:grid-cols-2">
            <.api_form_section
              form={@provider_form}
              errors={@provider_errors}
              key="openai"
              title="OpenAI-compatible API"
              badge="OpenAI"
            />
            <.api_form_section
              form={@provider_form}
              errors={@provider_errors}
              key="anthropic"
              title="Anthropic Messages API"
              badge="Anthropic"
            />
          </div>

          <.dm_textarea
            id="provider-default-headers"
            name="provider[default_headers]"
            label="Provider Default Headers"
            rows={3}
            value={@provider_form[:default_headers].value}
            class="font-mono"
          />

          <.dm_btn type="submit" variant="primary">Save Provider</.dm_btn>
        </.form>
      </.dm_card>

      <.dm_card variant="bordered" class="mb-6">
        <:title>Add Model</:title>
        <.model_form
          form={@model_form}
          errors={@model_errors}
          provider={@provider}
          submit="add_model"
          change="validate_model"
          button="Add Model"
        />
      </.dm_card>

      <.dm_card :if={@editing_model} variant="bordered" class="mb-6">
        <:title>Edit Model: {@editing_model.model}</:title>
        <.model_form
          form={@edit_model_form}
          errors={@edit_model_errors}
          provider={@provider}
          submit="update_model"
          change="validate_edit_model"
          button="Save Model"
        />
        <.dm_btn type="button" size="sm" class="mt-3" phx-click="cancel_edit_model">
          Cancel
        </.dm_btn>
      </.dm_card>

      <.dm_card variant="bordered">
        <:title>Models</:title>

        <div :if={@provider.models == []} class="text-sm text-on-surface-variant">
          No models configured.
        </div>

        <div class="space-y-3">
          <div
            :for={model <- @provider.models}
            class="rounded-md border border-outline-variant p-3"
          >
            <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="font-mono text-sm">{model.model}</span>
                  <.dm_badge variant={enabled_variant(model.enabled)} size="sm">
                    {enabled_text(model.enabled)}
                  </.dm_badge>
                  <.dm_badge variant="neutral" size="sm">{model.source}</.dm_badge>
                </div>
                <div :if={model.display_name} class="mt-1 text-sm text-on-surface-variant">
                  {model.display_name}
                </div>
                <div class="mt-2 flex flex-wrap gap-2">
                  <.dm_badge
                    :for={api <- @provider.apis}
                    variant={if surface_enabled?(model, api), do: badge_variant(api.api_surface), else: "neutral"}
                    size="sm"
                  >
                    {api_label(api.api_surface)} {if surface_enabled?(model, api), do: "on", else: "off"}
                  </.dm_badge>
                </div>
              </div>

              <div class="flex flex-wrap gap-2">
                <.dm_btn size="xs" phx-click="edit_model" phx-value-id={model.id}>
                  Edit
                </.dm_btn>
                <.dm_btn
                  size="xs"
                  variant={if model.enabled, do: "warning", else: "success"}
                  phx-click="toggle_model"
                  phx-value-id={model.id}
                >
                  {if model.enabled, do: "Disable", else: "Enable"}
                </.dm_btn>
                <.dm_btn
                  size="xs"
                  variant="error"
                  phx-click="delete_model"
                  phx-value-id={model.id}
                  data-confirm={"Remove model #{model.model}?"}
                >
                  Remove
                </.dm_btn>
              </div>
            </div>
          </div>
        </div>
      </.dm_card>
    </div>
    """
  end

  defp api_form_section(assigns) do
    ~H"""
    <div class="rounded-md border border-outline-variant p-4">
      <div class="mb-3 flex items-center justify-between gap-3">
        <span class="font-medium">{@title}</span>
        <.dm_badge variant={if @key == "openai", do: "info", else: "tertiary"} size="sm">
          {@badge}
        </.dm_badge>
      </div>

      <div class="space-y-4">
        <input type="hidden" name={"provider[#{@key}_enabled]"} value="false" />
        <.dm_checkbox
          id={"provider-#{@key}-enabled"}
          name={"provider[#{@key}_enabled]"}
          label={"Enable #{surface_label(@key)} API"}
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
    </div>
    """
  end

  defp model_form(assigns) do
    ~H"""
    <.form for={@form} phx-submit={@submit} phx-change={@change} class="space-y-4">
      <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
        <div>
          <.dm_input
            id={"#{@submit}-model"}
            name="model[model]"
            label="Model"
            value={@form[:model].value}
            placeholder="provider-model-id"
          />
          <.error errors={@errors} field="model" />
        </div>

        <.dm_input
          id={"#{@submit}-display-name"}
          name="model[display_name]"
          label="Display Name"
          value={@form[:display_name].value}
        />
      </div>

      <input type="hidden" name="model[enabled]" value="false" />
      <.dm_checkbox
        id={"#{@submit}-enabled"}
        name="model[enabled]"
        label="Enable model"
        value="true"
        checked={@form[:enabled].value in [true, "true", "on"]}
      />

      <div>
        <div class="mb-2 text-sm font-medium">API Surfaces</div>
        <div class="flex flex-wrap gap-4">
          <label :for={api <- @provider.apis} class="inline-flex items-center gap-2 text-sm">
            <input type="hidden" name={"model[surface_#{api.id}]"} value="false" />
            <input
              id={"#{@submit}-surface-#{api.id}"}
              type="checkbox"
              name={"model[surface_#{api.id}]"}
              value="true"
              checked={form_value(@form, "surface_#{api.id}") in [true, "true", "on"]}
            />
            <span>{api_label(api.api_surface)}</span>
          </label>
        </div>
        <.error errors={@errors} field="surfaces" />
      </div>

      <.dm_textarea
        id={"#{@submit}-metadata"}
        name="model[metadata]"
        label="Metadata"
        rows={3}
        value={@form[:metadata].value}
        class="font-mono"
      />

      <.dm_btn type="submit" variant="primary">{@button}</.dm_btn>
    </.form>
    """
  end

  defp field_value(form, key, suffix) do
    form[String.to_atom("#{key}_#{suffix}")].value
  end

  defp form_value(form, key), do: form[key].value
end
