defmodule Backplane.Registry.Tool do
  @moduledoc """
  Struct representing a registered tool in the tool registry.
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
          timeout: pos_integer()
        }
end
