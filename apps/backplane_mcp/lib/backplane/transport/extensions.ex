defmodule Backplane.Transport.Extensions do
  @moduledoc """
  Registry for MCP extensions (2025-11-25).
  Extensions use reverse-DNS identifiers.
  """

  @supported_extensions %{
    "io.modelcontextprotocol/tasks" => %{}
  }

  @doc "Return all server-supported extensions."
  @spec supported_extensions() :: map()
  def supported_extensions, do: @supported_extensions

  @doc "Check if a specific extension is supported."
  @spec supports?(String.t()) :: boolean()
  def supports?(extension_id), do: Map.has_key?(@supported_extensions, extension_id)

  @doc """
  Negotiate extensions with client. Returns the intersection of
  server-supported and client-requested extensions.
  """
  @spec negotiate(map() | nil) :: map()
  def negotiate(nil), do: %{}

  def negotiate(client_extensions) when is_map(client_extensions) do
    Map.filter(@supported_extensions, fn {k, _v} -> Map.has_key?(client_extensions, k) end)
  end

  def negotiate(_), do: %{}
end
