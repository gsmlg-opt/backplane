defmodule Backplane.MCP.Info do
  @moduledoc """
  Identity and protocol version metadata reported by the MCP transport
  and upstream client.
  """

  @protocol_version "2025-03-26"

  @doc "Current Backplane release version (from the :backplane app spec)."
  @spec version() :: String.t()
  def version do
    case Application.spec(:backplane, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  @doc "MCP protocol version supported by this server."
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version
end
