# Backplane Agent Runtime

A standalone embedded OTP execution package. Hosts own sessions, repositories,
configuration, history, UI and public protocols. Optional tools and their backends
start only when selected by the host. No Phoenix, database, Sigma or Backplane
server application is required.

Trusted host backends can return `ToolEffects.reject(operation, error)` for a
proved rejection before dispatch, preserving provider continuation without
weakening uncertain-effect handling. Existing adapters returning plain errors
must adopt this explicit contract; see [EMBEDDING.md](EMBEDDING.md).

The package uses `jsonschex 0.10.0` as its production JSON Schema Draft
2020-12 engine; it is intentionally not dependency-free.

Embeddings can set `provider_output_limit: :infinity` for unlimited generated
provider content, or select a finite non-negative byte budget per response.
Repeated stream snapshots count each logical content block once. The finite
`output_limit` tool-result bound remains independent; see [EMBEDDING.md](EMBEDDING.md)
for defaults, content representation and structured limit errors.

`Backplane.AgentRuntime.Conversation` drives prompt → lazy provider stream →
authorized tools → provider continuation → settlement. It is an alternative owner
to the existing explicit-command `ExecutionController`, not another controller to
run beside it. See [EMBEDDING.md](EMBEDDING.md) for contracts and an example,
[SCHEMAS.md](SCHEMAS.md) for the Draft 2020-12 tool-schema boundary, and
[PERSISTENCE.md](PERSISTENCE.md) for host storage and recovery requirements.

`examples/embedded.exs` is a deterministic complete provider/tool turn. Run it
from a consumer with `mix run examples/embedded.exs` after installing this package
(or run the file from the extracted artifact). It makes no network requests.

This is not a completed Sigma migration. Codex profiles are explicit, opt-in
host integrations; selecting no profile starts no command worker, extension
runtime, collaboration tree, network client, or provider-hosted capability.

The local, interaction/context, collaboration V1/V2, stateful extension,
dynamic MCP/plugin, Code Mode, service-backed, and composed Codex profiles are
documented in [CODEX.md](CODEX.md). Model-callable tools use the strict catalog
and `Conversation -> Execution` path. Provider-hosted tools are negotiated and
projected separately and never become local registry entries. The implementation
is assessed compatibility, not unqualified Codex parity; platform, durable
backend, provider-wire, and live-service limits are recorded in the coverage
ledger under `docs/agent-runtime/codex-tools/`.
