defmodule Backplane.PluginProtocol.Client do
  @moduledoc """
  Client for Backplane's distribution API (not an Agent Plugins registry standard).

  Transport is injected as a function receiving
  `%{method: method, url: url, headers: [{name, value}], body: nil_or_json_binary}` and returning
  `{:ok, %{status: integer, body: binary_or_decoded_json}} | {:error, reason}`.
  The caller owns timeouts, TLS verification, redirect policy and response byte
  limits. Authorization must never be forwarded to another origin on redirects.
  `auth` accepts a bearer string or a zero-arity function returning header pairs.
  """
  alias Backplane.PluginProtocol
  alias Backplane.PluginProtocol.Archive
  @enforce_keys [:base_url, :transport]
  defstruct [:base_url, :transport, :auth, headers: []]

  def new(opts) do
    %__MODULE__{
      base_url: Keyword.fetch!(opts, :base_url) |> String.trim_trailing("/"),
      transport: Keyword.fetch!(opts, :transport),
      headers: Keyword.get(opts, :headers, []),
      auth: Keyword.get(opts, :auth)
    }
  end

  def catalog(client, opts \\ []), do: json_request(client, "/catalog", opts)
  def resolve(client, params \\ []), do: json_request(client, "/resolve", params)

  @doc "Downloads, verifies SHA-256, safely unpacks and loads the exact artifact."
  def download(client, digest, opts \\ []) do
    with true <- is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
         {:ok, artifact} <- get(client, "/artifacts/" <> digest, []),
         true <- is_binary(artifact),
         :ok <- verify_digest(artifact, digest),
         {:ok, snapshot} <- Archive.unpack_with_metadata(artifact, opts),
         {:ok, package} <- PluginProtocol.load(snapshot.files, opts) do
      {:ok,
       %{
         artifact: artifact,
         files: snapshot.files,
         modes: snapshot.modes,
         package: package,
         artifact_digest: digest
       }}
    else
      false -> {:error, :invalid_artifact}
      error -> error
    end
  end

  defp verify_digest(bytes, expected) do
    if Archive.digest(bytes) == expected, do: :ok, else: {:error, :digest_mismatch}
  end

  defp json_request(client, path, params) do
    with {:ok, body} <- get(client, path, params) do
      decode(body)
    end
  end

  @doc "Makes a JSON request within the same registry origin and protocol prefix."
  def request(client, method, path, body \\ nil) do
    if method in [:get, :post, :put, :patch, :delete] and safe_endpoint?(path) do
      headers = client.headers ++ auth_headers(client.auth)

      headers =
        if is_nil(body), do: headers, else: headers ++ [{"content-type", "application/json"}]

      with {:ok, response} <-
             transport(client, %{
               method: method,
               url: client.base_url <> "/plugin-protocol/v1" <> path,
               headers: headers,
               body: if(is_nil(body), do: nil, else: JSON.encode!(body))
             }) do
        decode(response)
      end
    else
      {:error, :invalid_endpoint}
    end
  end

  defp safe_endpoint?(path) when is_binary(path) do
    String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
      not String.contains?(path, ["\\", "\0", "#", "?"]) and
      not String.contains?(URI.decode(path), ["..", "\\", "\0"])
  end

  defp safe_endpoint?(_), do: false

  defp decode(map) when is_map(map), do: {:ok, map}
  defp decode(""), do: {:ok, %{}}

  defp decode(binary) when is_binary(binary) do
    case JSON.decode(binary) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_response}
    end
  end

  defp decode(_), do: {:error, :invalid_response}

  defp get(client, path, params) do
    query = params |> Enum.reject(fn {_, value} -> is_nil(value) end) |> URI.encode_query()

    url =
      client.base_url <>
        "/plugin-protocol/v1" <> path <> if(query == "", do: "", else: "?" <> query)

    request = %{
      method: :get,
      url: url,
      headers: client.headers ++ auth_headers(client.auth),
      body: nil
    }

    transport(client, request)
  end

  defp transport(client, request) do
    case client.transport.(request) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :invalid_transport_response}
    end
  end

  defp auth_headers(nil), do: []
  defp auth_headers(token) when is_binary(token), do: [{"authorization", "Bearer " <> token}]
  defp auth_headers(provider) when is_function(provider, 0), do: provider.()
end
