defmodule Backplane.LLM.ModelDiscovery do
  @moduledoc """
  Discovers provider models from configured API surfaces.
  """

  import Ecto.Query

  alias Backplane.LLM.{
    CredentialPlug,
    OpenAICodex,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface
  }

  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  defmodule ModelDetail do
    @moduledoc false

    defstruct [:id, :metadata]

    @type t :: %__MODULE__{id: String.t(), metadata: map()}
  end

  @default_google_antigravity_models ~w(
    gemini-3.1-pro-high
    gemini-3.1-pro-low
    gemini-3.1-flash-lite
    gemini-3.5-flash-low
    claude-opus-4-6
    claude-opus-4-6-thinking
    claude-sonnet-4-6
    gpt-oss-120b
  )

  @discovery_stale_key "backplane_discovery_stale"
  @default_openai_codex_client_version "0.0.0"
  @request_timeout_ms 10_000

  @type discovery_result :: %{
          discovered: non_neg_integer(),
          created: non_neg_integer(),
          updated: non_neg_integer(),
          errors: [String.t()]
        }

  @doc "Reload models for all discoverable API surfaces on a provider."
  @spec reload_provider(Provider.t()) :: discovery_result()
  def reload_provider(%Provider{apis: %Ecto.Association.NotLoaded{}} = provider) do
    case Provider.get(provider.id) do
      %Provider{} = provider -> reload_provider(provider)
      nil -> empty_result()
    end
  end

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
    with {:ok, model_details} <- discover_model_details(provider, api) do
      persist_models(provider, api, model_details)
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

  defp discover_model_details(provider, api) do
    cond do
      openai_codex_oauth_api?(provider, api) ->
        emit_discovery_started(provider, :remote)

        with {:ok, headers} <- discovery_headers(provider, api),
             {:ok, response} <- get_models(api, headers, codex: true) do
          case parse_codex_model_details(response.body) do
            {:ok, details} ->
              emit_discovery_completed(provider, :remote, details)
              {:ok, details}

            {:error, reason} ->
              emit_discovery_failed(provider, :remote, reason)
              {:error, reason}
          end
        else
          {:error, reason} ->
            emit_discovery_failed(provider, :remote, reason)
            {:error, reason}
        end

      google_antigravity_oauth_api?(provider, api) ->
        details = Enum.map(google_antigravity_models(), &%ModelDetail{id: &1, metadata: %{}})
        {:ok, details}

      true ->
        with {:ok, headers} <- discovery_headers(provider, api),
             {:ok, response} <- get_models(api, headers) do
          parse_model_details(response.body)
        end
    end
  end

  defp emit_discovery_started(provider, source) do
    :telemetry.execute(
      [:backplane, :codex, :models, :discovery, :started],
      %{},
      discovery_metadata(provider, source)
    )
  end

  defp emit_discovery_completed(provider, source, details) do
    :telemetry.execute(
      [:backplane, :codex, :models, :discovery, :completed],
      %{count: length(details)},
      discovery_metadata(provider, source)
    )
  end

  defp emit_discovery_failed(provider, source, reason) do
    :telemetry.execute(
      [:backplane, :codex, :models, :discovery, :failed],
      %{},
      provider
      |> discovery_metadata(source)
      |> Map.put(:error_class, format_error(reason))
    )
  end

  defp discovery_metadata(provider, source) do
    %{
      provider_id: provider.id,
      provider_name: provider.name,
      endpoint: "models",
      source: source
    }
  end

  defp google_antigravity_oauth_api?(%Provider{} = provider, %ProviderApi{} = api) do
    provider.preset_key == "google-ai-studio" and
      api.api_surface == :openai and
      credential_auth_type(provider.credential) == "google_oauth"
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

  defp google_antigravity_models do
    Application.get_env(:backplane, :google_antigravity_model_catalog) ||
      @default_google_antigravity_models
  end

  defp credential_metadata_auth_type(metadata) when is_map(metadata) do
    Map.get(metadata, "auth_type") || Map.get(metadata, :auth_type) || "api_key"
  end

  defp credential_metadata_auth_type(_metadata), do: "api_key"

  defp discovery_headers(provider, api) do
    if openai_codex_oauth_api?(provider, api) do
      codex_discovery_headers(provider, api)
    else
      generic_discovery_headers(provider, api)
    end
  end

  defp codex_discovery_headers(provider, api) do
    with {:ok, token, meta} <- Credentials.fetch_with_meta(provider.credential) do
      {replace_headers, default_headers} =
        CredentialPlug.codex_headers(token, meta, provider.default_headers)

      headers =
        replace_headers
        |> Enum.reject(fn {_name, value} -> is_nil(value) end)
        |> put_default_headers(default_headers)
        |> put_default_headers(codex_api_default_headers(api.default_headers))

      {:ok, put_header_new(headers, "content-type", "application/json")}
    end
  end

  defp generic_discovery_headers(provider, api) do
    with {:ok, auth_headers} <- CredentialPlug.build_auth_headers(provider, api.api_surface) do
      headers = put_default_headers(auth_headers, default_header_pairs(api.default_headers))
      {:ok, put_header_new(headers, "content-type", "application/json")}
    end
  end

  defp codex_api_default_headers(headers) do
    headers
    |> default_header_pairs()
    |> Enum.reject(fn {name, _value} ->
      name in OpenAICodex.provider_owned_headers()
    end)
  end

  defp put_default_headers(headers, defaults) do
    Enum.reduce(defaults, headers, fn {name, value}, acc ->
      put_header_new(acc, String.downcase(to_string(name)), to_string(value))
    end)
  end

  defp put_header_new(headers, key, value) do
    if Enum.any?(headers, fn {header, _value} -> String.downcase(header) == key end) do
      headers
    else
      [{key, value} | headers]
    end
  end

  defp get_models(api, headers, opts \\ []) do
    url = discovery_url(api)

    url = if Keyword.get(opts, :codex, false), do: put_codex_client_version(url), else: url

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
      receive_timeout: @request_timeout_ms
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
          proxy: proxy_tuple(scheme, uri),
          proxy_headers: [{"proxy-authorization", "Basic " <> Base.encode64(uri.userinfo)}]
        ]

      true ->
        [proxy: proxy_tuple(scheme, uri)]
    end
  end

  defp proxy_tuple(scheme, uri) do
    options = [
      transport_opts: [timeout: @request_timeout_ms],
      tunnel_timeout: @request_timeout_ms
    ]

    {scheme, uri.host, uri.port || default_proxy_port(scheme), options}
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

  defp parse_model_details(%{"data" => models}) when is_list(models),
    do: if(models == [], do: {:error, :empty_model_list}, else: parse_model_details(models))

  defp parse_model_details(%{"models" => models}) when models == [],
    do: {:error, :empty_model_list}

  defp parse_model_details(%{"models" => models}) when is_list(models),
    do: parse_model_details(models)

  defp parse_model_details(models) when is_list(models),
    do: details_from(models, &model_detail/1)

  defp parse_model_details(_), do: {:error, :invalid_model_list}

  defp parse_codex_model_details(%{"models" => models}) when models == [],
    do: {:error, :empty_model_list}

  defp parse_codex_model_details(%{"data" => models}) when models == [],
    do: {:error, :empty_model_list}

  defp parse_codex_model_details(%{"models" => models}) when is_list(models),
    do: details_from(models, &codex_model_detail/1)

  defp parse_codex_model_details(_), do: {:error, :invalid_model_list}

  defp details_from(models, extractor) do
    models
    |> Enum.map(extractor)
    |> Enum.reduce_while({:ok, []}, fn
      %ModelDetail{} = detail, {:ok, details} ->
        {:cont, {:ok, [detail | details]}}

      nil, _details ->
        {:halt, {:error, :empty_model_list}}
    end)
    |> case do
      {:ok, details} -> {:ok, details |> Enum.reverse() |> Enum.uniq_by(& &1.id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp model_detail(model) when is_map(model) do
    id = model_id(model)

    if blank?(id) do
      nil
    else
      %ModelDetail{id: id, metadata: normalize_metadata(model)}
    end
  end

  defp model_detail(model) when is_binary(model) do
    if blank?(model), do: nil, else: %ModelDetail{id: model, metadata: %{}}
  end

  defp model_detail(_model), do: nil

  defp codex_model_detail(%{"slug" => slug} = model) when is_binary(slug) do
    if blank?(slug) do
      nil
    else
      %ModelDetail{id: slug, metadata: normalize_metadata(model)}
    end
  end

  defp codex_model_detail(_model), do: nil

  defp model_id(%{"slug" => slug}) when is_binary(slug), do: slug
  defp model_id(%{"id" => id}) when is_binary(id), do: id
  defp model_id(%{"name" => name}) when is_binary(name), do: name
  defp model_id(_), do: nil

  defp normalize_metadata(model) when is_map(model),
    do: Map.new(model, fn {key, value} -> {to_string(key), value} end)

  defp persist_models(provider, api, model_details) do
    Enum.reduce(model_details, empty_result(), fn %ModelDetail{} = detail, result ->
      case persist_model_surface(provider, api, detail) do
        {:created, _model, _surface} ->
          %{result | discovered: result.discovered + 1, created: result.created + 1}

        {:updated, _model, _surface} ->
          %{result | discovered: result.discovered + 1, updated: result.updated + 1}

        {:error, reason} ->
          add_error(result, "#{detail.id}: #{format_error(reason)}")
      end
    end)
    |> maybe_prune_stale_models(provider, api, model_details)
    |> maybe_record_discovered_at(api)
  end

  defp persist_model_surface(provider, api, detail) do
    Repo.transaction(fn ->
      case upsert_model_surface(provider, api, detail) do
        {:error, reason} -> Repo.rollback(reason)
        result -> result
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_prune_stale_models(%{errors: []} = result, provider, api, model_ids) do
    remove_stale_model_surfaces(provider, api, model_ids)
    disable_orphan_discovered_models(provider)

    result
  end

  defp maybe_prune_stale_models(result, _provider, _api, _model_ids), do: result

  defp maybe_record_discovered_at(%{errors: []} = result, api) do
    case ProviderApi.update(api, %{last_discovered_at: DateTime.utc_now()}) do
      {:ok, _api} -> result
      {:error, reason} -> add_error(result, "last_discovered_at: #{format_error(reason)}")
    end
  end

  defp maybe_record_discovered_at(result, _api), do: result

  defp remove_stale_model_surfaces(provider, api, [] = _model_ids) do
    ProviderModelSurface
    |> join(:inner, [surface], model in ProviderModel, on: model.id == surface.provider_model_id)
    |> where(
      [surface, model],
      model.provider_id == ^provider.id and surface.provider_api_id == ^api.id and
        model.source == :discovered
    )
    |> Repo.delete_all()
  end

  defp remove_stale_model_surfaces(provider, api, model_details) do
    model_ids = Enum.map(model_details, & &1.id)

    ProviderModelSurface
    |> join(:inner, [surface], model in ProviderModel, on: model.id == surface.provider_model_id)
    |> where(
      [surface, model],
      model.provider_id == ^provider.id and surface.provider_api_id == ^api.id and
        model.source == :discovered and model.model not in ^model_ids
    )
    |> Repo.delete_all()
  end

  defp upsert_model_surface(provider, api, %ModelDetail{} = detail) do
    case ProviderModel.get_by_provider_and_model(provider.id, detail.id) do
      nil ->
        create_discovered_model(provider, api, detail)

      %ProviderModel{} = model ->
        upsert_surface(:updated, model, api, model_metadata(model, detail, api))
    end
  end

  defp create_discovered_model(provider, api, %ModelDetail{} = detail) do
    metadata = model_metadata(nil, detail, api)

    with {:ok, model} <-
           ProviderModel.create(%{
             provider_id: provider.id,
             model: detail.id,
             source: :discovered,
             enabled: true,
             display_name: detail.id,
             metadata: metadata
           }),
         {:ok, surface} <- create_or_refresh_surface(model, api, metadata) do
      {:created, model, surface}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_surface(status, model, api, metadata) do
    attrs =
      if revive_discovered_model?(model) do
        %{enabled: true, metadata: metadata}
      else
        %{metadata: metadata}
      end

    with {:ok, model} <- ProviderModel.update(model, attrs) do
      case create_or_refresh_surface(model, api, metadata) do
        {:ok, surface} -> {status, model, surface}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp create_or_refresh_surface(model, api, metadata) do
    attrs = %{
      provider_model_id: model.id,
      provider_api_id: api.id,
      last_seen_at: DateTime.utc_now(),
      metadata: metadata
    }

    case ProviderModelSurface.get_by_model_and_api(model.id, api.id) do
      nil ->
        ProviderModelSurface.create(Map.put(attrs, :enabled, true))

      surface ->
        ProviderModelSurface.update(
          surface,
          Map.put(attrs, :metadata, Map.merge(surface.metadata || %{}, metadata))
        )
    end
  end

  defp disable_orphan_discovered_models(provider) do
    orphan_model_ids =
      ProviderModel
      |> join(:left, [model], surface in ProviderModelSurface,
        on: surface.provider_model_id == model.id
      )
      |> where([model], model.provider_id == ^provider.id and model.source == :discovered)
      |> group_by([model], model.id)
      |> having([_model, surface], count(surface.id) == 0)
      |> select([model], model.id)

    ProviderModel
    |> where([model], model.id in subquery(orphan_model_ids))
    |> Repo.update_all(set: [enabled: false])
  end

  defp model_metadata(nil, %ModelDetail{metadata: metadata}, api) do
    Map.put(metadata, "api_surface", Atom.to_string(api.api_surface))
  end

  defp model_metadata(model, %ModelDetail{metadata: metadata}, api) do
    upstream_metadata =
      metadata
      |> Map.put("api_surface", Atom.to_string(api.api_surface))
      |> Map.put("slug", model.model)

    (model.metadata || %{})
    |> Map.delete(@discovery_stale_key)
    |> Map.merge(upstream_metadata)
  end

  defp revive_discovered_model?(%ProviderModel{} = model) do
    model.source == :discovered and model.enabled == false and
      (model.surfaces == [] or (model.metadata || %{})[@discovery_stale_key] == true)
  end

  defp put_codex_client_version(url) do
    client_version =
      Application.get_env(:backplane, :openai_codex_client_version) ||
        System.get_env("OPENAI_CODEX_CLIENT_VERSION") ||
        @default_openai_codex_client_version

    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")

    if blank?(query["client_version"]) and not blank?(client_version) do
      %{uri | query: URI.encode_query(Map.put(query, "client_version", client_version))}
      |> URI.to_string()
    else
      url
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
