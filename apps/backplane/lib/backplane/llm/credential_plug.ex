defmodule Backplane.LLM.CredentialPlug do
  @moduledoc """
  Strips client auth headers and injects provider API credentials into a conn.
  """

  alias Backplane.LLM.Provider
  alias Backplane.Settings.Credentials
  import Plug.Conn

  @default_anthropic_version "2023-06-01"

  @doc """
  Inject provider credentials into `conn` based on the provider's `api_type`.

  For `:anthropic`:
  - Deletes the `authorization` header
  - Sets `x-api-key` to the resolved API key
  - Injects `anthropic-version: 2023-06-01` if not already present
  - Merges `provider.default_headers`

  For `:openai`:
  - Deletes the `x-api-key` header
  - Sets `authorization` to `Bearer <resolved_key>`
  - Merges `provider.default_headers`

  API key resolution order:
  1. `provider.credential` — name referencing the centralized credentials store
  2. `provider.api_key_encrypted` — legacy direct-encrypted API key
  3. Returns 503 if neither is set
  """
  @spec inject(Plug.Conn.t(), Provider.t()) :: Plug.Conn.t()
  def inject(%Plug.Conn{} = conn, %Provider{api_type: :anthropic} = provider) do
    case resolve_api_key(provider) do
      {:ok, api_key} ->
        conn
        |> delete_req_header("authorization")
        |> put_req_header("x-api-key", api_key)
        |> maybe_inject_anthropic_version()
        |> merge_default_headers(provider.default_headers)

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{error: "credential unavailable", detail: inspect(reason)}))
        |> halt()
    end
  end

  def inject(%Plug.Conn{} = conn, %Provider{api_type: :openai} = provider) do
    case resolve_api_key(provider) do
      {:ok, api_key} ->
        conn
        |> delete_req_header("x-api-key")
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> merge_default_headers(provider.default_headers)

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{error: "credential unavailable", detail: inspect(reason)}))
        |> halt()
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  # Resolve the plaintext API key for a provider.
  # 1. If `credential` is set, look it up in the centralized credentials store.
  # 2. Fall back to `api_key_encrypted` (legacy direct-encryption path).
  # 3. Return {:error, :no_credential} if neither is set.
  defp resolve_api_key(%Provider{credential: credential})
       when is_binary(credential) and credential != "" do
    Credentials.fetch(credential)
  end

  defp resolve_api_key(%Provider{api_key_encrypted: encrypted})
       when is_binary(encrypted) do
    Provider.decrypt_api_key(%Provider{api_key_encrypted: encrypted})
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
