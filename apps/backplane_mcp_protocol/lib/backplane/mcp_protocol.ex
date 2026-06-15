defmodule Backplane.McpProtocol do
  @moduledoc """
  First-party MCP protocol implementation for Backplane.
  """

  @latest_protocol_version "2025-11-25"
  @supported_protocol_versions ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

  @spec protocol_version() :: String.t()
  def protocol_version, do: @latest_protocol_version

  @spec supported_protocol_versions() :: [String.t()]
  def supported_protocol_versions, do: @supported_protocol_versions

  @spec negotiate_version(String.t() | nil) :: String.t()
  def negotiate_version(nil), do: @latest_protocol_version
  def negotiate_version(version) when version in @supported_protocol_versions, do: version
  def negotiate_version(_version), do: @latest_protocol_version
end
