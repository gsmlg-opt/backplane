defmodule Backplane.LLM.CredentialPlug do
  @moduledoc """
  Strips client auth headers and injects provider API credentials into a conn.
  """

  alias Backplane.LLM.Provider
  import Plug.Conn

  @default_anthropic_version "2023-06-01"

  @doc """
  Inject provider credentials into `conn` based on the provider's `api_type`.

  For `:anthropic`:
  - Deletes the `authorization` header
  - Sets `x-api-key` to the decrypted API key
  - Injects `anthropic-version: 2023-06-01` if not already present
  - Merges `provider.default_headers`

  For `:openai`:
  - Deletes the `x-api-key` header
  - Sets `authorization` to `Bearer <decrypted_key>`
  - Merges `provider.default_headers`
  """
  @spec inject(Plug.Conn.t(), Provider.t()) :: Plug.Conn.t()
  def inject(%Plug.Conn{} = conn, %Provider{api_type: :anthropic} = provider) do
    {:ok, api_key} = Provider.decrypt_api_key(provider)

    conn
    |> delete_req_header("authorization")
    |> put_req_header("x-api-key", api_key)
    |> maybe_inject_anthropic_version()
    |> merge_default_headers(provider.default_headers)
  end

  def inject(%Plug.Conn{} = conn, %Provider{api_type: :openai} = provider) do
    {:ok, api_key} = Provider.decrypt_api_key(provider)

    conn
    |> delete_req_header("x-api-key")
    |> put_req_header("authorization", "Bearer #{api_key}")
    |> merge_default_headers(provider.default_headers)
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

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
