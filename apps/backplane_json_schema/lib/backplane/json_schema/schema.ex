defmodule Backplane.JsonSchema.Schema do
  @moduledoc """
  Compiled JSON Schema representation and compile-time macro helpers.
  """

  alias Backplane.JsonSchema.Compiler

  @type t :: Backplane.JsonSchema.Types.Schema.t()

  defstruct [
    :rules,
    :defs,
    :source_id,
    :raw,
    :dynamic_anchor,
    :loader,
    local_refs: %{},
    format_assertion: false,
    content_assertion: false,
    draft: "draft2020_12"
  ]

  @doc """
  Compiles a static schema literal at compile time and embeds the compiled
  `Backplane.JsonSchema.Schema` directly into the caller module.
  """
  defmacro compile!(schema, opts \\ []) do
    quote bind_quoted: [schema: schema, opts: opts] do
      case Compiler.compile(schema, opts) do
        {:ok, compiled} ->
          Macro.escape(compiled)

        {:error, errors} ->
          formatted =
            errors
            |> List.wrap()
            |> Enum.map(&to_string/1)
            |> Enum.join("; ")

          raise ArgumentError, "Failed to compile JSON Schema: #{formatted}"
      end
    end
  end
end
