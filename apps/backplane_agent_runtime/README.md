# Backplane Agent Runtime

A standalone embedded OTP execution package. Hosts own sessions, repositories,
configuration, history, UI and public protocols. Optional tools and their backends
start only when selected by the host. No Phoenix, database, Sigma or Backplane
server application is required.

The package uses `jsonschex 0.10.0` as its production JSON Schema Draft
2020-12 engine; it is intentionally not dependency-free.

`Backplane.AgentRuntime.Conversation` drives prompt → lazy provider stream →
authorized tools → provider continuation → settlement. It is an alternative owner
to the existing explicit-command `ExecutionController`, not another controller to
run beside it. See [EMBEDDING.md](EMBEDDING.md) for contracts and an example,
[SCHEMAS.md](SCHEMAS.md) for the Draft 2020-12 tool-schema boundary, and
[PERSISTENCE.md](PERSISTENCE.md) for host storage and recovery requirements.

`examples/embedded.exs` is a deterministic complete provider/tool turn. Run it
from a consumer with `mix run examples/embedded.exs` after installing this package
(or run the file from the extracted artifact). It makes no network requests.

This is not a completed Sigma migration. Collaboration spawn, delegate, send,
wait, cancel and ask-user wrappers still return explicit unsupported results.
Conversation interaction resolution is a local host-adapter boundary, not an
implementation of those collaboration operations.
