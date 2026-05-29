defmodule Backplane.MCP.Info do
  @moduledoc """
  Identity and protocol version metadata reported by the MCP transport
  and upstream client.
  """

  @latest_version "2025-06-18"
  @supported_versions ["2025-06-18", "2025-03-26"]

  @doc "Current Backplane release version (from the :backplane app spec)."
  @spec version() :: String.t()
  def version do
    case Application.spec(:backplane, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  @doc "Latest MCP protocol version supported by this server."
  @spec protocol_version() :: String.t()
  def protocol_version, do: @latest_version

  @doc "All MCP protocol versions supported by this server."
  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @supported_versions

  @doc """
  Negotiate protocol version with client.

  If the client requests a supported version, that version is returned.
  If the client requests an unsupported version or none at all, the
  latest supported version is returned.
  """
  @spec negotiate_version(String.t() | nil) :: String.t()
  def negotiate_version(nil), do: @latest_version
  def negotiate_version(v) when v in @supported_versions, do: v
  def negotiate_version(_), do: @latest_version
end
