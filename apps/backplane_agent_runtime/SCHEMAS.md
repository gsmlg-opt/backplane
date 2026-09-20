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
| `minimum` | Inclusive numeric lower bound on `integer` and `number` values |
| `items` | One recursively validated schema for every array item |
| `oneOf` | A non-empty list of schemas; the value must match exactly one branch |

A `oneOf` schema may contain only `oneOf` and `description`. Other sibling
semantics are outside this subset. Object constraints apply at every nesting
level, so nested `required` and `additionalProperties` rules are enforced.

The validator first checks the complete schema, including absent properties
and every composition branch. An unknown keyword or unsupported type returns
an `:unsupported_capability` error. A malformed supported schema or arguments
that do not satisfy a supported constraint return a `:validation` error. The
execution gateway performs this check before authorization, approval,
budget reservation, durable intent commit, or backend invocation.

Keywords outside the table are unsupported. This includes `$ref`, `enum`,
`const`, `anyOf`, `allOf`, `not`, `pattern`, string lengths, array lengths,
tuple-style `items`, `maximum`, and exclusive numeric bounds. Hosts must not
strip these constraints. They should surface the runtime error or use a
different validator/backend boundary whose contract supports the complete
schema.

## Sigma and MCP boundary

The current Sigma built-in schemas at
`143c8db27f5f3d32efc5dafffb2755dba1daa23b` fit this subset. The regression
fixtures cover all nine built-in tools and retain the `minimum`, nested
`items`, nested object, and `oneOf` forms used by those tools.

Sigma can receive arbitrary `inputSchema` maps from MCP `tools/list`; MCP does
not restrict those maps to this package's subset. A Sigma adapter may register
such a descriptor unchanged, but execution will reject unsupported schema
features before invoking the MCP tool. Supporting additional MCP schemas
requires an explicit package change with validation tests; silently dropping
constraints is not supported.

This document concerns tool-call input validation. Sigma's MCP elicitation UI
has its own narrower form-rendering boundary and remains a host concern.
