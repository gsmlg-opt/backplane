# Backplane.JsonSchema

JSON Schema Draft 2020-12 and Draft 7 AST compiler and validator for Backplane.

## Features

- **Strict Dialect Support**: Draft 2020-12 (MCP tool input schema standard) and Draft 7.
- **Fail-Closed & Offline**: In-memory embedded meta-schemas; no external network resolution during validation.
- **AST Compilation**: Schemas compile into structured `%Backplane.JsonSchema.Types.Schema{}` structs with indexed scope fragments.
- **Clear Error Formatting**: Standard error tuples and human-readable formatting via `Backplane.JsonSchema.format_error/1`.

## Installation

Add `:backplane_json_schema` to your dependencies:

```elixir
def deps do
  [
    {:backplane_json_schema, "~> 1.10"}
  ]
end
```

## Usage

```elixir
schema = %{
  "type" => "object",
  "properties" => %{
    "name" => %{"type" => "string"},
    "age" => %{"type" => "integer", "minimum" => 0}
  },
  "required" => ["name"]
}

# Compile schema
{:ok, compiled} = Backplane.JsonSchema.compile(schema)

# Validate payload
:ok = Backplane.JsonSchema.validate(compiled, %{"name" => "Alice", "age" => 30})

# Invalid payload returns errors
{:error, errors} = Backplane.JsonSchema.validate(compiled, %{"age" => -5})
formatted = Backplane.JsonSchema.format_error(hd(errors))
```

## License

Apache-2.0
