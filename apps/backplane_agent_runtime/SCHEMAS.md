# Tool input schema support

`Backplane.AgentRuntime.InputSchema` validates tool arguments at the execution
gateway. It implements a dependency-free, explicit subset of JSON Schema; it
is not a general JSON Schema validator.

Tool schemas must have an object root. String and atom keys are accepted for
host-authored schemas. The supported keywords are:

| Keyword | Supported use |
| --- | --- |
| `type` | `object`, `array`, `string`, `integer`, `number`, `boolean`, or `null`; a non-empty unique list forms a union |
| `properties` | Object property schemas, validated recursively |
| `required` | A list of string property names |
| `additionalProperties` | Boolean object policy or a schema applied to every additional property; `additional_properties` is also accepted for Elixir callers |
| `description` | Annotation only |
| `default` | Annotation only; never inserted into tool arguments or validated against the schema |
| `format`, `contentEncoding`, `$schema`, `x-mcp-header` | String annotations only; values are retained by the host but not interpreted or asserted |
| `enum` | A list of JSON values; the value must equal one choice |
| `minimum` | Inclusive numeric lower bound on `integer` and `number` values |
| `maximum` | Inclusive numeric upper bound on `integer` and `number` values |
| `minLength` | Minimum Unicode code-point count for strings |
| `pattern` | Regular-expression search constraint for strings, within the portable subset below |
| `items` | One recursively validated schema for every array item |
| `minItems`, `maxItems` | Inclusive array length bounds |
| `oneOf` | A non-empty list of schemas; the value must match exactly one branch |
| `anyOf` | A non-empty list of schemas; the value must match at least one branch |
| `not` | One recursively validated schema that the value must not match |

A `oneOf` schema may be used alone for nested scalar or object alternatives, or
alongside supported object keywords. In the latter form, the object siblings
must all match and exactly one `oneOf` branch must match. Object branches may
omit `type`; object assertions in those branches apply when the value is an
object. This works at the tool root, in nested properties, and in array items.
Combining `oneOf` and `anyOf` in the same schema remains unsupported.

Object constraints apply at every nesting level, so nested `required`, property
types, `additionalProperties`, and typed object `enum` rules are enforced.
`default` is accepted on every supported schema, including nested properties,
array items, composition branches, and composition siblings.

Nested schemas may omit `type`. An empty schema accepts every value in the JSON
input domain. Assertions without an explicit type follow JSON Schema keyword
applicability: numeric bounds apply only to numbers, string constraints only to
strings, array constraints only to arrays, and object constraints only to
objects. Thus a `required`-only composition branch tests object values without
turning scalar values into objects. The tool schema root remains object-only.

`enum` narrows the existing type and other constraints; it does not replace
them. It works on object roots, typed properties, array items, and inside
`oneOf` branches. Strings are case-sensitive, numbers compare by numeric value
(for example, `1` equals `1.0`), and arrays/objects compare by their contents.
Boolean values are distinct from numbers. Enum choices must be JSON values,
including string-keyed objects; arbitrary Elixir atoms, structs, and tuples are
not accepted as choices. An empty enum rejects every supplied value; repeated
choices do not change membership. These membership rules follow the
[JSON Schema enum contract](https://json-schema.org/draft/2020-12/json-schema-validation#name-enum).
Enum-only property schemas and `enum` alongside compositions are supported.
Annotations and defaults never modify arguments or bypass assertions.

### Pattern subset

`pattern` uses JSON Schema search semantics: an unanchored expression may match
any substring. Patterns are limited to 1,024 UTF-8 bytes and compiled in Unicode
mode. The supported portable subset includes literals, character classes,
capturing and noncapturing groups, alternation, normal quantifiers, anchors, and
escaped punctuation. It rejects other `(?...)` groups, PCRE verbs, possessive
quantifiers, POSIX classes, backreferences, and letter or digit escapes such as
`\u`, `\d`, and `\p`. This intentionally avoids assigning PCRE behavior to syntax
whose ECMAScript semantics differ.

Before compilation, an unescaped `.` outside a character class is translated to
exclude LF, CR, U+2028, and U+2029, and an unescaped `$` outside a character class
is translated to absolute end-of-input. These preserve ECMAScript behavior on
the underlying PCRE engine. Matching has a fixed engine work limit. Exhausting
that limit returns an `:execution_failure` and propagates through `not`, `oneOf`,
and `anyOf`; it is never treated as an ordinary branch mismatch.

The validator first checks the complete schema, including absent properties
and every composition branch. An unknown keyword or unsupported type returns
an `:unsupported_capability` error. A malformed supported schema or arguments
that do not satisfy a supported constraint return a `:validation` error. The
execution gateway performs this check before authorization, approval,
budget reservation, durable intent commit, or backend invocation.

Hosts can call `InputSchema.validate_schema/1` to preflight the complete schema
without supplying placeholder arguments. Catalog publication uses this boundary
before making a revised registry visible.

Keywords outside the table are unsupported. This includes `$ref`, `$defs`,
`const`, `allOf`, tuple-style `items`, string maximum length, and exclusive
numeric bounds. Hosts must not strip these constraints. They should surface the
runtime error or use a different validator/backend boundary whose contract
supports the complete schema.

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

The issue #46 fixture is a sanitized, schema-only capture of the 58 tools exposed
by the locally configured hub on 2026-09-23. Each record contains only the tool
name and `inputSchema`; it contains no invocation arguments or credentials. It
proves that captured catalog plus focused forms reported by the requester. The
requester's separate 70-schema catalog was not available when this support was
implemented and remains a distinct live compatibility gate.

This document concerns tool-call input validation. Sigma's MCP elicitation UI
has its own narrower form-rendering boundary and remains a host concern.
