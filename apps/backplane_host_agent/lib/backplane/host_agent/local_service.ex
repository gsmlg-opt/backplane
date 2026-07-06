defmodule Backplane.HostAgent.LocalService do
  @moduledoc """
  Behaviour for host-agent local MCP tool services.
  """

  @callback prefix() :: String.t()
  @callback tools() :: [map()]
  @callback call(tool :: String.t(), args :: map(), ctx :: map()) ::
              {:ok, term()} | {:error, term()}
end
