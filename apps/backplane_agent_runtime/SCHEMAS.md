# Tool input schema support

`Backplane.AgentRuntime.InputSchema` validates tool arguments at the execution
gateway. It implements a dependency-free, explicit subset of JSON Schema; it
is not a general JSON Schema validator.

Tool schemas must have an object root. String and atom keys are accepted for
host-authored schemas. The supported keywords are:

| Keyword | Supported use |
| --- | --- |
| `type` | `object`, `array`, `string`, `integer`, `number`, or `boolean` |
| `properties` | Object property schemas, validated recursively |
| `required` | A list of string property names |
| `additionalProperties` | Boolean object policy; `additional_properties` is also accepted for Elixir callers |
| `description` | Annotation only |
| `default` | Annotation only; never inserted into tool arguments or validated against the schema |
| `enum` | A list of JSON values allowed by a typed schema; the value must equal one choice |
| `minimum` | Inclusive numeric lower bound on `integer` and `number` values |
| `items` | One recursively validated schema for every array item |
| `oneOf` | A non-empty list of schemas; the value must match exactly one branch |
| `anyOf` | A non-empty list of schemas; the value must match at least one branch |

A `oneOf` schema may be used alone for nested scalar or object alternatives, or
alongside supported object keywords. In the latter form, the object siblings
must all match and exactly one `oneOf` branch must match. Object branches may
omit `type`; they inherit the composition's object context. This works at the
tool root, in nested properties, and in array items. Combining `oneOf` and
`anyOf` in the same schema remains unsupported.

Object constraints apply at every nesting level, so nested `required`, property
types, `additionalProperties`, and typed object `enum` rules are enforced.
`default` is accepted on every supported schema, including nested properties,
array items, composition branches, and composition siblings.

`enum` narrows the existing type and other constraints; it does not replace
them. It works on object roots, typed properties, array items, and inside
`oneOf` branches. Strings are case-sensitive, numbers compare by numeric value
(for example, `1` equals `1.0`), and arrays/objects compare by their contents.
Boolean values are distinct from numbers. Enum choices must be JSON values,
including string-keyed objects; arbitrary Elixir atoms, structs, and tuples are
not accepted as choices. An empty enum rejects every supplied value; repeated
choices do not change membership. These membership rules follow the
[JSON Schema enum contract](https://json-schema.org/draft/2020-12/json-schema-validation#name-enum).
Enum-only property schemas and untyped `enum` beside nested `oneOf` remain
outside this subset. A typed object `enum` may narrow an object schema composed
with `oneOf`.

The validator first checks the complete schema, including absent properties
and every composition branch. An unknown keyword or unsupported type returns
an `:unsupported_capability` error. A malformed supported schema or arguments
that do not satisfy a supported constraint return a `:validation` error. The
execution gateway performs this check before authorization, approval,
budget reservation, durable intent commit, or backend invocation.

Hosts can call `InputSchema.validate_schema/1` to preflight the complete schema
without supplying placeholder arguments. Catalog publication uses this boundary
before making a revised registry visible.

Keywords outside the table are unsupported. This includes `$ref`,
`const`, `allOf`, `not`, `pattern`, string lengths, array lengths,
tuple-style `items`, `maximum`, and exclusive numeric bounds. Hosts must not
strip these constraints. They should surface the runtime error or use a
different validator/backend boundary whose contract supports the complete
schema.

## Sigma and MCP boundary

The original nine Sigma coding-tool fixtures come from
`143c8db27f5f3d32efc5dafffb2755dba1daa23b` and retain `minimum`, nested
`items`, nested object, and `oneOf` constraints. The todo-tool fixture comes from
`5114a42efe449ca2a5b91aa8e40df8aba27c04e4` and retains both the `action` and
`status` enums. The optional read-only source probe checks these ten actual
schema functions and drives a todo call through the adapted provider stream.

Sigma can receive arbitrary `inputSchema` maps from MCP `tools/list`; MCP does
not restrict those maps to this package's subset. A Sigma adapter may register
such a descriptor unchanged, but execution will reject unsupported schema
features before invoking the MCP tool. Supporting additional MCP schemas
requires an explicit package change with validation tests; silently dropping
constraints is not supported.

This document concerns tool-call input validation. Sigma's MCP elicitation UI
has its own narrower form-rendering boundary and remains a host concern.
