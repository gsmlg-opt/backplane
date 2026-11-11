defmodule Backplane.Admin.ProviderShowLive do
  use Backplane.Admin, :live_view

  alias Backplane.LLM.{
    HostServices,
    ModelDiscovery,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    ProviderPreset
  }

  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/llama/providers",
       provider: nil,
       credential_options: [],
       host_service_options: [],
       provider_form: to_form(%{}, as: :provider),
       provider_errors: %{},
       model_form: to_form(model_defaults(), as: :model),
       model_errors: %{},
       editing_model: nil,
       edit_model_form: nil,
       edit_model_errors: %{},
       deleting_model: nil,
       model_reload_status: nil,
       model_groups: []
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Provider.get(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("errors", "Provider not found"))
         |> push_navigate(to: ~p"/llama/providers")}

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
       provider_errors: validate_provider_params(socket.assigns.provider, params)
     )}
  end

  def handle_event("save_provider", %{"provider" => params}, socket) do
    errors = validate_provider_params(socket.assigns.provider, params)

    if map_size(errors) > 0 do
      {:noreply,
       assign(socket,
         provider_form: to_form(params, as: :provider),
         provider_errors: errors
       )}
    else
      case update_provider(socket.assigns.provider, params) do
        {:ok, provider} ->
          Backplane.Admin.Audit.record("provider.update", "provider", provider.id)

          {:noreply,
           socket
           |> put_flash(:info, dgettext("admin", "Provider updated"))
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
        Backplane.Admin.Audit.record("provider.reload_models", "provider", provider.id)

        put_flash(
          socket,
          :info,
          dgettext("admin", "Reloaded %{discovered} model(s): %{created} new, %{updated} updated",
            discovered: result.discovered,
            created: result.created,
            updated: result.updated
          )
        )
      else
        put_flash(
          socket,
          :error,
          dgettext("errors", "Model reload finished with errors: %{errors}",
            errors: Enum.join(result.errors, "; ")
          )
        )
      end

    {:noreply,
     socket
     |> assign_provider(Provider.get(provider.id))
     |> assign(model_reload_status: result)}
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
        {:ok, model} ->
          Backplane.Admin.Audit.record("provider_model.create", "provider_model", model.id)

          {:noreply,
           socket
           |> put_flash(:info, dgettext("admin", "Model added"))
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
        {:noreply, put_flash(socket, :error, dgettext("errors", "Model not found"))}

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

  def handle_event("confirm_delete_model", %{"id" => id}, socket) do
    case model_for_provider(socket.assigns.provider, id) do
      nil ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Model not found"))}

      model ->
        {:noreply, assign(socket, deleting_model: model)}
    end
  end

  def handle_event("cancel_delete_model", _params, socket) do
    {:noreply, assign(socket, deleting_model: nil)}
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
        {:ok, model} ->
          Backplane.Admin.Audit.record("provider_model.update", "provider_model", model.id)

          {:noreply,
           socket
           |> put_flash(:info, dgettext("admin", "Model updated"))
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
        {:noreply, put_flash(socket, :error, dgettext("errors", "Model not found"))}

      model ->
        case ProviderModel.update(model, %{enabled: !model.enabled}) do
          {:ok, _updated} ->
            Backplane.Admin.Audit.record("provider_model.toggle", "provider_model", model.id)
            {:noreply, assign_provider(socket, Provider.get(provider.id))}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, dgettext("errors", "Failed to update model"))}
        end
    end
  end

  def handle_event("delete_model", %{"id" => id}, socket) do
    provider = socket.assigns.provider

    case model_for_provider(provider, id) do
      nil ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Model not found"))}

      model ->
        case ProviderModel.delete(model) do
          {:ok, _deleted} ->
            Backplane.Admin.Audit.record("provider_model.delete", "provider_model", model.id)

            {:noreply,
             socket
             |> put_flash(:info, dgettext("admin", "Model removed"))
             |> assign_provider(Provider.get(provider.id))
             |> assign(deleting_model: nil)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, dgettext("errors", "Failed to remove model"))}
        end
    end
  end

  defp assign_provider(socket, provider) do
    provider = normalize_provider(provider)

    assign(socket,
      provider: provider,
      model_groups: antigravity_model_groups(provider),
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
          |> Enum.reject(&hidden_stale_discovered_model?/1)
          |> Enum.sort_by(& &1.model)
    }
  end

  defp hidden_stale_discovered_model?(model) do
    model.source == :discovered and not model.enabled and model.surfaces == []
  end

  defp antigravity_model_groups(%Provider{apis: apis, models: models}) do
    if Enum.any?(apis, &(&1.api_surface == :antigravity)) do
      models
      |> List.wrap()
      |> Enum.reject(&hidden_stale_discovered_model?/1)
      |> Enum.filter(&antigravity_display_model?/1)
      |> Enum.group_by(&antigravity_model_family/1)
      |> Enum.map(fn {family, variants} ->
        %{
          family: family,
          label: antigravity_family_label(family, variants),
          variants: Enum.sort_by(variants, & &1.model)
        }
      end)
      |> Enum.sort_by(& &1.label)
    else
      []
    end
  end

  defp antigravity_provider?(%Provider{apis: apis}),
    do: Enum.any?(apis || [], &(&1.api_surface == :antigravity))

  defp antigravity_provider?(_provider), do: false

  defp antigravity_display_model?(%{source: :manual}), do: true

  defp antigravity_display_model?(%{source: "manual"}), do: true

  defp antigravity_display_model?(model) do
    metadata = model.metadata || %{}
    # Keep hand-authored/legacy rows that predate the native catalog shape.
    if is_nil(metadata["slug"]) do
      true
    else
      recommended? = metadata["recommended"] == true

      recommended? and model.model != "gemini-pro-agent" and
        not String.match?(model.model, ~r/^gemini-2(?:\.\d+)?-/)
    end
  end

  defp antigravity_model_family(model) do
    model.model
    |> String.replace(~r/-(?:extra-)?low\z/, "")
    |> String.replace(~r/-(?:high|medium|tiered|thinking)\z/, "")
    |> case do
      "gemini-pro-agent" -> "gemini-3.1-pro"
      family -> family
    end
  end

  defp antigravity_family_label(family, variants) do
    variants
    |> Enum.find(&(&1.model == family))
    |> case do
      %{display_name: name} when is_binary(name) and name != "" -> name
      _ -> family
    end
  end

  defp load_credentials(socket) do
    provider = socket.assigns.provider
    preset = provider_preset(provider)
    creds = safe_call(fn -> Credentials.list() end, [])
    known_names = MapSet.new(creds, & &1.name)

    options =
      [
        {"", dgettext("admin", "Select a credential...")}
        | creds
          |> Enum.filter(&credential_allowed?(preset, &1))
          |> Enum.map(fn cred -> {cred.name, credential_label(cred)} end)
      ]

    options =
      if provider && provider.credential && not MapSet.member?(known_names, provider.credential) do
        options ++ [{provider.credential,
           dgettext("admin", "%{name} (missing)", name: provider.credential)}]
      else
        options
      end

    assign(socket,
      host_service_options: [{"", dgettext("admin", "Direct HTTP")} | HostServices.options()],
      credential_options: options
    )
  end

  defp provider_preset(%Provider{preset_key: preset_key}) when is_binary(preset_key) do
    ProviderPreset.get(preset_key)
  end

  defp provider_preset(_provider), do: nil

  defp credential_allowed?(nil, cred), do: cred.kind == "llm"

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

  defp update_provider(provider, params) do
    Repo.transaction(fn ->
      with {:ok, updated_provider} <-
             Provider.update(provider, %{
               name: params["name"],
               credential: params["credential"],
               host_service_id: blank_to_nil(params["host_service_id"]),
               rpm_limit: parse_optional_integer(params["rpm_limit"]),
               enabled: truthy?(params["enabled"]),
               default_headers: decode_json_map(params["default_headers"])
             }),
           :ok <- upsert_apis(updated_provider, params) do
        Provider.get(updated_provider.id)
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset_errors(changeset))
        {:error, reason} when is_map(reason) -> Repo.rollback(reason)
        {:error, reason} -> Repo.rollback(%{base: inspect(reason)})
      end
    end)
  end

  defp upsert_apis(provider, params) do
    provider.id
    |> ProviderApi.list_for_provider()
    |> Enum.reduce_while(:ok, fn api, :ok ->
      case upsert_api(provider, api.api_surface, params) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp upsert_api(provider, surface, params) do
    prefix = Atom.to_string(surface)
    existing = Enum.find(ProviderApi.list_for_provider(provider.id), &(&1.api_surface == surface))

    default_protocols =
      if existing, do: existing.native_protocols, else: native_protocols(provider, surface)

    attrs = %{
      provider_id: provider.id,
      api_surface: surface,
      base_url: params["#{prefix}_base_url"],
      enabled: truthy?(params["#{prefix}_enabled"]),
      default_headers: decode_json_map(params["#{prefix}_default_headers"]),
      model_discovery_enabled: truthy?(params["#{prefix}_model_discovery_enabled"]),
      responses_websocket: truthy?(params["#{prefix}_responses_websocket"]),
      model_discovery_path: blank_to_nil(params["#{prefix}_model_discovery_path"]),
      backend_config: backend_config_from_params(surface, params)
    }

    attrs =
      Map.put(
        attrs,
        :native_protocols,
        native_protocols_from_params(params, surface, default_protocols)
      )

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

  defp native_protocols(provider, surface) do
    case ProviderPreset.get(provider.preset_key || "custom") do
      nil ->
        if(surface == :anthropic, do: [:anthropic_messages], else: [:openai_chat_completions])

      preset ->
        ProviderPreset.native_protocols(preset, surface)
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

  defp validate_provider_params(provider, params) do
    %{}
    |> require_field(params, "name", dgettext("errors", "Name is required"))
    |> require_credential(params)
    |> require_allowed_credential(provider_preset(provider), params)
    |> require_api_surfaces(params, provider)
  end

  defp require_credential(errors, params) do
    if blank?(params["host_service_id"]),
      do: require_field(errors, params, "credential", dgettext("errors", "Credential is required")),
      else: errors
  end

  defp require_allowed_credential(errors, nil, _params), do: errors

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

  defp require_api_surface(errors, params, surface) do
    if truthy?(params["#{surface}_enabled"]) and blank?(params["host_service_id"]) do
      require_field(
        errors,
        params,
        "#{surface}_base_url",
        dgettext("errors", "%{surface} base URL is required", surface: surface_label(surface))
      )
    else
      errors
    end
  end

  defp require_api_surfaces(errors, params, provider) do
    Enum.reduce(provider.apis, errors, fn api, errors ->
      require_api_surface(errors, params, Atom.to_string(api.api_surface))
    end)
  end

  defp validate_model_params(provider, params) do
    %{}
    |> require_field(params, "model", dgettext("errors", "Model is required"))
    |> require_one_surface(provider, params)
  end

  defp require_one_surface(errors, provider, params) do
    if Enum.any?(provider.apis, &truthy?(params["surface_#{&1.id}"])) do
      errors
    else
      Map.put(errors, "surfaces", dgettext("errors", "Select at least one API surface"))
    end
  end

  defp require_field(errors, params, field, message) do
    if blank?(params[field]), do: Map.put(errors, field, message), else: errors
  end

  defp provider_params(provider) do
    params = %{
      "name" => provider.name,
      "credential" => provider.credential || "",
      "host_service_id" => provider.host_service_id || "",
      "enabled" => checkbox_value(provider.enabled),
      "rpm_limit" => provider.rpm_limit && Integer.to_string(provider.rpm_limit),
      "default_headers" => encode_json_map(provider.default_headers)
    }

    Enum.reduce(provider.apis, params, &put_api_params(provider, &1, &2))
  end

  defp put_api_params(provider, api, params) do
    prefix = Atom.to_string(api.api_surface)

    params =
      params
      |> Map.put("#{prefix}_enabled", api_enabled(api))
      |> Map.put("#{prefix}_base_url", api_value(api, :base_url))
      |> Map.put("#{prefix}_model_discovery_enabled", api_enabled(api, :model_discovery_enabled))
      |> Map.put("#{prefix}_responses_websocket", api_enabled(api, :responses_websocket))
      |> Map.put("#{prefix}_model_discovery_path", api_value(api, :model_discovery_path))
      |> Map.put("#{prefix}_default_headers", encode_json_map(api_headers(api)))
      |> put_backend_config_params(api)

    Enum.reduce(protocols_for(provider, api), params, fn protocol, params ->
      Map.put(params, "#{protocol}_enabled", protocol_enabled(api, protocol))
    end)
  end

  defp put_backend_config_params(params, %{api_surface: :antigravity} = api) do
    config = Map.get(api, :backend_config, %{}) || %{}

    params
    |> Map.put("antigravity_project_id", Map.get(config, "project_id", ""))
    |> Map.put("antigravity_user_agent", Map.get(config, "user_agent", ""))
    |> Map.put("antigravity_client_version", Map.get(config, "client_version", ""))
  end

  defp put_backend_config_params(params, _api), do: params

  defp backend_config_from_params(:antigravity, params) do
    %{
      "project_id" => blank_to_nil(params["antigravity_project_id"]),
      "user_agent" => blank_to_nil(params["antigravity_user_agent"]),
      "client_version" => blank_to_nil(params["antigravity_client_version"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp backend_config_from_params(_surface, _params), do: %{}

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

  defp api_enabled(api), do: checkbox_value(api.enabled)
  defp api_enabled(api, field), do: checkbox_value(Map.get(api, field))

  defp api_value(api, field), do: Map.get(api, field) || ""

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
  defp surface_label("google"), do: "Google GenerateContent"
  defp surface_label("antigravity"), do: "Google Antigravity"

  defp api_label(:openai), do: "OpenAI"
  defp api_label(:anthropic), do: "Anthropic"
  defp api_label(:google), do: "Google"
  defp api_label(:antigravity), do: "Antigravity"
  defp api_label(other), do: to_string(other)

  defp badge_variant(:openai), do: "info"
  defp badge_variant(:anthropic), do: "tertiary"
  defp badge_variant(:google), do: "success"
  defp badge_variant(:antigravity), do: "warning"
  defp badge_variant(_), do: "neutral"

  defp enabled_variant(true), do: "success"
  defp enabled_variant(false), do: "neutral"

  defp enabled_text(true), do: dgettext("common", "Enabled")
  defp enabled_text(false), do: dgettext("common", "Disabled")

  defp google_apis(provider) do
    Enum.filter(provider.apis, &(&1.api_surface == :google))
  end

  defp google_api_version(api) do
    if String.contains?(api.base_url || "", "/v1beta"), do: "v1beta", else: dgettext("admin", "Unknown")
  end

  defp google_credential_auth_type(provider) do
    case provider_preset(provider) do
      %{credential_auth_type: "api_key"} -> dgettext("admin", "API key")
      %{credential_auth_type: auth_type} when is_binary(auth_type) -> auth_type
      _ -> dgettext("admin", "Unknown")
    end
  end

  defp google_model_metadata(model, provider) do
    google_api_ids = MapSet.new(google_apis(provider), & &1.id)

    case Enum.filter(model.surfaces || [], &MapSet.member?(google_api_ids, &1.provider_api_id)) do
      [] -> nil
      surfaces -> Enum.reduce(surfaces, model.metadata || %{}, &Map.merge(&2, &1.metadata || %{}))
    end
  end

  defp metadata_value(metadata, keys) do
    Enum.find_value(keys, dgettext("admin", "Unknown"), fn key ->
      case Map.get(metadata, key) do
        value when value in [nil, ""] -> nil
        value -> to_string(value)
      end
    end)
  end

  defp metadata_list(metadata, key) do
    case Map.get(metadata, key) do
      values when is_list(values) and values != [] -> Enum.join(values, ", ")
      _ -> dgettext("admin", "Unknown")
    end
  end

  defp directory_status(nil), do: nil
  defp directory_status(%{errors: []}),
    do: dgettext("admin", "Last reload completed successfully.")

  defp directory_status(%{errors: errors}),
    do:
      dgettext("errors", "Last reload incomplete: %{errors}", errors: Enum.join(errors, "; "))

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
            <.link navigate={~p"/llama/providers"} class="text-sm text-primary underline">
              {dgettext("navigation", "Back to providers")}
            </.link>
          </div>
          <h1 class="text-2xl font-bold">{@provider.name}</h1>
          <div class="mt-1 flex flex-wrap items-center gap-2 text-sm text-on-surface-variant">
            <.dm_badge variant={enabled_variant(@provider.enabled)} size="sm">
              {enabled_text(@provider.enabled)}
            </.dm_badge>
            <span :if={@provider.preset_key}>{dgettext("admin", "Preset: %{key}", key: @provider.preset_key)}</span>
            <span>{dgettext("admin", "Credential:")} <code>{@provider.credential}</code></span>
            <span :if={google_apis(@provider) != []}>
              {dgettext("admin", "Credential auth: %{type}", type: google_credential_auth_type(@provider))}
            </span>
          </div>
        </div>

      </div>

      <.dm_card variant="bordered" class="mb-6">
        <:title>{dgettext("admin", "Edit Provider")}</:title>
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
                label={dgettext("common", "Name")}
                value={@provider_form[:name].value}
              />
              <.error errors={@provider_errors} field="name" />
            </div>

            <div>
              <.dm_select
                id="provider-credential"
                name="provider[credential]"
                label={dgettext("admin", "Credential")}
                options={@credential_options}
                value={@provider_form[:credential].value || ""}
              />
              <.error errors={@provider_errors} field="credential" />
            </div>

            <div>
              <.dm_select id="provider-host-service" name="provider[host_service_id]" label={dgettext("admin", "Host API Service")}
                options={@host_service_options} value={@provider_form[:host_service_id].value || ""} />
              <.error errors={@provider_errors} field="host_service_id" />
              <p class="mt-1 text-xs text-on-surface-variant">{dgettext("admin", "Hosted APIs use the service endpoints. Credential is optional for unauthenticated local services.")}</p>
            </div>

            <div>
              <input type="hidden" name="provider[enabled]" value="false" />
              <.dm_checkbox
                id="provider-enabled"
                name="provider[enabled]"
                label={dgettext("admin", "Enable provider")}
                value="true"
                checked={@provider_form[:enabled].value in [true, "true", "on"]}
              />
            </div>

            <div>
              <.dm_input
                id="provider-rpm-limit"
                name="provider[rpm_limit]"
                label={dgettext("admin", "RPM Limit")}
                value={@provider_form[:rpm_limit].value}
              />
            </div>
          </div>

          <div class="grid grid-cols-1 gap-4 xl:grid-cols-2">
            <.api_form_section
              :for={api <- @provider.apis}
              form={@provider_form}
              errors={@provider_errors}
              key={Atom.to_string(api.api_surface)}
              title={surface_title(api.api_surface)}
              badge={api_label(api.api_surface)}
              protocols={protocols_for(@provider, api)}
            />
          </div>

          <.dm_textarea
            id="provider-default-headers"
            name="provider[default_headers]"
            label={dgettext("admin", "Provider Default Headers")}
            rows={3}
            value={@provider_form[:default_headers].value}
            class="font-mono"
          />

          <.dm_btn type="submit" variant="primary">{dgettext("admin", "Save Provider")}</.dm_btn>
        </.form>
      </.dm_card>

      <.dm_card :if={google_apis(@provider) != []} variant="bordered" class="mb-6">
        <:title>{dgettext("admin", "Directory refresh")}</:title>
        <div class="space-y-2 text-sm">
          <div :for={api <- google_apis(@provider)}>
            <span class="font-medium">Google GenerateContent:</span>
            <span>{dgettext("admin", "API version: %{version}.", version: google_api_version(api))}</span>
            <span :if={api.last_discovered_at}>
              {dgettext("admin", "Last successful discovery: %{time}", time: api.last_discovered_at)}
            </span>
            <span :if={!api.last_discovered_at}>{dgettext("admin", "No successful discovery recorded.")}</span>
          </div>
          <p :if={directory_status(@model_reload_status)} class="text-on-surface-variant">
            {directory_status(@model_reload_status)}
          </p>
          <p class="text-on-surface-variant">{dgettext("admin", "Directory refresh reads the model catalog only; it never starts a generation.")}</p>
        </div>
      </.dm_card>

      <.dm_card variant="bordered" class="mb-6">
        <:title>
          <div class="flex w-full flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <span>{dgettext("admin", "Add Model")}</span>
            <.dm_btn type="button" size="sm" variant="secondary" phx-click="reload_models">
              {dgettext("admin", "Load Models from API")}
            </.dm_btn>
          </div>
        </:title>
        <.model_form
          form={@model_form}
          errors={@model_errors}
          provider={@provider}
          submit="add_model"
          change="validate_model"
          button={dgettext("admin", "Add Model")}
        />
      </.dm_card>

      <.dm_card :if={@editing_model} variant="bordered" class="mb-6">
        <:title>{dgettext("admin", "Edit Model: %{model}", model: @editing_model.model)}</:title>
        <.model_form
          form={@edit_model_form}
          errors={@edit_model_errors}
          provider={@provider}
          submit="update_model"
          change="validate_edit_model"
          button={dgettext("admin", "Save Model")}
        />
        <.dm_btn type="button" size="sm" class="mt-3" phx-click="cancel_edit_model">
          {dgettext("common", "Cancel")}
        </.dm_btn>
      </.dm_card>

      <.dm_card variant="bordered">
        <:title>{dgettext("admin", "Models")}</:title>
        <.delete_model_modal :if={@deleting_model} model={@deleting_model} />

        <div :if={@provider.models == []} class="text-sm text-on-surface-variant">
          {dgettext("admin", "No models configured.")}
        </div>

        <div :if={antigravity_provider?(@provider)} class="space-y-3">
          <div :for={group <- @model_groups} class="rounded-md border border-outline-variant p-4">
            <div class="flex items-center justify-between gap-3">
              <div>
                <div class="font-medium">{group.label}</div>
                <div class="text-xs text-on-surface-variant">
                  {dgettext("admin", "%{count} backend variants", count: length(group.variants))}
                </div>
              </div>
              <.dm_badge variant="neutral" size="sm">{group.family}</.dm_badge>
            </div>
            <div class="mt-3 space-y-2">
              <div
                :for={model <- group.variants}
                class="flex flex-wrap items-center justify-between gap-2 rounded border border-outline-variant px-3 py-2"
              >
                <div class="min-w-0">
                  <code class="block truncate text-sm">{model.model}</code>
                  <div class="mt-1 flex flex-wrap gap-2 text-xs text-on-surface-variant">
                    <span>{model.source}</span>
                    <span :if={model.metadata["tagTitle"]}>{model.metadata["tagTitle"]}</span>
                    <span :if={model.metadata["thinkingBudget"]}>
                      {dgettext("admin", "thinking budget: %{value}", value: model.metadata["thinkingBudget"])}
                    </span>
                  </div>
                  <.antigravity_model_metadata_popover
                    :if={antigravity_model_metadata(model, @provider)}
                    metadata={antigravity_model_metadata(model, @provider)}
                    model={model}
                  />
                </div>
                <div class="flex items-center gap-1">
                  <.dm_badge variant={enabled_variant(model.enabled)} size="sm">
                    {enabled_text(model.enabled)}
                  </.dm_badge>
                  <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Edit")} position="bottom">
                    <.dm_btn
                      {tooltip_attrs}
                      id={"edit-model-#{model.id}"}
                      type="button"
                      size="xs"
                      shape="circle"
                      variant="outline"
                      aria-label={dgettext("admin", "Edit model %{model}", model: model.model)}
                      phx-click="edit_model"
                      phx-value-id={model.id}
                    >
                      <.dm_mdi name="pencil" class="h-4 w-4" />
                      <span class="sr-only">{dgettext("common", "Edit")}</span>
                    </.dm_btn>
                  </.dm_tooltip>
                  <.dm_tooltip :let={tooltip_attrs} content={if model.enabled, do: dgettext("common", "Disable"), else: dgettext("common", "Enable")} position="bottom">
                    <.dm_btn
                      {tooltip_attrs}
                      type="button"
                      size="xs"
                      shape="circle"
                      variant={if model.enabled, do: "warning", else: "success"}
                      aria-label={
                        if model.enabled,
                          do: dgettext("admin", "Disable model %{model}", model: model.model),
                          else: dgettext("admin", "Enable model %{model}", model: model.model)
                      }
                      phx-click="toggle_model"
                      phx-value-id={model.id}
                    >
                      <.dm_mdi name={if model.enabled, do: "pause", else: "play"} class="h-4 w-4" />
                      <span class="sr-only">{if model.enabled, do: dgettext("common", "Disable"), else: dgettext("common", "Enable")}</span>
                    </.dm_btn>
                  </.dm_tooltip>
                  <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Remove")} position="bottom">
                    <.dm_btn
                      {tooltip_attrs}
                      type="button"
                      size="xs"
                      shape="circle"
                      variant="error"
                      aria-label={dgettext("admin", "Remove model %{model}", model: model.model)}
                      phx-click="confirm_delete_model"
                      phx-value-id={model.id}
                    >
                      <.dm_mdi name="delete" class="h-4 w-4" />
                      <span class="sr-only">{dgettext("common", "Remove")}</span>
                    </.dm_btn>
                  </.dm_tooltip>
                </div>
              </div>
            </div>
          </div>
        </div>

        <.dm_table
          :if={@provider.models != [] and not antigravity_provider?(@provider)}
          id="provider-models-table"
          data={@provider.models}
          hover
          zebra
        >
          <:col :let={model} label={dgettext("admin", "Model")}>
            <div class="min-w-0">
              <code class="block truncate text-sm">{model.model}</code>
              <span :if={model.display_name} class="mt-1 block text-sm text-on-surface-variant">
                {model.display_name}
              </span>
              <.google_model_metadata
                :if={google_model_metadata(model, @provider)}
                metadata={google_model_metadata(model, @provider)}
              />
              <.antigravity_model_metadata_popover
                :if={antigravity_model_metadata(model, @provider)}
                metadata={antigravity_model_metadata(model, @provider)}
                model={model}
              />
            </div>
          </:col>
          <:col :let={model} label={dgettext("common", "Status")}>
            <.dm_badge variant={enabled_variant(model.enabled)} size="sm">
              {enabled_text(model.enabled)}
            </.dm_badge>
          </:col>
          <:col :let={model} label={dgettext("admin", "Source")}>
            <.dm_badge variant="neutral" size="sm">{model.source}</.dm_badge>
          </:col>
          <:col :let={model} label={dgettext("admin", "API surfaces")}>
            <div class="flex flex-wrap gap-2">
              <.dm_badge
                :for={api <- @provider.apis}
                variant={
                  if surface_enabled?(model, api),
                    do: badge_variant(api.api_surface),
                    else: "neutral"
                }
                size="sm"
              >
                {if surface_enabled?(model, api),
                  do: dgettext("admin", "%{api} on", api: api_label(api.api_surface)),
                  else: dgettext("admin", "%{api} off", api: api_label(api.api_surface))}
              </.dm_badge>
            </div>
          </:col>
          <:col :let={model} label={dgettext("admin", "Routing")}>
            <div :if={google_model_metadata(model, @provider)} class="flex flex-wrap gap-2">
              <.dm_badge variant="success" size="sm">{dgettext("admin", "Native Google GenerateContent")}</.dm_badge>
              <.dm_badge variant="neutral" size="sm">{dgettext("admin", "Translation unavailable")}</.dm_badge>
            </div>
            <span :if={!google_model_metadata(model, @provider)} class="text-on-surface-variant">{dgettext("admin", "Unknown")}</span>
          </:col>
          <:col :let={model} label={dgettext("common", "Actions")}>
            <div class="flex items-center gap-1">
              <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Edit")} position="bottom">
                <.dm_btn {tooltip_attrs}
                  id={"edit-model-#{model.id}"}
                  type="button"
                  size="xs"
                  shape="circle"
                  variant="outline"
                  aria-label={dgettext("admin", "Edit model %{model}", model: model.model)}
                  phx-click="edit_model"
                  phx-value-id={model.id}
                >
                  <.dm_mdi name="pencil" class="h-4 w-4" />
                  <span class="sr-only">{dgettext("common", "Edit")}</span>
                </.dm_btn>
              </.dm_tooltip>
              <.dm_tooltip :let={tooltip_attrs} content={if model.enabled, do: dgettext("common", "Disable"), else: dgettext("common", "Enable")} position="bottom">
                <.dm_btn {tooltip_attrs}
                  id={"toggle-model-#{model.id}"}
                  type="button"
                  size="xs"
                  shape="circle"
                  variant={if model.enabled, do: "warning", else: "success"}
                  aria-label={
                    if model.enabled,
                      do: dgettext("admin", "Disable model %{model}", model: model.model),
                      else: dgettext("admin", "Enable model %{model}", model: model.model)
                  }
                  phx-click="toggle_model"
                  phx-value-id={model.id}
                >
                  <.dm_mdi name={if model.enabled, do: "pause", else: "play"} class="h-4 w-4" />
                  <span class="sr-only">{if model.enabled, do: dgettext("common", "Disable"), else: dgettext("common", "Enable")}</span>
                </.dm_btn>
              </.dm_tooltip>
              <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Remove")} position="bottom">
                <.dm_btn {tooltip_attrs}
                  id={"open-delete-model-modal-#{model.id}"}
                  type="button"
                  size="xs"
                  shape="circle"
                  variant="error"
                  aria-label={dgettext("admin", "Remove model %{model}", model: model.model)}
                  phx-click="confirm_delete_model"
                  phx-value-id={model.id}
                >
                  <.dm_mdi name="delete" class="h-4 w-4" />
                  <span class="sr-only">{dgettext("common", "Remove")}</span>
                </.dm_btn>
              </.dm_tooltip>
            </div>
          </:col>
        </.dm_table>
      </.dm_card>
    </div>
    """
  end

  defp delete_model_modal(assigns) do
    ~H"""
    <div
      id="delete-model-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 px-4 py-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby="delete-model-modal-title"
      phx-window-keydown="cancel_delete_model"
      phx-key="Escape"
    >
      <div class="w-full max-w-md rounded-lg border border-outline-variant bg-surface-container p-6 shadow-xl">
        <h2 id="delete-model-modal-title" class="mb-2 text-lg font-semibold text-on-surface">
          {dgettext("admin", "Delete Model")}
        </h2>
        <p class="mb-6 text-sm text-on-surface-variant">
          {dgettext("admin", "Remove model")} <code class="font-mono text-error">{@model.model}</code>?
          {dgettext("admin", "This cannot be undone.")}
        </p>
        <div class="flex justify-end gap-2">
          <.dm_btn type="button" variant="outline" size="sm" phx-click="cancel_delete_model">
            {dgettext("common", "Cancel")}
          </.dm_btn>
          <.dm_btn
            id="delete-model-confirm"
            type="button"
            variant="error"
            size="sm"
            phx-click="delete_model"
            phx-value-id={@model.id}
          >
            {dgettext("common", "Delete")}
          </.dm_btn>
        </div>
      </div>
    </div>
    """
  end

  attr(:metadata, :map, required: true)

  defp google_model_metadata(assigns) do
    ~H"""
    <dl class="mt-2 space-y-1 text-xs text-on-surface-variant">
      <div>{dgettext("admin", "Native resource:")} <code>{metadata_value(@metadata, ["name", "resource_name"])}</code></div>
      <div>{dgettext("admin", "Input token limit: %{value}", value: metadata_value(@metadata, ["inputTokenLimit", "context_window"]))}</div>
      <div>{dgettext("admin", "Output token limit: %{value}", value: metadata_value(@metadata, ["outputTokenLimit", "max_output_tokens"]))}</div>
      <div>{dgettext("admin", "Supported methods: %{value}", value: metadata_list(@metadata, "supportedGenerationMethods"))}</div>
      <div>{dgettext("admin", "Advanced capabilities: Unknown")}</div>
    </dl>
    """
  end

  defp antigravity_model_metadata(model, provider) do
    api_ids =
      provider.apis
      |> Enum.filter(&(&1.api_surface == :antigravity))
      |> MapSet.new(& &1.id)

    case Enum.filter(model.surfaces || [], &MapSet.member?(api_ids, &1.provider_api_id)) do
      [] -> nil
      surfaces -> Enum.reduce(surfaces, model.metadata || %{}, &Map.merge(&2, &1.metadata || %{}))
    end
  end

  attr(:metadata, :map, required: true)
  attr(:model, :map, required: true)

  defp antigravity_model_metadata_popover(assigns) do
    ~H"""
    <.dm_popover
      id={"model-metadata-#{@model.id}"}
      placement="bottom-start"
      class="max-w-2xl"
    >
      <:trigger>
        <button
          type="button"
          class="inline-flex items-center rounded p-1 text-on-surface-variant hover:bg-surface-container-high"
          aria-label={dgettext("admin", "Show metadata for %{model}", model: @model.model)}
        >
          <.dm_mdi name="information-outline" class="h-4 w-4" />
        </button>
      </:trigger>
      <div class="relative z-50 max-w-2xl space-y-2 rounded-md border border-outline-variant bg-surface p-3 text-xs text-on-surface-variant shadow-lg">
        <div>
          <span class="font-medium">{dgettext("admin", "Native display name:")}</span>
          {metadata_value(@metadata, ["displayName"])}
        </div>
        <div>
          <span class="font-medium">{dgettext("admin", "Quota:")}</span>
          {native_metadata_value(@metadata, "quotaInfo")}
        </div>
        <div>
          <div class="font-medium">{dgettext("admin", "Native metadata:")}</div>
          <pre class="mt-1 max-h-80 overflow-auto whitespace-pre-wrap break-all rounded bg-surface-container p-2"><code>{encode_json_map(@metadata)}</code></pre>
        </div>
      </div>
    </.dm_popover>
    """
  end

  defp native_metadata_value(metadata, key) do
    case Map.get(metadata, key) do
      value when value in [nil, ""] -> dgettext("admin", "Unavailable")
      value when is_map(value) or is_list(value) -> Jason.encode!(value)
      value -> to_string(value)
    end
  end

  defp api_form_section(assigns) do
    ~H"""
    <div class="rounded-md border border-outline-variant p-4">
      <div class="mb-3 flex items-center justify-between gap-3">
        <span class="font-medium">{@title}</span>
        <.dm_badge variant={badge_variant(String.to_existing_atom(@key))} size="sm">
          {@badge}
        </.dm_badge>
      </div>

      <div class="space-y-4">
        <input type="hidden" name={"provider[#{@key}_enabled]"} value="false" />
        <.dm_checkbox
          id={"provider-#{@key}-enabled"}
          name={"provider[#{@key}_enabled]"}
          label={dgettext("admin", "Enable %{surface} API", surface: surface_label(@key))}
          value="true"
          checked={field_value(@form, @key, "enabled") in [true, "true", "on"]}
        />

        <div>
          <.dm_input
            id={"provider-#{@key}-base-url"}
            name={"provider[#{@key}_base_url]"}
            label={dgettext("admin", "Base URL")}
            value={field_value(@form, @key, "base_url")}
          />
          <.error errors={@errors} field={"#{@key}_base_url"} />
        </div>

        <div :if={@key == "antigravity"} class="space-y-4">
          <.dm_input
            id="provider-antigravity-project-id"
            name="provider[antigravity_project_id]"
            label={dgettext("admin", "Project ID")}
            value={field_value(@form, "antigravity", "project_id")}
          />
          <.dm_input
            id="provider-antigravity-user-agent"
            name="provider[antigravity_user_agent]"
            label={dgettext("admin", "User Agent")}
            value={field_value(@form, "antigravity", "user_agent")}
          />
          <.dm_input
            id="provider-antigravity-client-version"
            name="provider[antigravity_client_version]"
            label={dgettext("admin", "Client Version")}
            value={field_value(@form, "antigravity", "client_version")}
          />
        </div>

        <div :if={@protocols != []} class="space-y-2">
          <p class="text-sm font-medium">{dgettext("admin", "Native wire protocols")}</p>
          <div :for={protocol <- @protocols}>
            <input type="hidden" name={protocol_input_name(@key, protocol)} value="false" />
            <.dm_checkbox
              id={protocol_input_id(@key, protocol)}
              name={protocol_input_name(@key, protocol)}
              label={protocol_label(protocol)}
              value="true"
              checked={protocol_field_value(@form, protocol) in [true, "true", "on"]}
            />
          </div>
          <.error errors={@errors} field={"#{@key}_native_protocols"} />
        </div>

        <div :if={@key == "openai"} class="space-y-2">
          <input type="hidden" name="provider[openai_responses_websocket]" value="false" />
          <.dm_checkbox
            id="provider-openai-responses-websocket"
            name="provider[openai_responses_websocket]"
            label={dgettext("admin", "Upstream supports Responses WebSocket")}
            value="true"
            checked={field_value(@form, @key, "responses_websocket") in [true, "true", "on"]}
          />
          <p class="text-sm text-base-content/60">
            {dgettext("admin", "Requires native Responses. Enables WebSocket forwarding with an explicit model query. Does not enable background cancellation or steering. WebSocket token usage is not yet included in gateway usage totals.")}
          </p>
          <.error errors={@errors} field="openai_responses_websocket" />
        </div>

        <input type="hidden" name={"provider[#{@key}_model_discovery_enabled]"} value="false" />
        <.dm_checkbox
          id={"provider-#{@key}-discovery-enabled"}
          name={"provider[#{@key}_model_discovery_enabled]"}
          label={dgettext("admin", "Enable model discovery")}
          value="true"
          checked={field_value(@form, @key, "model_discovery_enabled") in [true, "true", "on"]}
        />

        <.dm_input
          id={"provider-#{@key}-discovery-path"}
          name={"provider[#{@key}_model_discovery_path]"}
          label={dgettext("admin", "Model Discovery Path")}
          value={field_value(@form, @key, "model_discovery_path")}
        />

        <.dm_textarea
          id={"provider-#{@key}-default-headers"}
          name={"provider[#{@key}_default_headers]"}
          label={dgettext("admin", "Default Headers")}
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
            label={dgettext("admin", "Model")}
            value={@form[:model].value}
            placeholder="provider-model-id"
          />
          <.error errors={@errors} field="model" />
        </div>

        <.dm_input
          id={"#{@submit}-display-name"}
          name="model[display_name]"
          label={dgettext("admin", "Display Name")}
          value={@form[:display_name].value}
        />
      </div>

      <input type="hidden" name="model[enabled]" value="false" />
      <.dm_checkbox
        id={"#{@submit}-enabled"}
        name="model[enabled]"
        label={dgettext("admin", "Enable model")}
        value="true"
        checked={@form[:enabled].value in [true, "true", "on"]}
      />

      <div>
        <div class="mb-2 text-sm font-medium">{dgettext("admin", "API Surfaces")}</div>
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
        label={dgettext("admin", "Metadata")}
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

  defp protocol_enabled(api, protocol) do
    checkbox_value(protocol in api.native_protocols)
  end

  defp native_protocols_from_params(params, surface, default) do
    protocols = supported_protocols(surface)
    keys = Enum.map(protocols, &"#{&1}_enabled")

    if Enum.any?(keys, &Map.has_key?(params, &1)) do
      Enum.filter(protocols, &truthy?(params["#{&1}_enabled"]))
    else
      default
    end
  end

  defp protocols_for(provider, api) do
    case provider_preset(provider) do
      nil -> supported_protocols(api.api_surface)
      preset -> ProviderPreset.native_protocols(preset, api.api_surface)
    end
  end

  defp supported_protocols(:openai), do: [:openai_chat_completions, :openai_responses]
  defp supported_protocols(:anthropic), do: [:anthropic_messages]
  defp supported_protocols(:google), do: [:google_generate_content]
  defp supported_protocols(:antigravity), do: [:google_antigravity]

  defp surface_title(:openai), do: "OpenAI-compatible API"
  defp surface_title(:anthropic), do: "Anthropic Messages API"
  defp surface_title(:google), do: "Google GenerateContent API"
  defp surface_title(:antigravity), do: "Google Antigravity Native API"

  defp protocol_input_name(_key, protocol), do: "provider[#{protocol}_enabled]"

  defp protocol_input_id(_key, protocol),
    do: "provider-#{protocol |> Atom.to_string() |> String.replace("_", "-")}-enabled"

  defp protocol_label(:openai_chat_completions), do: "Chat Completions"
  defp protocol_label(:openai_responses), do: "Responses"
  defp protocol_label(:anthropic_messages), do: "Anthropic Messages"
  defp protocol_label(:google_generate_content), do: "Google GenerateContent"
  defp protocol_label(:google_antigravity), do: "Google Antigravity"

  defp protocol_field_value(form, protocol),
    do: form[String.to_atom("#{protocol}_enabled")].value

  defp form_value(form, key), do: form[key].value
end
