defmodule Backplane.Registry.Tool do
  @moduledoc """
  Struct representing a registered tool in the tool registry.

  Supports MCP tool metadata fields across all protocol versions:
  - `annotations` — behavioral hints (2025-03-26+): readOnlyHint, destructiveHint, etc.
  - `output_schema` — structured output JSON Schema (2025-06-18+)
  - `icon` — icon metadata with url and mediaType (2025-11-25+)
  """

  @enforce_keys [:name, :description, :input_schema, :origin]
  defstruct [
    :name,
    :description,
    :input_schema,
    :origin,
    :module,
    :handler,
    :upstream_pid,
    :original_name,
    :output_schema,
    :annotations,
    :icon,
    timeout: 30_000
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          origin: :native | {:upstream, String.t()} | {:managed, String.t()},
          module: module() | nil,
          handler: atom() | (map() -> {:ok, term()} | {:error, term()}) | nil,
          upstream_pid: pid() | nil,
          original_name: String.t() | nil,
          output_schema: map() | nil,
          annotations: map() | nil,
          icon: map() | nil,
          timeout: pos_integer()
        }
end
