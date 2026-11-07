# Backplane.Schema

Declarative raw data structure schema validator, coercer, and JSON Schema Draft 7 converter for Backplane.

## Features

- **Schema as Data**: Define schemas with native Elixir maps, keyword lists, atoms, and tuples.
- **Declarative DSL**: Use `defschema/2,3` to compile reusable validation functions and bang variants.
- **Coercion & Encoding**: Decode wire strings into typed values with `{:coerce, ...}` and encode back with `Backplane.Schema.encode/3`.
- **Tree Rewriting**: Transform schemas programmatically via `Backplane.Schema.walk/2`.
- **JSON Schema Interop**: Export and import Draft 7 JSON Schemas via `to_json_schema/2` and `from_json_schema/2`.

## Installation

Add `:backplane_schema` to your dependencies:

```elixir
def deps do
  [
    {:backplane_schema, "~> 1.10"}
  ]
end
```

## Usage

```elixir
defmodule MySchemas do
  import Backplane.Schema

  defschema :user, %{
    name: {:required, :string},
    age: {:integer, {:gte, 0}},
    tags: {:list, :string}
  }
end

{:ok, valid} = MySchemas.user(%{name: "Alice", age: 30, tags: ["admin"]})
```

## License

MIT
