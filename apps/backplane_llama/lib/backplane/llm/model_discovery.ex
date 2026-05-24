defmodule Backplane.LLM.ModelDiscovery do
  @moduledoc """
  Discovers provider models from configured API surfaces.
  """

  alias Backplane.LLM.{CredentialPlug, Provider, ProviderApi, ProviderModel, ProviderModelSurface}

  @type discovery_result :: %{
          discovered: non_neg_integer(),
          created: non_neg_integer(),
          updated: non_neg_integer(),
          errors: [String.t()]
        }

  @doc "Reload models for all discoverable API surfaces on a provider."
  @spec reload_provider(Provider.t()) :: discovery_result()
  def reload_provider(%Provider{} = provider) do
    provider
    |> discoverable_apis()
    |> Enum.reduce(empty_result(), fn api, result ->
      merge_results(result, reload_api(provider, api))
    end)
  end

  @doc "Reload models for one provider API surface."
  @spec reload_api(Provider.t(), ProviderApi.t()) :: discovery_result()
  def reload_api(%Provider{} = provider, %ProviderApi{} = api) do
    with {:ok, headers} <- discovery_headers(provider, api),
         {:ok, response} <- get_models(api, headers),
         {:ok, model_ids} <- parse_model_ids(response.body) do
      persist_models(provider, api, model_ids)
    else
      {:error, reason} ->
        add_error(empty_result(), "#{api.api_surface}: #{format_error(reason)}")
    end
  end

  defp discoverable_apis(%Provider{apis: apis}) when is_list(apis) do
    Enum.filter(apis, fn api ->
      api.enabled and api.model_discovery_enabled and not blank?(api.model_discovery_path)
    end)
  end

  defp discoverable_apis(_provider), do: []

  defp discovery_headers(provider, api) do
    with {:ok, auth_headers} <- CredentialPlug.build_auth_headers(provider, api.api_surface) do
      {:ok, auth_headers ++ default_header_pairs(api.default_headers)}
    end
  end

  defp get_models(api, headers) do
    api
    |> discovery_url()
    |> Req.get(
      Keyword.merge(
        [
          headers: headers,
          receive_timeout: 10_000
        ],
        Application.get_env(:backplane, :llm_model_discovery_req_options, [])
      )
    )
    |> case do
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp discovery_url(api) do
    path = api.model_discovery_path || default_discovery_path(api.api_surface)

    if String.starts_with?(path, ["http://", "https://"]) do
      path
    else
      String.trim_trailing(api.base_url, "/") <> "/" <> String.trim_leading(path, "/")
    end
  end

  defp default_discovery_path(:openai), do: "/models"
  defp default_discovery_path(:anthropic), do: "/v1/models"

  defp parse_model_ids(%{"data" => models}) when is_list(models), do: ids_from(models)
  defp parse_model_ids(%{"models" => models}) when is_list(models), do: ids_from(models)
  defp parse_model_ids(models) when is_list(models), do: ids_from(models)
  defp parse_model_ids(_), do: {:error, :invalid_model_list}

  defp ids_from(models) do
    ids =
      models
      |> Enum.map(&model_id/1)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    {:ok, ids}
  end

  defp model_id(%{"id" => id}) when is_binary(id), do: id
  defp model_id(%{"name" => name}) when is_binary(name), do: name
  defp model_id(model) when is_binary(model), do: model
  defp model_id(_), do: nil

  defp persist_models(provider, api, model_ids) do
    Enum.reduce(model_ids, empty_result(), fn model_id, result ->
      case upsert_model_surface(provider, api, model_id) do
        {:created, _model, _surface} ->
          %{result | discovered: result.discovered + 1, created: result.created + 1}

        {:updated, _model, _surface} ->
          %{result | discovered: result.discovered + 1, updated: result.updated + 1}

        {:error, reason} ->
          add_error(result, "#{model_id}: #{format_error(reason)}")
      end
    end)
    |> tap(fn _result ->
      ProviderApi.update(api, %{last_discovered_at: DateTime.utc_now()})
    end)
  end

  defp upsert_model_surface(provider, api, model_id) do
    case ProviderModel.get_by_provider_and_model(provider.id, model_id) do
      nil ->
        create_discovered_model(provider, api, model_id)

      %ProviderModel{} = model ->
        upsert_surface(:updated, model, api)
    end
  end

  defp create_discovered_model(provider, api, model_id) do
    with {:ok, model} <-
           ProviderModel.create(%{
             provider_id: provider.id,
             model: model_id,
             source: :discovered,
             enabled: true
           }),
         {:ok, surface} <- create_or_enable_surface(model, api) do
      {:created, model, surface}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_surface(status, model, api) do
    case create_or_enable_surface(model, api) do
      {:ok, surface} -> {status, model, surface}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_or_enable_surface(model, api) do
    attrs = %{
      provider_model_id: model.id,
      provider_api_id: api.id,
      enabled: true,
      last_seen_at: DateTime.utc_now()
    }

    case ProviderModelSurface.get_by_model_and_api(model.id, api.id) do
      nil -> ProviderModelSurface.create(attrs)
      surface -> ProviderModelSurface.update(surface, attrs)
    end
  end

  defp default_header_pairs(nil), do: []

  defp default_header_pairs(headers) when is_map(headers) do
    Enum.map(headers, fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)
  end

  defp empty_result, do: %{discovered: 0, created: 0, updated: 0, errors: []}

  defp merge_results(left, right) do
    %{
      discovered: left.discovered + right.discovered,
      created: left.created + right.created,
      updated: left.updated + right.updated,
      errors: left.errors ++ right.errors
    }
  end

  defp add_error(result, error), do: %{result | errors: result.errors ++ [error]}

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp format_error(%Ecto.Changeset{} = changeset), do: inspect(changeset.errors)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
