defmodule Backplane.LLM.CredentialPlug do
  @moduledoc """
  Strips client auth headers and injects provider API credentials into a conn.
  """

  alias Backplane.LLM.Provider
  alias Backplane.Settings.Credentials
  import Plug.Conn

  @default_anthropic_version "2023-06-01"

  @doc """
  Inject provider credentials into `conn` for a concrete API surface.

  For `:anthropic`:
  - Deletes the `authorization` header
  - Sets `x-api-key` to the resolved API key
  - Injects `anthropic-version: 2023-06-01` if not already present
  - Merges `provider.default_headers`

  For `:openai`:
  - Deletes the `x-api-key` header
  - Sets `authorization` to `Bearer <resolved_key>`
  - Merges `provider.default_headers`

  API key resolution:
  - `provider.credential` — name referencing the centralized credentials store
  - Returns 503 if credential is not set or not found
  """
  @spec inject(Plug.Conn.t(), Provider.t(), :openai | :anthropic) :: Plug.Conn.t()
  def inject(%Plug.Conn{} = conn, %Provider{} = provider, :anthropic) do
    case resolve_api_key(provider) do
      {:ok, api_key} ->
        conn
        |> delete_req_header("authorization")
        |> put_req_header("x-api-key", api_key)
        |> maybe_inject_anthropic_version()
        |> merge_default_headers(provider.default_headers)

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{error: "provider credential not configured"}))
        |> halt()
    end
  end

  def inject(%Plug.Conn{} = conn, %Provider{} = provider, :openai) do
    case resolve_api_key(provider) do
      {:ok, api_key} ->
        conn
        |> delete_req_header("x-api-key")
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> merge_default_headers(provider.default_headers)

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{error: "provider credential not configured"}))
        |> halt()
    end
  end

  @doc false
  @spec inject(Plug.Conn.t(), Provider.t()) :: Plug.Conn.t()
  def inject(%Plug.Conn{} = conn, %Provider{} = _provider) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, Jason.encode!(%{error: "provider API surface not configured"}))
    |> halt()
  end

  # ── Public helpers ────────────────────────────────────────────────────────────

  @doc """
  Build authentication headers for a provider without a conn.

  Returns `{:ok, headers}` where headers is a list of `{key, value}` tuples,
  or `{:error, reason}`.
  """
  @spec build_auth_headers(Provider.t(), :openai | :anthropic) ::
          {:ok, [{String.t(), String.t()}]} | {:error, atom()}
  def build_auth_headers(%Provider{} = provider, :anthropic) do
    case resolve_api_key(provider) do
      {:ok, api_key} ->
        headers =
          [{"x-api-key", api_key}, {"anthropic-version", @default_anthropic_version}] ++
            default_header_pairs(provider.default_headers)

        {:ok, headers}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def build_auth_headers(%Provider{} = provider, :openai) do
    case resolve_api_key(provider) do
      {:ok, api_key} ->
        headers =
          [{"authorization", "Bearer #{api_key}"}] ++
            default_header_pairs(provider.default_headers)

        {:ok, headers}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec build_auth_headers(Provider.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, atom()}
  def build_auth_headers(%Provider{}), do: {:error, :api_surface_required}

  defp default_header_pairs(nil), do: []

  defp default_header_pairs(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  # Resolve the plaintext API key for a provider via the centralized credential store.
  defp resolve_api_key(%Provider{credential: credential})
       when is_binary(credential) and credential != "" do
    Credentials.fetch(credential)
  end

  defp resolve_api_key(_provider), do: {:error, :no_credential}

  defp maybe_inject_anthropic_version(conn) do
    case get_req_header(conn, "anthropic-version") do
      [] -> put_req_header(conn, "anthropic-version", @default_anthropic_version)
      _existing -> conn
    end
  end

  defp merge_default_headers(conn, headers) when is_map(headers) do
    Enum.reduce(headers, conn, fn {key, value}, acc ->
      put_req_header(acc, String.downcase(key), value)
    end)
  end
end
