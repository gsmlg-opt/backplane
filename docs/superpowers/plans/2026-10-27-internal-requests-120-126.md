# Internal Requests #120–#126 Implementation Plan

> **For agentic workers:** Use `subagent-driven-development` for independent slices and `scoped-prd-execution` for integration. Work only in the current authorized main checkout. The coordinator owns Git and release delivery.

**Goal:** Implement the approved 7d82bdb3 contracts and publish verified 1.10.44 packages and release artifacts.

**Architecture:** MCP Protocol owns wire requests and transport cleanup; Plugin Session retains per-activation cleanup evidence. Conversation owns tool deadlines and existing Store/Registry lifecycle authority. Small native/result/archive extensions preserve existing callers.

**Tech Stack:** Elixir 1.18+/OTP 28, http_fetch 0.21.17, POSIX C11 pipe guardian, existing ExUnit/HTTP fixtures, real Deno and canonical GitHub release workflow.

## Execution boundaries

The user approved all four design documents at 7d82bdb3. Preserve unrelated work;
create no branch/worktree. Independent authors own disjoint files. Every shared
Mix/devenv command uses `flock /tmp/backplane-ir44-beam.lock`; Git mutations belong
only to the coordinator. Native standalone fixture builds use task-owned paths.
Do not change unrelated Memory/provider/security policy or downstream source.

## Task 1: HTTP dependency and request cleanup (#120)

Files: MCP Protocol `mix.exs`, `application.ex`, `http.ex`, `sse.ex`,
`transport/sse.ex`, `transport/streamable_http.ex`, its `stream.ex`,
JWT/introspection HTTP callsites, associated tests/conformance HTTP fixtures.
New HTTP lifecycle modules may remain inside this package. No Client/STDIO or
Runtime edits in this slice.

- [x] Add regressions showing neutral Fetch responses and close evidence. A new
  standalone server fixture must resolve without Finch/Mint and serve an MCP call.
- [x] Observe the new assertions fail on the baseline before production changes.
- [x] Replace Finch with the already resolved Fetch dependency and private neutral
  request/response values. Preserve manual 307/origin/header/status behavior.
- [x] Keep allocation/dispatch/body workers outside transport mailboxes, register
  each resource before work, retain original Promise completion handles and abort
  only owned requests. Implement responsive `close/2` and `cleanup_status/1`
  using the approved version-1 report, including every redirect hop.
- [x] Verify existing HTTP/origin/SSE/modern-stream fixtures and the fresh server
  graph. Record exact commands and local completion evidence.

## Task 2: Tool selection and archive history (#121/#126)

Files: Runtime `conversation.ex`, `conversation_adapter.ex`,
`codex/multi_agent/archive.ex`, focused Conversation/recovery tests/fixtures and
owning README/PERSISTENCE documentation sections.

- [x] Add final-input selector and live deadline behavior tests, initially failing
  because the optional hook/getter is absent. Preserve unchanged defaults.
- [x] Add metadata to actual Provider-generated child histories and observe
  export rejection on the baseline before relaxing only the message metadata gate.
- [x] Implement the optional trusted hook:

  ```elixir
  tool_effect_timeout(invocation, context)
  # :default | {:ok, finite_ms} | {:error, %Backplane.AgentRuntime.Error{}}
  ```

  Select once after final approval, before intent; bound it by remaining
  admission/run/outer time. Carry the selection to direct/nested dispatch.
- [x] Arm timer/state before backend execution and provide the runtime-owned
  token-fenced getter:

  ```elixir
  effect_deadline.()
  # {:ok, %{selected_timeout_ms: ms, deadline_ms: absolute_or_nil,
  #         remaining_ms: remaining, paused: boolean}}
  ```

  Preserve pause/resume remaining time and invalidate expired producers.
- [x] Keep shared limit validation unchanged; selected budgets alone accept
  `1..2_147_483_647`. Schedule and promptly cancel real large timers.
- [x] Preserve bounded normalized JSON metadata, closed outer schemas and exact
  authoritative Store/digest equality. Execute no effects during import/export.
- [x] Verify real closure/reconciliation, JSON export/fresh-manager restore,
  explicit new-run continuation and independent cold-BEAM no-replay evidence.

## Task 3: Verified stdio and connection coordination (#122)

Files: MCP Protocol `c_src/`, explicit build task, `transport/stdio.ex`,
new stdio guard protocol module, `transport/behaviour.ex`, `client/supervisor.ex`,
Client close API and focused native/ExUnit tests. Coordinator owns shared files.

- [x] Write a standalone packet4 guardian fixture expecting probe/start/data/close
  identities, actual target reap and helper exit; first fail because the helper
  is absent. Cover EOF, TERM/KILL, nonzero target exit, blocked output, missing
  evidence and a descendant retaining stdout without unbounded wait.
- [x] Implement C11 guardian with bounded nonblocking queues, exact unreaped-child
  signaling and real waitpid; emit its correlated receipt before successful exit.
- [x] Add explicit atomic build/capability task; ordinary compilation requires no
  C compiler. Package sources and build task; verify copied/symlinked priv paths.
- [x] Implement guarded STDIO mode while preserving ordinary direct clients.
  Require both valid receipt and actual helper exit status for confirmation.
- [x] Construct plugin connections as one-shot temporary client/transport trees.
  Keep sealed processes alive for receipt collection; then stop owned children
  and supervisor without replacement. Add `Client.close_connection/2` with one
  finite budget and separate client/transport/supervisor outcomes.
- [x] Verify public close/status under blocked sends and launch counters after
  closure/failure; never infer resource success from transport DOWN alone.

## Task 4: Caller-owned resources (#123)

Files: Client public APIs/internal owned-request machinery, `client/request.ex`,
`client/resource_request.ex`, focused resource/ToolCall/MRTR tests.

- [x] Add three public resource-start fixtures; observe missing API failure.
- [x] Share the current two-phase ToolCall machinery behind type-specific handle
  facades without changing ToolCall representation or tools/call behavior.
- [x] Add dedicated starts, await and cancellation using real resource methods:

  ```elixir
  Client.start_list_resources(client, opts)
  Client.start_list_resource_templates(client, opts)
  Client.start_read_resource(client, uri, opts)
  Client.await_resource_request(handle, timeout)
  Client.cancel_resource_request(handle, reason, opts)
  ```

  Retain logical ownership across MRTR wire IDs and progress callbacks.
- [x] Verify bounded registration, ordinary ordered pagination/read metadata,
  nonterminal await observation timeout, owner loss and cancelling one caller
  while another completes and the shared client continues serving requests.

## Task 5: Retained Plugin Session cleanup (#122)

Files: Runtime `plugins/session.ex`, `plugins/mcp.ex`, focused Plugin Session tests.

- [x] Reproduce two real adapter connections: one successful stop and one explicit
  cleanup failure retaining its process. Observe Registry's false confirmation.
- [x] Register activation obligations before catalog preparation. Run calls and
  cleanup in owned supervised workers; preserve ready/partial startup behavior.
- [x] Add `close/2` and `cleanup_status/1`, stable per-activation/close identities
  and retained component outcomes, using one finite cleanup budget.
- [x] Make repeated close observation-only and make stop return `:ok` only for
  aggregate confirmation; otherwise preserve a sealed inspectable Session and
  return structured unknown outcome. Keep Registry classification unchanged.
- [x] Integrate actual default adapter transport/connection receipts, partial
  activation/catalog failure and responsive status during blocked calls.

## Task 6: Explicit plugin and answer outcomes (#124/#125)

Files: Runtime `codex/dynamic_runtime.ex`, `codex/web.ex`, focused result tests and
CODEX documentation. No Plugin Session, HTTP provider or installer policy changes.

- [x] Add public native completion and answer-only tests and observe baseline
  requested/malformed behavior before implementation.
- [x] Accept only the explicit plugin variant:

  ```elixir
  {:ok, {:completed, %{completed: true, user_confirmed: actual_boolean,
                       tool_type: type, action_type: action, tool_id: id}}}
  ```

  Bind `operation.plugin_request_id`, validate exact request identity and complete
  the same receipt; retain legacy requested maps/lists and actual uncertainty.
- [x] Keep valid results lists first, then accept tagged answer content/citations
  in either key style, preserving the original map and whole-map size bound.
- [x] Verify actual local package installation separately from shape fixtures,
  direct/real-Deno native output, next model input/journal, root/child identities
  and exact settled replay without installer re-execution.

## Task 7: Integrated verification and delivery

Files: required package verification/build/CI/release/Docker contract integration,
owning docs, approved design status and scoped release metadata.

- [x] Review each slice for spec compliance, then code quality; repair findings
  before marking it accepted. Review the combined diff and file ownership.
- [x] Run focused tests, owning package suites, strict compile/format/Credo,
  exact-CI-toolchain Dialyzer, package builds, native helper and cold-BEAM probes.
- [x] Run `mix run --no-start test/ci_workflow_test.exs` and
  `mix run --no-start test/release_config_test.exs` after required helper-build
  workflow changes. Do not weaken release gates or fix out-of-scope failures.
- [ ] Audit scoped commits; push main and wait for required exact-SHA CI.
- [ ] Recheck free version and dispatch
  `gh workflow run release.yml --ref main -f version=1.10.44 -f release_apps=all`.
- [ ] Wait for all jobs, then verify GitHub archives/checksums/provenance, five
  official Hex/HexDocs packages and fresh package behavior, GHCR version/latest,
  and final local/remote convergence. Publication does not include deployment or
  downstream application adoption.
