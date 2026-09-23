# Tool Input Schemas

`Backplane.AgentRuntime.InputSchema` is the MCP tool-call boundary. Schema
semantics are provided by `jsonschex 0.10.0`, whose target is JSON Schema Draft
2020-12. The runtime keeps the existing `validate_schema/1` and `validate/2`
contracts and adds optional `opts` forms for explicit external schema
registries/loaders.

## Dialect And Vocabularies

The supported dialect is exactly:

`https://json-schema.org/draft/2020-12/schema`

The `$schema` keyword may be omitted or may include the canonical URI with a
trailing `#`. Older drafts, unknown dialect URIs, and unsupported required
vocabularies return `:unsupported_capability`; they are never interpreted as a
different draft. The original schema is retained by the tool descriptor and is
never made less restrictive to pass validation.

The standard core, applicator, validation, unevaluated, meta-data,
format-annotation, and content vocabularies are supported. `format` is
annotation-only by default. `contentEncoding`, `contentMediaType`, and
`contentSchema` are also annotation-only by default; the runtime never decodes
or mutates tool arguments. A host that explicitly needs assertions can pass
`format_assertion: true` or `content_assertion: true` to the `opts` form. An
explicit required `format-assertion` vocabulary follows the dialect contract.

## Draft 2020-12 Coverage

The engine covers the complete Draft 2020-12 core, applicator, validation,
unevaluated, and content vocabularies, including:

- boolean schemas, all seven JSON types, unions, `enum`, `const`, and JSON
  numeric/structural equality;
- `multipleOf`, inclusive and exclusive numeric bounds, Unicode string lengths,
  ECMA-262-compatible `pattern`, and `format` policy above;
- `properties`, `patternProperties`, `additionalProperties`, `propertyNames`,
  `required`, `minProperties`, `maxProperties`, `dependentRequired`, and
  `dependentSchemas`;
- `prefixItems`, `items`, `contains`, `minContains`, `maxContains`,
  `minItems`, `maxItems`, and `uniqueItems`;
- arbitrary nesting and coexistence of `allOf`, `anyOf`, `oneOf`, `not`,
  `if`/`then`/`else`, including sibling keywords next to `$ref`;
- `$id`, `$schema`, `$defs`, `$ref`, `$anchor`, `$dynamicRef`,
  `$dynamicAnchor`, reference scopes, recursive references, and dynamic scope;
- evaluated-result propagation for `unevaluatedProperties` and
  `unevaluatedItems` across composition branches and references.

The package's official Draft 2020-12 test suite is vendored at
`test/fixtures/json_schema_test_suite` and pinned by `COMMIT`. The required
non-optional suite is run by `json_schema_draft202012_test.exs`; optional format
and content assertion behavior is tested separately according to the policy
above.

## Runtime Boundary

Tool schemas must be maps with an object root. A missing root `type` retains the
MCP object boundary; an explicit root union is rejected unless it is exactly
`"object"` (or `["object"]`). Nested schemas may be maps or boolean schemas.

Elixir host schemas may use atom keys and atom values only for the `type`
keyword. Keys are converted to existing strings with `Atom.to_string/1`; no
untrusted atoms are created. The input argument term is returned unchanged:
there are no defaults, coercions, unknown-property trimming, or default-based
authorization decisions.

External references are never fetched implicitly. Pass either:

```elixir
InputSchema.validate(schema, arguments,
  schema_registry: %{"https://example.test/name" => %{"type" => "string"}}
)
```

or an explicit `schema_loader: &loader/1`. Missing local references and failed
explicit loads are reported before catalog publication or backend invocation.

Schema size, nesting, node, reference, and input-shape limits fail closed with
`:execution_failure`. Validator execution failures are not converted into
ordinary `oneOf`/`anyOf`/`not` mismatches. Schema compilation errors are
`:validation`, while unsupported dialect/vocabulary capability errors are
`:unsupported_capability`.

`ToolCatalog` preflight and the `Execution`/`Conversation` gateways call this
same boundary. The check occurs before authorization, approval, budget
reservation, durable intent publication, or backend dispatch.

## Compatibility Evidence

- Issue #45 oneOf/object sibling composition remains covered by the existing
  catalog and execution regressions.
- Issue #46 and the captured Sigma/MCP schema fixtures remain catalog-preflight
  inputs; schemas are retained unchanged and validated by Draft 2020-12.
- The package now has a production dependency on `jsonschex` and
  `ex_json_pointer`, with `decimal` for arbitrary-precision numeric
  assertions; it is no longer a dependency-free artifact.
# Batch admission and quarantine

`Backplane.AgentRuntime.ToolCatalog.admit_batch/2` is the public batch boundary.
It is strict by default; pass `mode: :quarantine` explicitly to omit only tools
whose direct `InputSchema.validate_schema/1` result is
`%Error{class: :unsupported_capability}`. Validation, metadata, backend,
authority, duplicate-name, and unresolved-reference errors remain fatal.

The result is one executable bundle: `registry`, provider `tools`, narrowed
`authority`, `accepted` names, and ordered `rejected` diagnostics containing the
tool name, descriptor revision, and original structured error. Grants are only
removed for rejected tools; caller/run and other authority fields are retained.
An empty input or an all-rejected quarantine batch returns an empty registry,
provider list, and grants. Rejected diagnostics are trusted-host data and must
not be serialized into model requests, subscriber events, or checkpoints.

Use `schema_admission: :strict | :quarantine` when starting a Conversation or
on a dynamic catalog update; both paths consume the same admitted bundle.
