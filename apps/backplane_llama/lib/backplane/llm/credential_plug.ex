defmodule Backplane.LLM.CredentialPlug do
  @moduledoc """
  Strips client auth headers and injects provider API credentials into a conn.

  Dispatches on both `provider.api_type` and the credential's `auth_type`:

  - api_type `:anthropic` + auth_type `api_key` / `oauth2_client_credentials`:
    sets `x-api-key`, adds `anthropic-version`.
  - api_type `:anthropic` + auth_type `anthropic_oauth`:
    sets `Authorization: Bearer …`, adds `anthropic-beta: oauth-2025-04-20`
    and `anthropic-version`.
  - api_type `:openai` (any auth_type): sets `Authorization: Bearer …`.
  """

  alias Backplane.LLM.{HeaderPolicy, OpenAICodex, Provider, ProviderApi}
  alias Backplane.Settings.Credentials
  alias Backplane.Settings.{Credential, Encryption}
  import Plug.Conn

  @default_anthropic_version "2023-06-01"

  @doc """
  Inject provider credentials into `conn`. Derives `api_type` from
  `provider.api_type`.
  """
  @spec inject(Plug.Conn.t(), Provider.t(), ProviderApi.t() | nil) :: Plug.Conn.t()
  def inject(conn, provider, provider_api \\ nil)

  def inject(%Plug.Conn{} = conn, %Provider{api_type: api_type} = provider, provider_api)
      when api_type in [:anthropic, :openai] do
    case resolve_credential(provider) do
      {:ok, token, meta} ->
        api_defaults = api_default_headers(provider_api)

        defaults =
          HeaderPolicy.merge_defaults(provider.default_headers, api_defaults, surface: api_type)

        conn
        |> maybe_apply_anthropic_version(api_type)
        |> merge_default_headers(defaults)
        |> apply_extra_headers(meta.extra_headers)
        |> apply_auth_headers(provider, api_type, meta.auth_type, token)

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Formata.JSON.encode!(%{error: "provider credential not configured"}))
        |> halt()
    end
  end

  def inject(%Plug.Conn{} = conn, %Provider{}, _provider_api) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, Formata.JSON.encode!(%{error: "provider API surface not configured"}))
    |> halt()
  end

  @doc """
  Build authentication headers for a provider without a conn.

  Returns `{:ok, headers}` where headers is a list of `{key, value}` tuples,
  or `{:error, reason}`.

  Accepts an optional explicit `api_type` and `provider_api` — used by
  production callers (router, health checker, model discovery) that know the
  surface from context. Provider and API default headers are normalized
  case-insensitively with API defaults overriding Provider defaults, while
  protected credential and server-owned headers always win last.
  """
  @spec build_auth_headers(Provider.t(), atom(), ProviderApi.t() | nil) ::
          {:ok, [{String.t(), String.t() | nil}]} | {:error, atom()}
  def build_auth_headers(
        %Provider{host_service_id: id, credential: credential} = provider,
        api_type,
        provider_api
      )
      when is_binary(id) and credential in [nil, ""] and api_type in [:anthropic, :openai] do
    defaults =
      HeaderPolicy.merge_defaults(
        provider.default_headers,
        api_default_headers(provider_api),
        surface: api_type
      )

    headers =
      HeaderPolicy.merge_ordered(
        [anthropic_version_pair(api_type), defaults],
        keep_nil: true
      )

    {:ok, headers}
  end

  def build_auth_headers(%Provider{} = provider, api_type, provider_api)
      when api_type in [:anthropic, :antigravity, :google, :openai] do
    case resolve_surface_credential(provider, api_type) do
      {:ok, token, meta} ->
        defaults =
          HeaderPolicy.merge_defaults(
            provider.default_headers,
            api_default_headers(provider_api),
            surface: api_type
          )

        headers =
          HeaderPolicy.merge_ordered(
            [
              anthropic_version_pair(api_type),
              defaults,
              safe_extra_headers(meta.extra_headers, api_type),
              base_headers(provider, api_type, meta.auth_type, token)
            ],
            keep_nil: true
          )

        {:ok, headers}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def build_auth_headers(%Provider{}, _api_type, _provider_api),
    do: {:error, :api_surface_required}

  @spec build_auth_headers(Provider.t(), atom()) ::
          {:ok, [{String.t(), String.t() | nil}]} | {:error, atom()}
  def build_auth_headers(%Provider{} = provider, api_type),
    do: build_auth_headers(provider, api_type, nil)

  @doc "Build native Responses API-key headers from an already verified immutable snapshot."
  @spec build_responses_auth_headers(Provider.t(), Credential.t(), ProviderApi.t() | nil) ::
          {:ok, [{String.t(), String.t() | nil}]} | {:error, atom()}
  def build_responses_auth_headers(
        %Provider{} = provider,
        %Credential{} = credential,
        provider_api \\ nil
      ) do
    auth_type = Map.get(credential.metadata || %{}, "auth_type")

    if credential.name == provider.credential and auth_type in [nil, "api_key"] do
      with {:ok, token} <- Encryption.decrypt(credential.encrypted_value) do
        defaults =
          HeaderPolicy.merge_defaults(
            provider.default_headers,
            api_default_headers(provider_api),
            surface: :openai
          )

        headers =
          HeaderPolicy.merge_ordered(
            [defaults, base_headers(provider, :openai, auth_type, token)],
            keep_nil: true
          )

        {:ok, headers}
      end
    else
      {:error, :responses_lifecycle_unsupported}
    end
  end

  @spec build_auth_headers(Provider.t()) ::
          {:ok, [{String.t(), String.t() | nil}]} | {:error, atom()}
  def build_auth_headers(%Provider{api_type: api_type} = provider)
      when api_type in [:anthropic, :antigravity, :google, :openai],
      do: build_auth_headers(provider, api_type, nil)

  def build_auth_headers(%Provider{}), do: {:error, :api_surface_required}

  @doc """
  Builds provider-owned and default headers for a Codex OAuth credential.

  Provider-owned client headers are replaced by Relayixir's case-insensitive
  merge. Metadata defaults are supplied for absent headers only; API defaults
  override Provider defaults, which override Codex fallback defaults.
  """
  @spec codex_headers(String.t(), map(), map() | nil, map() | nil) ::
          {[{String.t(), String.t() | nil}], [{String.t(), String.t()}]}
  def codex_headers(token, meta, provider_default_headers \\ %{}, api_default_headers \\ %{})
      when is_binary(token) and is_map(meta) do
    metadata = Map.get(meta, :metadata, meta)

    replace =
      [
        {"authorization", "Bearer " <> token},
        {"x-api-key", nil},
        {"chatgpt-account-id", account_id(metadata)},
        {"x-openai-fedramp", fedramp(metadata)}
      ]

    configured_defaults =
      HeaderPolicy.merge_defaults(
        provider_default_headers,
        api_default_headers,
        surface: :codex
      )

    defaults =
      HeaderPolicy.merge_ordered([codex_default_headers(), configured_defaults])

    {replace, defaults}
  end

  defp account_id(meta), do: metadata_value(meta, ["account_id"])

  defp fedramp(meta) do
    case metadata_value(meta, ["x_openai_fedramp", "x-openai-fedramp", "fedramp"]) do
      value when value in [true, false] -> to_string(value)
      value -> value
    end
  end

  defp metadata_value(meta, keys) do
    Enum.find_value(keys, fn key -> Map.get(meta, key) || Map.get(meta, String.downcase(key)) end)
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp resolve_surface_credential(%Provider{credential: name} = provider, :google)
       when is_binary(name) and name != "" do
    case Backplane.Settings.Credentials.Vault.get(name) do
      nil ->
        {:error, :not_found}

      %{metadata: metadata} ->
        auth_type = Map.get(metadata || %{}, "auth_type")

        if auth_type in [nil, "api_key"],
          do: resolve_credential(provider),
          else: {:error, :unsupported_google_auth_type}
    end
  end

  defp resolve_surface_credential(%Provider{credential: name} = provider, :antigravity)
       when is_binary(name) and name != "" do
    case Backplane.Settings.Credentials.Vault.get(name) do
      nil ->
        {:error, :not_found}

      %{metadata: metadata} ->
        auth_type = Map.get(metadata || %{}, "auth_type")

        if auth_type == "google_oauth",
          do: resolve_credential(provider),
          else: {:error, :unsupported_antigravity_auth_type}
    end
  end

  defp resolve_surface_credential(provider, _surface), do: resolve_credential(provider)

  defp resolve_credential(%Provider{credential: credential})
       when is_binary(credential) and credential != "" do
    Credentials.fetch_with_meta(credential)
  end

  defp resolve_credential(_provider), do: {:error, :no_credential}

  defp apply_auth_headers(conn, _provider, :anthropic, "anthropic_oauth", token) do
    conn
    |> delete_req_header("x-api-key")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp apply_auth_headers(conn, provider, :anthropic, _auth_type, token) do
    if anthropic_api?(provider) do
      conn
      |> delete_req_header("authorization")
      |> put_req_header("x-api-key", token)
    else
      conn
      |> delete_req_header("x-api-key")
      |> put_req_header("authorization", "Bearer #{token}")
    end
  end

  defp apply_auth_headers(conn, _provider, :openai, _auth_type, token) do
    conn
    |> delete_req_header("x-api-key")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp apply_extra_headers(conn, []), do: conn

  defp apply_extra_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
  end

  defp maybe_apply_anthropic_version(conn, :anthropic) do
    case get_req_header(conn, "anthropic-version") do
      [] -> put_req_header(conn, "anthropic-version", @default_anthropic_version)
      _ -> conn
    end
  end

  defp maybe_apply_anthropic_version(conn, _), do: conn

  defp base_headers(_provider, :anthropic, "anthropic_oauth", token),
    do: [{"authorization", "Bearer #{token}"}]

  defp base_headers(provider, :anthropic, _auth_type, token) do
    if anthropic_api?(provider) do
      [{"x-api-key", token}]
    else
      [{"authorization", "Bearer #{token}"}]
    end
  end

  defp base_headers(_provider, :openai, _auth_type, token),
    do: [{"authorization", "Bearer #{token}"}]

  defp base_headers(_provider, :google, _auth_type, token),
    do: [{"authorization", nil}, {"x-api-key", nil}, {"x-goog-api-key", token}]

  defp base_headers(_provider, :antigravity, "google_oauth", token),
    do: [
      {"authorization", "Bearer #{token}"},
      {"x-api-key", nil},
      {"x-goog-api-key", nil}
    ]

  defp anthropic_api?(%Provider{preset_key: "ollama-cloud"}), do: false

  defp anthropic_api?(%Provider{} = provider) do
    preset_key = provider.preset_key
    name = provider.name || ""

    preset_key == "anthropic" or
      name == "anthropic" or
      String.contains?(String.downcase(name), "anthropic")
  end

  defp anthropic_version_pair(:anthropic), do: [{"anthropic-version", @default_anthropic_version}]
  defp anthropic_version_pair(_), do: []

  defp api_default_headers(%ProviderApi{default_headers: headers}) when is_map(headers),
    do: headers

  defp api_default_headers(%{default_headers: headers}) when is_map(headers), do: headers
  defp api_default_headers(_), do: %{}

  defp safe_extra_headers(headers, api_type) when is_list(headers) do
    HeaderPolicy.reject_headers(headers, HeaderPolicy.protected_headers(api_type))
  end

  defp merge_default_headers(conn, headers) when is_list(headers) do
    Enum.reduce(headers, conn, fn {key, value}, acc ->
      put_req_header(acc, String.downcase(key), value)
    end)
  end

  defp codex_default_headers do
    case OpenAICodex.default_header("originator") do
      nil -> []
      value -> [{"originator", value}]
    end
  end
end
