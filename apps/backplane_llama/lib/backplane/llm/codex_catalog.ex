defmodule Backplane.LLM.CodexCatalog do
  @moduledoc """
  Controlled projection of routable Backplane models into the Codex catalog.

  Catalog entries are an exposure policy. Provider credentials, model discovery,
  and request routing remain owned by the normal LLM registry and resolver.
  """

  import Ecto.Query

  alias Backplane.LLM.{
    CodexCatalogEntry,
    ModelDiscovery,
    ModelMetadata,
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface
  }

  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  @default_priority 100

  @type effective_entry :: %{
          entry: CodexCatalogEntry.t(),
          provider: Provider.t(),
          model: ProviderModel.t(),
          api: ProviderApi.t(),
          metadata: map(),
          descriptor: map()
        }

  @doc "List persisted policy entries in deterministic order."
  def list do
    CodexCatalogEntry
    |> order_by([entry], asc: entry.priority, asc: entry.public_model_id)
    |> Repo.all()
  end

  @doc "Fetch an entry by id."
  def get(id), do: Repo.get(CodexCatalogEntry, id)

  @doc "List enabled Codex providers with an eligible Responses API, without fetching secrets."
  def providers do
    Provider.list()
    |> Enum.filter(&(not is_nil(codex_api(&1))))
  end

  @doc "Import every model from a selected Codex provider."
  def import_provider(provider_id) when is_binary(provider_id) do
    with %Provider{} = provider <- Provider.get(provider_id),
         %ProviderApi{} = api <- codex_api(provider),
         {:ok, snapshot} <- ModelDiscovery.reload_codex_api(provider, api) do
      persist_snapshot(provider, api, snapshot, :all)
    else
      nil -> {:error, :invalid_codex_provider}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Refresh one saved Codex model from its provider's latest model listing."
  def refresh(entry_id) when is_binary(entry_id) do
    with %CodexCatalogEntry{} = entry <- get(entry_id),
         true <- imported_entry?(entry),
         {:ok, provider} <- source_provider(entry.source_model),
         %ProviderApi{} = api <- codex_api(provider),
         {:ok, snapshot} <- ModelDiscovery.reload_codex_api(provider, api),
         true <- Enum.any?(snapshot.models, &(&1["slug"] == entry.public_model_id)) do
      persist_snapshot(provider, api, snapshot, {:one, entry.id})
    else
      nil -> {:error, :invalid_codex_entry}
      false -> {:error, :model_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Create a catalog policy entry after validating its route and metadata."
  def create(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_attrs(attrs),
         :ok <- validate_source(attrs),
         :ok <- validate_reasoning(attrs) do
      result = %CodexCatalogEntry{} |> CodexCatalogEntry.changeset(attrs) |> Repo.insert()
      broadcast_on_ok(result)
    else
      {:error, reason} -> {:error, changeset_error(attrs, reason)}
    end
  end

  @doc "Update a catalog policy entry after validating its route and metadata."
  def update(%CodexCatalogEntry{} = entry, attrs) when is_map(attrs) do
    merged = Map.merge(Map.from_struct(entry), atomize(attrs))

    with {:ok, normalized} <- normalize_attrs(merged),
         :ok <- validate_source(normalized),
         :ok <- validate_reasoning(normalized) do
      result = entry |> CodexCatalogEntry.changeset(normalized) |> Repo.update()
      broadcast_on_ok(result)
    else
      {:error, reason} -> {:error, changeset_error(attrs, reason)}
    end
  end

  @doc "Delete a catalog policy entry."
  def delete(%CodexCatalogEntry{} = entry) do
    result = Repo.delete(entry)
    broadcast_on_ok(result)
  end

  @doc "Toggle whether a persisted entry is published."
  def toggle(%CodexCatalogEntry{enabled: true} = entry) do
    result = entry |> CodexCatalogEntry.changeset(%{enabled: false}) |> Repo.update()
    broadcast_on_ok(result)
  end

  def toggle(%CodexCatalogEntry{} = entry) do
    case effective_entry(entry) do
      {:ok, _resolved} ->
        entry
        |> CodexCatalogEntry.changeset(%{enabled: true})
        |> Repo.update()
        |> broadcast_on_ok()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Return all routable OpenAI Responses targets for the admin selector."
  def candidates do
    from(model in ProviderModel,
      join: provider in assoc(model, :provider),
      join: surface in assoc(model, :surfaces),
      join: api in assoc(surface, :provider_api),
      where:
        provider.enabled == true and is_nil(provider.deleted_at) and model.enabled == true and
          surface.enabled == true and api.enabled == true and api.api_surface == :openai,
      preload: [provider: provider, surfaces: {surface, provider_api: api}],
      order_by: [asc: provider.name, asc: model.model]
    )
    |> Repo.all()
    |> Enum.filter(&(eligible_provider?(&1.provider) and responses_surface?(&1)))
    |> Enum.map(fn model ->
      %{
        source_model: "#{model.provider.name}/#{model.model}",
        provider: model.provider.name,
        model: model.model,
        display_name: model.display_name || model.model,
        metadata: canonical_metadata(model, model.provider)
      }
    end)
    |> Enum.uniq_by(& &1.source_model)
  end

  @doc "Return effective, valid enabled entries and invalid enabled entries."
  def effective do
    Enum.reduce(list(), {[], []}, fn entry, {valid, invalid} ->
      if entry.enabled do
        case effective_entry(entry) do
          {:ok, resolved} -> {[resolved | valid], invalid}
          {:error, reason} -> {valid, [{entry, reason} | invalid]}
        end
      else
        {valid, invalid}
      end
    end)
    |> then(fn {valid, invalid} ->
      {Enum.reverse(valid), Enum.reverse(invalid)}
    end)
  end

  @doc "Serialize the same effective projection used by the HTTP endpoint and preview."
  def response do
    {entries, invalid} = effective()
    {%{"models" => Enum.map(entries, & &1.descriptor)}, invalid}
  end

  @doc "Resolve an enabled public Codex id to its existing Backplane route target."
  def target_for(public_model_id) when is_binary(public_model_id) do
    case Repo.get_by(CodexCatalogEntry, public_model_id: public_model_id, enabled: true) do
      %CodexCatalogEntry{} = entry ->
        case effective_entry(entry) do
          {:ok, _resolved} -> entry.source_model
          _ -> nil
        end

      nil ->
        nil
    end
  end

  @doc "Build an effective entry for preview and diagnostics."
  def effective_entry(%CodexCatalogEntry{} = entry) do
    with true <- imported_entry?(entry),
         {:ok, provider} <- source_provider(entry.source_model),
         true <- eligible_provider?(provider),
         {:ok, resolved_provider, raw_model} <- ModelResolver.resolve(:openai, entry.source_model),
         true <- resolved_provider.id == provider.id and raw_model == entry.public_model_id,
         %ProviderModel{} = model <-
           ProviderModel.get_by_provider_and_model(provider.id, raw_model),
         %ProviderApi{} = api <- responses_api(provider.id),
         true <- :openai_responses in api.native_protocols,
         true <- model.enabled and provider.enabled and is_nil(provider.deleted_at),
         %ProviderModelSurface{} <- responses_surface(model.id, api.id),
         metadata <- entry.metadata["codex_raw"],
         descriptor <- descriptor(entry, metadata) do
      {:ok,
       %{
         entry: entry,
         provider: provider,
         model: model,
         api: api,
         metadata: metadata,
         descriptor: descriptor
       }}
    else
      false -> {:error, :route_unavailable}
      nil -> {:error, :route_unavailable}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :route_unavailable}
    end
  end

  defp descriptor(_entry, metadata), do: metadata

  @doc "Serialize one model using the current Codex ModelInfo wire contract."
  def serialize_model(
        public_model_id,
        display_name,
        description,
        metadata,
        priority \\ @default_priority
      ) do
    descriptor =
      metadata
      |> apply_reasoning_default_override()
      |> then(fn metadata ->
        ModelMetadata.codex(public_model_id, display_name, metadata,
          supported_in_api: true,
          priority: priority
        )
      end)
      |> Map.merge(%{
        "slug" => public_model_id,
        "display_name" => display_name || metadata["display_name"] || public_model_id,
        "description" => description,
        "supported_in_api" => true,
        "priority" => priority
      })

    descriptor
    |> wire_defaults()
    |> apply_schema_defaults(metadata)
    |> Map.drop([
      "max_output_tokens",
      "supports_reasoning_summaries",
      "supports_parallel_tool_calls"
    ])
  end

  defp apply_reasoning_default_override(%{"default_reasoning_level" => effort} = metadata)
       when is_binary(effort) do
    raw = if is_map(metadata["raw"]), do: metadata["raw"], else: %{}
    Map.put(metadata, "raw", Map.put(raw, "default_reasoning_level", effort))
  end

  defp apply_reasoning_default_override(metadata), do: metadata

  defp apply_schema_defaults(descriptor, metadata) do
    raw = if is_map(metadata["raw"]), do: metadata["raw"], else: %{}

    descriptor
    |> maybe_default(raw, "include_apps_usage_instructions", true)
    |> maybe_default(raw, "supports_reasoning_summary_parameter", true)
  end

  defp maybe_default(descriptor, raw, key, default) do
    if Map.has_key?(raw, key), do: descriptor, else: Map.put(descriptor, key, default)
  end

  defp wire_defaults(descriptor) do
    Map.merge(
      %{
        "description" => nil,
        "default_reasoning_level" => nil,
        "supported_reasoning_levels" => [],
        "shell_type" => "unified_exec",
        "visibility" => "list",
        "supported_in_api" => true,
        "priority" => @default_priority,
        "additional_speed_tiers" => [],
        "service_tiers" => [],
        "default_service_tier" => nil,
        "available_access_programs" => nil,
        "availability_nux" => nil,
        "upgrade" => nil,
        "base_instructions" => descriptor["base_instructions"] || "",
        "model_messages" => descriptor["model_messages"],
        "include_skills_usage_instructions" => false,
        "include_plugin_usage_instructions" => false,
        "include_apps_usage_instructions" => false,
        "supports_reasoning_summary_parameter" => true,
        "default_reasoning_summary" => "auto",
        "support_verbosity" => false,
        "default_verbosity" => nil,
        "apply_patch_tool_type" => nil,
        "web_search_tool_type" => "text",
        "supports_image_detail_original" => false,
        "max_context_window" => nil,
        "auto_compact_token_limit" => nil,
        "comp_hash" => nil,
        "effective_context_window_percent" => 95,
        "experimental_supported_tools" => [],
        "input_modalities" => ["text"],
        "supports_search_tool" => false,
        "supports_experimental_context" => false,
        "use_responses_lite" => false,
        "supports_reasoning_effort_updates" => false,
        "node_repl_auto_review_required" => false,
        "node_repl_disabled" => false,
        "auto_review_model_override" => nil,
        "model_specialty" => nil,
        "tool_mode" => nil,
        "multi_agent_version" => nil,
        "multi_agent_reasoning_effort" => nil
      },
      descriptor
    )
  end

  defp canonical_metadata(model, provider) do
    ModelMetadata.normalize(provider.preset_key, model.metadata || %{})
  end

  defp responses_api(provider_id) do
    ProviderApi
    |> where(
      [api],
      api.provider_id == ^provider_id and api.api_surface == :openai and api.enabled
    )
    |> Repo.one()
  end

  defp responses_surface(model_id, api_id) do
    ProviderModelSurface
    |> where(
      [surface],
      surface.provider_model_id == ^model_id and surface.provider_api_id == ^api_id and
        surface.enabled
    )
    |> Repo.one()
  end

  defp responses_surface?(%ProviderModel{surfaces: surfaces}) do
    Enum.any?(surfaces, fn surface ->
      ((surface.enabled and surface.provider_api) && surface.provider_api.enabled) and
        :openai_responses in surface.provider_api.native_protocols
    end)
  end

  defp validate_source(attrs) do
    source = Map.get(attrs, :source_model) || Map.get(attrs, "source_model")

    cond do
      blank?(source) -> {:error, :source_model_required}
      routable_source?(source) -> :ok
      true -> {:error, :route_unavailable}
    end
  end

  defp validate_reasoning(attrs) do
    metadata = Map.get(attrs, :reasoning_metadata) || Map.get(attrs, "reasoning_metadata") || %{}

    levels =
      Map.get(metadata, "supported_reasoning_levels") ||
        Map.get(metadata, :supported_reasoning_levels)

    if is_nil(levels) or (is_list(levels) and valid_levels?(levels)),
      do: :ok,
      else: {:error, :invalid_reasoning_metadata}
  end

  defp valid_levels?(levels) when is_list(levels) do
    Enum.all?(levels, fn
      effort when is_binary(effort) -> valid_effort?(effort)
      %{"effort" => effort} -> valid_effort?(effort)
      %{effort: effort} -> valid_effort?(effort)
      _ -> false
    end)
  end

  defp routable_source?(source) do
    with {:ok, provider} <- source_provider(source),
         true <- eligible_provider?(provider),
         {:ok, resolved_provider, raw_model} <- ModelResolver.resolve(:openai, source),
         true <- resolved_provider.id == provider.id,
         %ProviderModel{} = model <-
           ProviderModel.get_by_provider_and_model(provider.id, raw_model),
         %ProviderApi{} = api <- responses_api(provider.id),
         true <- :openai_responses in api.native_protocols,
         true <- model.enabled and provider.enabled and is_nil(provider.deleted_at),
         %ProviderModelSurface{} <- responses_surface(model.id, api.id) do
      true
    else
      _ -> false
    end
  end

  defp normalize_attrs(attrs) do
    attrs = atomize(attrs)

    attrs =
      attrs
      |> Map.update(:public_model_id, nil, &trim_string/1)
      |> Map.update(:source_model, nil, &trim_string/1)
      |> Map.update(:priority, @default_priority, &normalize_priority/1)
      |> Map.update(:enabled, false, &truthy?/1)
      |> Map.update(:reasoning_metadata, %{}, &if(is_map(&1), do: &1, else: %{}))
      |> Map.update(:metadata, %{}, &if(is_map(&1), do: &1, else: %{}))

    {:ok, attrs}
  end

  defp atomize(attrs) do
    Map.new(attrs, fn {key, value} ->
      {if(is_binary(key), do: String.to_existing_atom(key), else: key), value}
    end)
  rescue
    ArgumentError -> attrs
  end

  defp normalize_priority(value) when is_integer(value), do: value

  defp normalize_priority(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> value
    end
  end

  defp normalize_priority(value), do: value

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

  defp blank?(value), do: !is_binary(value) or String.trim(value) == ""
  defp valid_effort?(value), do: is_binary(value) and String.trim(value) != ""

  defp codex_api(%Provider{} = provider) do
    if eligible_provider?(provider) do
      apis =
        case provider.apis do
          %Ecto.Association.NotLoaded{} -> ProviderApi.list_for_provider(provider.id)
          apis -> apis
        end

      Enum.find(apis, fn api ->
        api.enabled and api.api_surface == :openai and api.model_discovery_enabled and
          :openai_responses in api.native_protocols
      end)
    end
  end

  defp eligible_provider?(%Provider{} = provider) do
    provider.enabled and is_nil(provider.deleted_at) and
      provider.preset_key == "openai-codex" and oauth_credential?(provider.credential)
  end

  defp oauth_credential?(name) do
    Enum.any?(Credentials.list(), fn credential ->
      credential.name == name and
        (credential.metadata || %{})["auth_type"] == "openai_oauth"
    end)
  end

  defp source_provider(source) when is_binary(source) do
    case String.split(source, "/", parts: 2) do
      [name, slug] when name != "" and slug != "" ->
        provider =
          Provider
          |> where([row], row.name == ^name and is_nil(row.deleted_at))
          |> Repo.one()

        case provider do
          %Provider{} = provider -> {:ok, provider}
          nil -> {:error, :invalid_codex_provider}
        end

      _ ->
        {:error, :invalid_codex_provider}
    end
  end

  defp source_provider(_), do: {:error, :invalid_codex_provider}

  defp imported_entry?(%CodexCatalogEntry{} = entry) do
    case (entry.metadata || %{})["codex_raw"] do
      %{"slug" => slug} when is_binary(slug) -> slug == entry.public_model_id
      _ -> false
    end
  end

  defp persist_snapshot(provider, api, snapshot, selection) do
    result =
      Repo.transaction(fn ->
        current_provider =
          Provider
          |> where([row], row.id == ^provider.id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        current_api =
          ProviderApi
          |> where([row], row.id == ^api.id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        unless current_provider && current_api &&
                 current_provider.name == provider.name &&
                 current_provider.credential == provider.credential &&
                 current_api.updated_at == snapshot.api_updated_at &&
                 current_api.provider_id == provider.id &&
                 codex_api(current_provider) do
          Repo.rollback(:discovery_configuration_changed)
        end

        case selection do
          :all ->
            Enum.reduce(snapshot.models, %{created: 0, refreshed: 0, retained: 0}, fn raw,
                                                                                      counts ->
              {status, _entry} = upsert_imported_entry(current_provider, raw)
              Map.update!(counts, status, &(&1 + 1))
            end)

          {:one, entry_id} ->
            entry =
              CodexCatalogEntry
              |> where([row], row.id == ^entry_id)
              |> lock("FOR UPDATE")
              |> Repo.one()

            unless entry, do: Repo.rollback(:invalid_codex_entry)

            raw = Enum.find(snapshot.models, &(&1["slug"] == entry.public_model_id))

            unless (raw && imported_entry?(entry)) and
                     entry.source_model == "#{current_provider.name}/#{raw["slug"]}" do
              Repo.rollback(:invalid_codex_entry)
            end

            {_status, updated} = upsert_imported_entry(current_provider, raw)
            updated
        end
      end)

    case result do
      {:ok, value} ->
        ModelResolver.clear_cache()
        Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
        {:ok, value}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_imported_entry(provider, %{"slug" => slug} = raw) do
    source_model = "#{provider.name}/#{slug}"

    attrs = %{
      public_model_id: slug,
      source_model: source_model,
      display_name: raw["display_name"],
      description: raw["description"],
      priority: if(is_integer(raw["priority"]), do: raw["priority"], else: @default_priority),
      context_window_override: nil,
      reasoning_metadata: %{},
      metadata: %{"codex_raw" => raw}
    }

    case Repo.get_by(CodexCatalogEntry, public_model_id: slug) do
      nil ->
        case %CodexCatalogEntry{}
             |> CodexCatalogEntry.changeset(Map.put(attrs, :enabled, true))
             |> Repo.insert() do
          {:ok, entry} -> {:created, entry}
          {:error, reason} -> Repo.rollback(reason)
        end

      %CodexCatalogEntry{source_model: ^source_model} = entry ->
        if Map.take(entry, Map.keys(attrs)) == attrs do
          {:retained, entry}
        else
          case entry |> CodexCatalogEntry.changeset(attrs) |> Repo.update() do
            {:ok, updated} -> {:refreshed, updated}
            {:error, reason} -> Repo.rollback(reason)
          end
        end

      _entry ->
        Repo.rollback({:model_conflict, slug})
    end
  end

  defp changeset_error(attrs, reason) do
    field =
      if reason in [:route_unavailable, :source_model_required],
        do: :source_model,
        else: :reasoning_metadata

    attrs
    |> atomize()
    |> then(&CodexCatalogEntry.changeset(%CodexCatalogEntry{}, &1))
    |> Ecto.Changeset.add_error(field, format_reason(reason))
  end

  defp format_reason(:route_unavailable), do: "must resolve to an enabled OpenAI Responses route"
  defp format_reason(:source_model_required), do: "must not be blank"

  defp format_reason(:invalid_reasoning_metadata),
    do: "contains unsupported reasoning effort values"

  defp broadcast_on_ok({:ok, _} = result) do
    Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
    result
  end

  defp broadcast_on_ok(result), do: result
end
