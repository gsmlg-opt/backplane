# Compatibility Matrix

## Initial slice boundary

For W1.1 the library exposes only package existence, dependency topology, and startup behavior. It does not yet promise provider request, SSE, transport, auth, model-catalog, cancellation, retry, or migration semantics.

## Must preserve in hosts

| Host | Non-target behavior |
| --- | --- |
| Backplane | LLM proxy routes and Relayixir forwarding, credential storage, native Codex transport, production release composition. |
| Sigma | Agent loop, tool execution, logs/session behavior. |
| Synapsis | QueryLoop/tool execution, approvals, daemon/background work, persistence, PubSub, and provider/config ownership. |

