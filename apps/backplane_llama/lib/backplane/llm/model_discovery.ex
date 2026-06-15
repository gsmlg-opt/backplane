defmodule Backplane.LLM.ModelDiscovery do
  @moduledoc """
  Discovers provider models from configured API surfaces.
  """

  alias Backplane.LLM.{CredentialPlug, Provider, ProviderApi, ProviderModel, ProviderModelSurface}
  alias Backplane.Settings.Credentials

  @default_openai_codex_models ~w(gpt-5.5 gpt-5.4 gpt-5.4-mini gpt-5.3-codex)

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
    with {:ok, model_ids} <- discover_model_ids(provider, api) do
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

  defp discover_model_ids(provider, api) do
    if openai_codex_oauth_api?(provider, api) do
      {:ok, openai_codex_models()}
    else
      with {:ok, headers} <- discovery_headers(provider, api),
           {:ok, response} <- get_models(api, headers) do
        parse_model_ids(response.body)
      end
    end
  end

  defp openai_codex_oauth_api?(%Provider{} = provider, %ProviderApi{} = api) do
    provider.preset_key == "openai-codex" and
      api.api_surface == :openai and
      credential_auth_type(provider.credential) == "openai_oauth"
  end

  defp credential_auth_type(nil), do: nil

  defp credential_auth_type(name) do
    Credentials.list()
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> nil
      cred -> credential_metadata_auth_type(cred.metadata)
    end
  end

  defp openai_codex_models do
    Application.get_env(:backplane, :openai_codex_model_catalog) || @default_openai_codex_models
  end

  defp credential_metadata_auth_type(metadata) when is_map(metadata) do
    Map.get(metadata, "auth_type") || Map.get(metadata, :auth_type) || "api_key"
  end

  defp credential_metadata_auth_type(_metadata), do: "api_key"

  defp discovery_headers(provider, api) do
    with {:ok, auth_headers} <- CredentialPlug.build_auth_headers(provider, api.api_surface) do
      {:ok, auth_headers ++ default_header_pairs(api.default_headers)}
    end
  end

  defp get_models(api, headers) do
    url = discovery_url(api)

    url
    |> Req.get(req_options(url, headers))
    |> case do
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp req_options(url, headers) do
    [
      headers: headers,
      receive_timeout: 10_000
    ]
    |> Keyword.merge(default_req_options(url))
    |> Keyword.merge(Application.get_env(:backplane, :llm_model_discovery_req_options, []))
  end

  defp default_req_options(url) do
    case proxy_connect_options(url) do
      [] -> []
      connect_options -> [connect_options: connect_options]
    end
  end

  defp proxy_connect_options(url) do
    uri = URI.parse(url)

    if proxy_bypassed?(uri.host) do
      []
    else
      uri.scheme
      |> proxy_url_from_env()
      |> proxy_connect_options_from_url()
    end
  end

  defp proxy_url_from_env("https") do
    env("HTTPS_PROXY") || env("https_proxy") ||
      env("HTTP_PROXY") || env("http_proxy") ||
      env("ALL_PROXY") || env("all_proxy")
  end

  defp proxy_url_from_env("http") do
    env("HTTP_PROXY") || env("http_proxy") ||
      env("ALL_PROXY") || env("all_proxy")
  end

  defp proxy_url_from_env(_scheme), do: nil

  defp proxy_connect_options_from_url(nil), do: []

  defp proxy_connect_options_from_url(proxy_url) do
    uri = URI.parse(proxy_url)
    scheme = proxy_scheme(uri.scheme)

    cond do
      is_nil(scheme) or is_nil(uri.host) ->
        []

      is_binary(uri.userinfo) and uri.userinfo != "" ->
        [
          proxy: {scheme, uri.host, uri.port || default_proxy_port(scheme), []},
          proxy_headers: [{"proxy-authorization", "Basic " <> Base.encode64(uri.userinfo)}]
        ]

      true ->
        [proxy: {scheme, uri.host, uri.port || default_proxy_port(scheme), []}]
    end
  end

  defp proxy_scheme("http"), do: :http
  defp proxy_scheme("https"), do: :https
  defp proxy_scheme(_), do: nil

  defp default_proxy_port(:http), do: 80
  defp default_proxy_port(:https), do: 443

  defp proxy_bypassed?(nil), do: false

  defp proxy_bypassed?(host) do
    no_proxy = env("NO_PROXY") || env("no_proxy")
    no_proxy && no_proxy_match?(String.downcase(host), no_proxy)
  end

  defp no_proxy_match?(host, no_proxy) do
    no_proxy
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&no_proxy_entry_match?(host, String.downcase(&1)))
  end

  defp no_proxy_entry_match?(_host, "*"), do: true
  defp no_proxy_entry_match?(_host, ""), do: false

  defp no_proxy_entry_match?(host, "*." <> domain) do
    host == domain or String.ends_with?(host, "." <> domain)
  end

  defp no_proxy_entry_match?(host, "." <> domain) do
    host == domain or String.ends_with?(host, "." <> domain)
  end

  defp no_proxy_entry_match?(host, entry), do: host == entry

  defp env(name), do: System.get_env(name)

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
