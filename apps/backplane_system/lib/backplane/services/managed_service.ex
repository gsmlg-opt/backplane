defmodule Backplane.Services.ManagedService do
  @moduledoc "Behaviour for managed MCP services."

  @callback prefix() :: String.t()
  @callback tools() :: [map()]
  @callback enabled?() :: boolean()
  @callback prompts() :: [map()]
  @callback get_prompt(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks prompts: 0, get_prompt: 3
end
