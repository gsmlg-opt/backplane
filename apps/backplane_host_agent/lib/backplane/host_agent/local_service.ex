defmodule Backplane.HostAgent.LocalService do
  @moduledoc """
  Behaviour for host-agent local MCP tool services.

  Services can return `{:content, blocks}` for MCP content such as images or
  `{:tool_error, reason}` for an MCP tool error result.
  """

  @callback prefix() :: String.t()
  @callback tools() :: [map()]
  @callback call(tool :: String.t(), args :: map(), ctx :: map()) ::
              {:ok, term()} | {:content, [map()]} | {:tool_error, term()} | {:error, term()}
end
