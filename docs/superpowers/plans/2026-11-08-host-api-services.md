# Host API Services Implementation Plan

> For agentic workers: execute this approved plan with scoped-prd-execution.
> The coordinator owns integration and shared build/test state. No commits,
> branches, worktrees, publication, or deployment are authorized.

**Goal:** Configure host-local API services in Backplane and call them through
the authenticated host-agent connection.

**Architecture:** Llama owns service configuration and existing provider links;
System owns the transport registry; API adapts authenticated host channels; the
standalone agent performs bounded concurrent HTTP forwarding. Existing routes
select providers and models before entering the host transport.

**Tech Stack:** Ecto/PostgreSQL, Phoenix channels/LiveView, Plug, Req, supervised
OTP processes, DuskMoon components, ExUnit.

## Execution scope

- Parent: this spec/plan, System transport and supervision, API channel binding,
  Llama router/proxy integration, focused integration tests, deployment guide.
- Host worker: agent API forwarder/supervision/channel capability callbacks and
  focused agent tests only.
- Platform worker: Llama HostService context/schema, provider links/credential
  validation/discovery guards, migration, admin service/provider configuration,
  and focused context/LiveView tests. Do not edit router/proxy or channel code.
- Preserve the pre-existing edits in `docs/deploy/release-workflow.md`,
  `scripts/publish_hex_package.py`, and its publication tests.

## Tasks and observable checks

- [x] Persist host services and link compatible LLM/embedding providers. Validate
  exact HTTP(S) endpoints, supported protocol keys, host ownership, disabled
  services, and optional credentials only on hosted providers. Tests create a host
  and service, attach providers, resolve their models, and reject incompatible APIs.
- [x] Expose platform CRUD and provider service selection using existing DuskMoon
  conventions. LiveView tests submit the forms, edit/disable services, and verify
  saved configuration and safe errors; never render plaintext credentials.
- [x] Implement the System request transport with per-call ownership, generation
  fencing, bounded chunk acknowledgement, caller/channel monitoring, cancellation,
  and explicit terminal outcomes. Unit tests simulate host/channel replacement,
  invalid frames, downstream failure, and unacknowledged chunks.
- [x] Bind host channels to the transport only after successful authenticated join;
  reject unsupported agents, revoked tokens, stale replies, and wrong-host calls.
  Send authoritative service inventories without credentials.
- [x] Implement supervised host execution using the configured endpoint for the
  selected protocol. Tests use real local HTTP responses, split SSE events, large
  bodies, cancellation, unavailable declarations, and configuration replacement.
- [x] Connect the existing embeddings/Chat Completions/Responses/Messages routing
  paths to the host proxy before direct URL rewriting. Preserve model mapping,
  error status/body, observation, headers, and client authentication stripping.
- [x] Verify the complete local path with fake upstream HTTP services, including
  one ordinary and one streamed call, exact paths and credential injection, then
  run direct-provider regression tests.
- [x] Update host-agent deployment documentation with platform configuration and
  transport limits. Format only changed files, compile, review the full integrated
  diff, and report executed checks plus any unverified runtime boundaries.

## Verification commands

Run Mix commands serially via `devenv shell --no-tui -- mix ...`. First execute
new focused tests in System, Llama, Host Agent, API, and Admin; then the existing
related provider/router/channel/worker suites. Run `mix format --check-formatted`
on changed Elixir files and `mix compile --warnings-as-errors` after integration.
Do not fix independent baseline failures or broaden into release checks.

## Verification evidence

- Scoped integration run: System 8, Llama 165, Admin 17, Host Agent 29,
  API 8 tests; all passed (227 total). The final API suite adds a real WebSocket
  host-agent callback test and passes 9 tests, bringing unique coverage to 228.
- The real socket test forwards a response exceeding a channel chunk, preserves
  the requested model and SSE end marker, and automatically re-registers after
  changing the endpoint URL. Other API tests cover all four protocols, exact
  paths/query strings, credential replacement, raw HTTP errors, disabling and
  updating services, acknowledgment backpressure, revocation and downstream
  cancellation. Model mapping also preserves unfinished provider bytes at EOF.
- Changed-file formatting, warnings-as-errors compilation, and whitespace checks
  passed. Existing related provider/discovery/embedding and admin regressions are
  included in the passing scoped run.
- The separately executed existing HostAgentChannel suite ran 60 tests with 10
  failures. Diagnostics include missing PostgreSQL `$libdir/vector` and
  `$libdir/dict_snowball` shared libraries, plus Memory storage/import failures.
  Those environment/Memory paths were not repaired; this is not an all-tests-green
  claim. Sandbox ownership/disconnection warnings also appeared in passing runs.
- No production restart/deployment, real Ollama/SGLang/vLLM qualification, browser
  visual review, commit, push, release, full suite, Credo or Dialyzer was performed.
