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

  alias Backplane.LLM.Provider
  alias Backplane.Settings.Credentials
  import Plug.Conn

  @default_anthropic_version "2023-06-01"

  @doc """
  Inject provider credentials into `conn`. Derives `api_type` from
  `provider.api_type`.
  """
  @spec inject(Plug.Conn.t(), Provider.t()) :: Plug.Conn.t()
  def inject(%Plug.Conn{} = conn, %Provider{api_type: api_type} = provider)
      when api_type in [:anthropic, :openai] do
    case resolve_credential(provider) do
      {:ok, token, meta} ->
        conn
        |> apply_auth_headers(api_type, meta.auth_type, token)
        |> apply_extra_headers(meta.extra_headers)
        |> maybe_apply_anthropic_version(api_type)
        |> merge_default_headers(provider.default_headers)

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{error: "provider credential not configured"}))
        |> halt()
    end
  end

  def inject(%Plug.Conn{} = conn, %Provider{}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, Jason.encode!(%{error: "provider API surface not configured"}))
    |> halt()
  end

  @doc """
  Build authentication headers for a provider without a conn.

  Returns `{:ok, headers}` where headers is a list of `{key, value}` tuples,
  or `{:error, reason}`.

  Accepts an optional explicit `api_type` — used by production callers (router,
  health checker, model discovery) that know the surface from context.  When
  omitted the `api_type` virtual field on the provider struct is used instead
  (set when the struct was created in-process via `Provider.create/1`).
  """
  @spec build_auth_headers(Provider.t(), atom()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, atom()}
  def build_auth_headers(%Provider{} = provider, api_type)
      when api_type in [:anthropic, :openai] do
    case resolve_credential(provider) do
      {:ok, token, meta} ->
        headers =
          base_headers(api_type, meta.auth_type, token) ++
            meta.extra_headers ++
            anthropic_version_pair(api_type) ++
            default_header_pairs(provider.default_headers)

        {:ok, headers}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def build_auth_headers(%Provider{}, _api_type), do: {:error, :api_surface_required}

  @spec build_auth_headers(Provider.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, atom()}
  def build_auth_headers(%Provider{api_type: api_type} = provider)
      when api_type in [:anthropic, :openai],
      do: build_auth_headers(provider, api_type)

  def build_auth_headers(%Provider{}), do: {:error, :api_surface_required}

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp resolve_credential(%Provider{credential: credential})
       when is_binary(credential) and credential != "" do
    Credentials.fetch_with_meta(credential)
  end

  defp resolve_credential(_provider), do: {:error, :no_credential}

  defp apply_auth_headers(conn, :anthropic, "anthropic_oauth", token) do
    conn
    |> delete_req_header("x-api-key")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp apply_auth_headers(conn, :anthropic, _auth_type, token) do
    conn
    |> delete_req_header("authorization")
    |> put_req_header("x-api-key", token)
  end

  defp apply_auth_headers(conn, :openai, _auth_type, token) do
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

  defp base_headers(:anthropic, "anthropic_oauth", token),
    do: [{"authorization", "Bearer #{token}"}]

  defp base_headers(:anthropic, _auth_type, token), do: [{"x-api-key", token}]

  defp base_headers(:openai, _auth_type, token),
    do: [{"authorization", "Bearer #{token}"}]

  defp anthropic_version_pair(:anthropic), do: [{"anthropic-version", @default_anthropic_version}]
  defp anthropic_version_pair(_), do: []

  defp default_header_pairs(nil), do: []

  defp default_header_pairs(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)
  end

  defp merge_default_headers(conn, headers) when is_map(headers) do
    Enum.reduce(headers, conn, fn {key, value}, acc ->
      put_req_header(acc, String.downcase(key), value)
    end)
  end

  defp merge_default_headers(conn, _), do: conn
end
