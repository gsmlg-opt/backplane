defmodule Backplane.LLM.ModelCatalog do
  @moduledoc "Aggregated model catalog served by `GET /v1/models`."

  alias Backplane.LLM.{
    AutoModel,
    ModelAlias,
    ModelMetadata,
    ModelResolver,
    Provider,
    ProviderApi
  }

  alias Backplane.Audio.{Binding, Config, Resolver}

  @spec entries() :: [map()]
  def entries do
    providers =
      Provider.list()
      |> Enum.filter(& &1.enabled)

    auto_models = AutoModel.list_configurations()
    custom_aliases = ModelAlias.list()
    provider_alias_names = ModelAlias.provider_names()

    resolver_names =
      MapSet.new(Enum.map(auto_models, & &1.name) ++ Enum.map(custom_aliases, & &1.alias))

    provider_entries =
      for provider <- providers,
          provider.name not in provider_alias_names,
          model <- provider.models,
          model.enabled do
        %{
          "id" => "#{provider.name}/#{model.model}",
          "object" => "model",
          "created" => 1_700_000_000,
          "owned_by" => provider.name,
          "provider" => provider.name,
          "canonical_id" => model.model
        }
      end

    auto_model_entries =
      for auto_model <- auto_models,
          auto_model.enabled do
        %{
          "id" => auto_model.name,
          "object" => "model",
          "created" => 1_700_000_000,
          "owned_by" => "backplane"
        }
      end

    custom_alias_entries =
      for model_alias <- custom_aliases do
        %{
          "id" => model_alias.alias,
          "object" => "model",
          "created" => 1_700_000_000,
          "owned_by" => "backplane"
        }
      end

    provider_alias_entries =
      for provider <- providers,
          provider.name in provider_alias_names,
          model <- provider.models,
          model.enabled do
        %{
          "id" => model.model,
          "object" => "model",
          "created" => 1_700_000_000,
          "owned_by" => provider.name,
          "provider" => provider.name,
          "canonical_id" => model.model
        }
      end

    # Build both namespaced and configured provider-alias targets from the
    # preloaded catalog. Later OpenAI targets take precedence over Anthropic.
    available_targets =
      for api_surface <- [:anthropic, :openai],
          provider <- providers,
          api <- provider.apis,
          api.enabled and api.api_surface == api_surface,
          model <- provider.models,
          model.enabled,
          surface <- model.surfaces,
          surface.enabled and surface.provider_api_id == api.id do
        {provider, model, surface, api}
      end

    provider_targets =
      Map.new(available_targets, fn {provider, model, _surface, _api} = target ->
        {"#{provider.name}/#{model.model}", target}
      end)

    provider_alias_targets =
      for api_surface <- [:anthropic, :openai],
          provider_name <- Enum.reverse(provider_alias_names),
          target <- available_targets,
          {provider, model, _surface, api} = target,
          provider.name == provider_name and api.api_surface == api_surface,
          into: %{} do
        {model.model, target}
      end

    entries =
      (provider_entries ++ auto_model_entries ++ custom_alias_entries ++ provider_alias_entries)
      |> Enum.uniq_by(& &1["id"])
      |> Enum.sort_by(& &1["id"])

    resolved_entries =
      for entry <- entries,
          target =
            selected_model_target(
              providers,
              provider_targets,
              provider_alias_targets,
              resolver_names,
              entry["id"]
            ),
          not is_nil(target) do
        {provider, model, surface, _api} = target
        raw_metadata = Map.merge(model.metadata || %{}, surface.metadata || %{})
        metadata = ModelMetadata.normalize(provider.preset_key, raw_metadata)
        Map.put(entry, "metadata", metadata)
      end

    audio_entries =
      if Config.enabled?() do
        enabled_bindings =
          Binding.list()
          |> Enum.filter(fn binding ->
            binding.enabled and binding.provider.enabled and is_nil(binding.provider.deleted_at) and
              binding.provider_model.enabled
          end)

        public_names =
          Enum.map(enabled_bindings, fn binding ->
            "#{binding.provider.name}/#{binding.provider_model.model}"
          end) ++
            Enum.map(custom_aliases, & &1.alias) ++
            for(
              binding <- enabled_bindings,
              binding.provider.name in provider_alias_names,
              do: binding.provider_model.model
            )

        for name <- Enum.uniq(public_names),
            Enum.any?([:speech, :transcription], fn operation ->
              match?({:ok, _}, Resolver.resolve(operation, name))
            end) do
          %{
            "id" => name,
            "object" => "model",
            "created" => 1_700_000_000,
            "owned_by" => "backplane"
          }
        end
      else
        []
      end

    (resolved_entries ++ audio_entries)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.sort_by(& &1["id"])
  end

  defp selected_model_target(
         providers,
         provider_targets,
         provider_alias_targets,
         resolver_names,
         id
       )
       when is_binary(id) do
    case String.split(id, "/", parts: 2) do
      [_provider_name, _raw_model] ->
        Map.get(provider_targets, id)

      [_alias_name] ->
        if MapSet.member?(resolver_names, id),
          do: selected_alias_target(providers, id),
          else: Map.get(provider_alias_targets, id)
    end
  end

  defp selected_alias_target(providers, id) do
    Enum.find_value([:openai, :anthropic], fn api_surface ->
      with {:ok, resolved_provider, raw_model} <- ModelResolver.resolve(api_surface, id),
           %Provider{} = provider <- Enum.find(providers, &(&1.id == resolved_provider.id)),
           %ProviderApi{} = api <-
             Enum.find(provider.apis, &(&1.enabled and &1.api_surface == api_surface)),
           model when not is_nil(model) <-
             Enum.find(provider.models, &(&1.enabled and &1.model == raw_model)),
           surface when not is_nil(surface) <-
             Enum.find(model.surfaces, &(&1.enabled and &1.provider_api_id == api.id)) do
        {provider, model, surface, api}
      else
        _ -> nil
      end
    end)
  end
end
