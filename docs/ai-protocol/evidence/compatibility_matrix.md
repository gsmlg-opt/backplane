# Compatibility Matrix

## Initial slice boundary

For W1.1 the library exposes only package existence, dependency topology, and startup behavior. It does not yet promise provider request, SSE, transport, auth, model-catalog, cancellation, retry, or migration semantics.

That statement is retained as historical W1.1 evidence. The current PR #32 remediation adds the
following first-consumer migration:

| Protocol/profile path | Prior implementation | Shared modules now used | Host consumer of results | Mode | Normal path | Tests | Remaining legacy |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Ordinary OpenAI Responses, non-Codex | Host JSON/SSE usage parsing | `SSE`, `OpenAIResponsesObserver`, serialization bounds | `UsageAccumulator`, `AccessEvent`, Observability `LogWriter`, `llm_logs` | Native observation | Enabled when operation is `responses` and preset is not `openai-codex` | `streaming_integration_test.exs`, `access_observability_test.exs`, core remediation tests | Request translation and HTTP transport remain host-owned |
| OpenAI Chat Completions | Host parser | None | Existing host usage/logging | Native | Unchanged | `usage_accumulator_test.exs`, `proxy_plug_test.exs` | Entire protocol parser |
| Anthropic Messages | Host parser | None | Existing host usage/logging | Native | Unchanged | existing streaming/proxy regressions | Entire protocol parser |
| OpenAI Codex Responses/models/compact | Dedicated Codex host path | None | Existing Codex telemetry/logging | Native | Unchanged | `openai_codex_proxy_plug_test.exs`, `router_codex_rejection_test.exs` | Entire dedicated path; live OAuth/provider not run |

## Must preserve in hosts

| Host | Non-target behavior |
| --- | --- |
| Backplane | LLM proxy routes and Relayixir forwarding, credential storage, native Codex transport, production release composition. |
| Sigma | Agent loop, tool execution, logs/session behavior. |
| Synapsis | QueryLoop/tool execution, approvals, daemon/background work, persistence, PubSub, and provider/config ownership. |
