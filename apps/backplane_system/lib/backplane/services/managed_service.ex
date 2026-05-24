defmodule Backplane.Services.ManagedService do
  @moduledoc "Behaviour for managed MCP services."

  @callback prefix() :: String.t()
  @callback tools() :: [map()]
  @callback enabled?() :: boolean()
end
