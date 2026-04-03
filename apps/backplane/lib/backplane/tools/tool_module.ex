defmodule Backplane.Tools.ToolModule do
  @moduledoc """
  Behaviour for native tool modules.

  Each tool module must define:
  - `tools/0` — returns a list of tool definitions (name, description, input_schema, module, handler)
  - `call/1` — dispatches a tool call based on the `_handler` key in args
  """

  @callback tools() :: [map()]
  @callback call(args :: map()) :: {:ok, term()} | {:error, term()}
end
