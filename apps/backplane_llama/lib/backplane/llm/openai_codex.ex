defmodule Backplane.LLM.OpenAICodex do
  @moduledoc """
  Provider specification for the OpenAI Codex preset backed by ChatGPT OAuth.

  This module owns only provider identity, endpoint policy, path mapping, and
  provider-owned header policy. It performs no protocol or schema conversion.
  """

  alias Backplane.LLM.{Provider, ProviderApi}
  alias Backplane.Settings.Credentials

  @default_backend_base_url "https://chatgpt.com/backend-api/codex"
  @provider_owned_headers ~w(authorization x-api-key chatgpt-account-id x-openai-fedramp)

  @doc "Returns true when the OpenAI API surface is the ChatGPT Codex backend."
  @spec enabled?(Provider.t(), ProviderApi.t()) :: boolean()
  def enabled?(
        %Provider{preset_key: "openai-codex", credential: credential},
        %ProviderApi{api_surface: :openai}
      )
      when is_binary(credential) and credential != "" do
    credential_auth_type(credential) == "openai_oauth"
  end

  def enabled?(_provider, _api), do: false

  @doc "Returns the configured Codex backend base URL."
  @spec backend_base_url() :: String.t()
  def backend_base_url do
    Application.get_env(:backplane, :openai_codex_backend_base_url, @default_backend_base_url)
  end

  @doc """
  Validates an API base URL and returns the upstream Codex backend base URL.

  The provider-scoped route appends the exact endpoint path to any valid HTTP(S)
  Codex-compatible backend URL.
  """
  @spec validate_backend_base_url(String.t() | nil) ::
          {:ok, String.t()} | {:error, :unsupported_endpoint}
  def validate_backend_base_url(nil), do: {:ok, @default_backend_base_url}

  def validate_backend_base_url(base_url) when is_binary(base_url) do
    uri = URI.parse(base_url)

    if uri.scheme in ["https", "http"] and is_binary(uri.host) do
      {:ok, backend_base_url(uri)}
    else
      {:error, :unsupported_endpoint}
    end
  end

  def validate_backend_base_url(_base_url), do: {:error, :unsupported_endpoint}

  @doc "Returns headers that are owned by the provider credential."
  @spec provider_owned_headers() :: [String.t()]
  def provider_owned_headers, do: @provider_owned_headers

  @doc "Returns the default value for a metadata header, or nil when absent."
  @spec default_header(String.t()) :: String.t() | nil
  def default_header("originator"), do: "codex_cli_rs"
  def default_header(_name), do: nil

  @doc "Returns the canonical default base URL for Codex provider presets."
  @spec default_backend_base_url() :: String.t()
  def default_backend_base_url, do: @default_backend_base_url

  defp backend_base_url(%URI{scheme: scheme, host: host, port: port, path: path}) do
    scheme = String.downcase(scheme || "https")

    "#{scheme}://#{String.downcase(host)}#{port_suffix(port)}#{normalized_path(path)}"
  end

  defp port_suffix(nil), do: ""
  defp port_suffix(port), do: ":#{port}"

  defp normalized_path(nil), do: ""

  defp normalized_path(path) do
    path
    |> String.trim_trailing("/")
    |> case do
      "" -> ""
      normalized -> normalized
    end
  end

  defp credential_auth_type(name) do
    Credentials.list()
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> nil
      credential -> credential_metadata_auth_type(credential.metadata)
    end
  end

  defp credential_metadata_auth_type(metadata) when is_map(metadata) do
    Map.get(metadata, "auth_type") || Map.get(metadata, :auth_type) || "api_key"
  end

  defp credential_metadata_auth_type(_metadata), do: "api_key"
end
