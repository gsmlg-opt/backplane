defmodule Backplane.Transport.McpEraRouter do
  @moduledoc """
  Classifies public MCP requests into the legacy or modern protocol era.

  Protocol marker and version parsing is delegated to the protocol package's
  profile router. This module only supplies Backplane's hard legacy connection
  signals and exposes the selected era to the HTTP transport.
  """

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Protocol.Profile
  alias Backplane.McpProtocol.Protocol.Registry
  alias Backplane.McpProtocol.Server.ProfileRouter

  @modern_versions ["2026-07-28"]
  @protocol_version_header "mcp-protocol-version"
  @session_header "mcp-session-id"

  @spec route(map(), term()) ::
          {:ok, ProfileRouter.route()} | {:error, Error.t()}
  def route(message, headers) when is_map(message) do
    with {:ok, headers} <- normalize_headers(headers) do
      ProfileRouter.route(message, %{
        req_headers: headers,
        supported_versions: @modern_versions,
        connection_era: hard_connection_era(message, headers)
      })
    end
  end

  @doc """
  Returns whether headers select modern error handling.

  Malformed or duplicate headers return true so the HTTP boundary reports the
  validation failure through the modern error path instead of falling through
  to the legacy transport.
  """
  @spec modern_header?(term()) :: boolean()
  def modern_header?(headers) do
    case normalize_headers(headers) do
      {:ok, headers} -> Enum.any?(headers, &modern_protocol_header?/1)
      {:error, %Error{}} -> true
    end
  end

  @spec era({:ok, ProfileRouter.route()} | {:error, Error.t()}) :: :legacy | :modern
  def era({:ok, :legacy}), do: :legacy
  def era(_modern_or_error), do: :modern

  defp hard_connection_era(%{"method" => "initialize"}, _headers), do: :legacy

  defp hard_connection_era(_message, headers) do
    if Enum.any?(headers, fn {name, _value} -> name == @session_header end),
      do: :legacy,
      else: nil
  end

  defp modern_protocol_header?({@protocol_version_header, value}) do
    case Registry.profile(value) do
      {:ok, %Profile{era: :legacy}} -> false
      _modern_or_unknown -> true
    end
  end

  defp modern_protocol_header?(_other_header), do: false

  defp normalize_headers(headers), do: normalize_headers(headers, [], false)

  defp normalize_headers([], normalized, _protocol_version_seen?) do
    {:ok, Enum.reverse(normalized)}
  end

  defp normalize_headers(
         [{name, value} | rest],
         normalized,
         protocol_version_seen?
       )
       when is_binary(name) and is_binary(value) do
    name = String.downcase(name)

    if name == @protocol_version_header and protocol_version_seen? do
      invalid_headers("Duplicate MCP-Protocol-Version header")
    else
      normalize_headers(
        rest,
        [{name, value} | normalized],
        protocol_version_seen? or name == @protocol_version_header
      )
    end
  end

  defp normalize_headers(_malformed, _normalized, _protocol_version_seen?) do
    invalid_headers("Malformed MCP request headers")
  end

  defp invalid_headers(message) do
    {:error, Error.protocol(:invalid_request, %{message: message})}
  end
end
