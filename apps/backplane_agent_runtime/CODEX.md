# Codex Tool Profiles

`Backplane.AgentRuntime.Codex.profile/4` is the runtime-owned boundary for
explicit Codex profiles. It binds trusted host resources into descriptors,
requires exact run grants and descriptor revisions, and returns one
`ToolCatalog` registry/tools/authority bundle for `Conversation`.
`definitions/0` retains the local provider definitions for compatibility.

Every model-callable profile below dispatches through
`Conversation -> Execution.commit/dispatch`. `Codex.Backend` receives the
descriptor-owned `backend_context` only after the intent commit. Model arguments
cannot select adapters, credentials, workspaces, environments, or grants.

## Profiles

- `:pinned_local` exposes configured `exec_command`, `write_stdin`,
  `apply_patch`, `update_plan`, `view_image`, `clock::curr_time`, and
  `clock::sleep`. `apply_patch` is a custom/freeform tool using the pinned Lark
  grammar; raw input follows the same admission and commit path as JSON input.
- `:interactive` exposes configured synchronous/asynchronous user interaction,
  permission request, environment readiness, `new_context`, and
  `get_context_remaining` tools. Host callbacks authenticate replies, apply
  grants, and supply authoritative readiness/token state.
- `:collaboration_v1` and `:collaboration_v2` expose their distinct pinned names.
  `Codex.MultiAgent` owns wait/list state and starts child `Conversation`
  processes under a `DynamicSupervisor`; child options and authority come only
  from the host.
- `:extensions` exposes 27 concrete goal, memory, skill, history, note, and
  message-board tools. The bundled scoped reference state is ephemeral. A host
  adapter is required before claiming durability or restart recovery.
- `:dynamic` conditionally exposes MCP resource operations, `tool_search`, and
  plugin request tools. Search publishes admitted tools for the next provider
  turn; another call in the discovery batch remains fenced to the old catalog.
- `:code_mode`, `:code_mode_only`, and `:mixed` expose the pinned freeform
  `exec` and function `wait` contracts only when the host can verify Deno
  process identity and bounded cleanup. Deno presence alone is insufficient;
  the current native adapter requires Linux `/proc` and `kill`, and unsupported
  hosts are rejected before a cell or nested tool can start. The opt-in Deno
  worker has no ambient filesystem or network access. Nested calls re-enter the
  admitted Conversation dispatcher with the existing run, authority, revision,
  budget, resource owner, catalog callbacks, and audit path.
- `:service_compat` exposes only configured service adapters. It includes the
  pinned `web::run` and `image_gen::imagegen` contracts plus explicit Backplane
  compatibility tools `web::fetch`, `web::search`, and `web::x_search`.
- `:configured` combines explicitly selected `:local`, `:interactive`,
  `:collaboration_v1` or `:collaboration_v2`, `:extensions`, `:dynamic`,
  `:code_mode`, and `:services` families. Missing families and duplicate
  canonical names fail before admission.

Provider-hosted capabilities are separate from local tools. A configured
provider adapter negotiates them and `:configured` returns them in
`profile.hosted_tools`; they are never inserted into `ToolRegistry`. The current
projection supports the pinned `web_search` declaration and normalizes observed
provider events. Local tests use an injected adapter and do not establish live
provider compatibility.

## Host Requirements

Profiles are capability-driven and fail closed. Command tools need the selected
workspace, command adapter, caller identity, and `Codex.ResourceRegistry`; plan
needs a host-started `Plan`; collaboration needs `Codex.MultiAgent`; extensions
need `Codex.ExtensionRuntime`; dynamic tools need `Codex.DynamicRuntime` plus the
  relevant MCP/plugin adapters; Code Mode needs `Codex.ResourceRegistry`, Deno,
  and a verified process-lifecycle capability; service and hosted tools need
  host-owned adapters and credentials. Selecting no
profile starts none of these resources.

Existing consumers can upgrade without selecting a Codex profile; their current
`Execution`, `ExecutionController`, provider, and tool APIs remain available.
To opt in, start only the required host runtimes, call `Codex.profile/4` with the
run's exact grants/revisions, and pass the returned `registry`, `tools`, and
`authority` together to `Conversation`. Do not merge profile fields with an old
catalog or persist `backend_context`, PIDs, callbacks, credentials, or grants.

The standalone local example is `examples/codex_local.exs`:

```sh
mix run --no-start --no-deps-check apps/backplane_agent_runtime/examples/codex_local.exs
```

On Linux it uses the existing `LocalCommand` process-group backend. On other
platforms it uses an explicitly labelled one-shot `System.cmd` example adapter
because production `LocalCommand` currently requires Linux `/proc`, `setsid`,
and process-group probing. PTY compatibility is not claimed.

## Compatibility Boundary

The exact 66-entry inventory for Codex revision
`46fdd5ef39735f4159cdcf0ec5e85c10521494e5` is packaged as
`priv/codex/source-inventory.json`. Per-family contract, execution,
availability, and parity evidence is maintained under
`docs/agent-runtime/codex-tools/`. Source presence does not establish behavior.

The old direct-call `clock` and time-waiting `wait` names remain Backplane
compatibility aliases and are not in `:pinned_local`. The pinned `wait` name is
the Code Mode continuation. Hosted search is `web_search`, standalone service
search is `web::run`, and image generation is `image_gen::imagegen`.

Compatibility remains adapted rather than unqualified full parity:

- Code Mode `wait` resumes a stored generator continuation, not the pinned
  time-sliced running-cell implementation.
- Linux process-group cleanup and PTY behavior are unavailable on macOS.
- Extension reference state is ephemeral unless a durable host adapter supplies
  and verifies recovery.
- Full pinned output schemas, all schema property descriptions, and native Codex
  event/wire differential coverage remain incomplete.
- Production MCP, web/image services, and provider-hosted tools were not tested
  against live backends.

Code Mode backend selection and migration are deferred. Denox NIF is the preferred
future candidate, not an adopted or verified backend. This milestone repairs
ordinary command lifecycle and shared Conversation timers/nested publication;
it does not verify engine interruption, isolation, resource limits, callback
cancellation, thread shutdown, continuations, or engine timer generations. The
existing opt-in profiles, capability gates, adapter and native tests remain.
See `docs/agent-runtime/codex-tools/backend-decision.md` in the repository for
the deferred checklist. Shared-runtime nested-dispatch tests do not establish
native Code Mode conformance.

## Command response budgets

`exec_command.max_output_tokens` and `write_stdin.max_output_tokens` bound the
output returned by each call, independently of `Command.output_limit`, which is
a host-owned backend hard limit. The response uses a four-bytes-per-token
estimate (default 10,000); it is not tokenizer accounting. Results expose
`output_budget_unit: :estimated_token_bytes`, `output_truncated`, and
`omitted_output_bytes`. A poll advances past the entire observed backend batch,
including intentionally omitted bytes; the next poll does not repeat that batch.
UTF-8 prefixes are not cut inside a character.

Results retain backend `status`, exit status when available, termination and
cleanup evidence, and `output_limit_exceeded?`. A hard-limit termination is not
a successful command merely because an exit code is missing. LocalCommand keeps
its bounded output buffer and Linux process-group cleanup; descendants that
create a separate session remain outside that backend's cleanup guarantee.

Command output retention is bounded independently from cleanup evidence. A failed
cleanup keeps the invocation/session, owner incarnation, process-group and
workspace association until an explicit reconciler confirms release. Expiring a
completed output record therefore cannot make `session_cleanup_status/1` or
owner cleanup report `:confirmed`; unknown identities remain distinct from known
never-launched reservations and confirmed-release receipts.

Collaboration close is idempotent. Closed or interrupted records retain closure
state and any uncertain settlement evidence, recursive close skips confirmed
descendants, and stale monitor notifications are fenced by run identity. The
manager does not terminate unrelated peers when a descendant cannot establish
settlement.

## Worker framing

The packaged Deno worker runs with explicit denied ambient permissions using
`deno run` and a data URL. Its stdin protocol is bounded NDJSON: UTF-8 decoding
is streaming, only newline-terminated records are parsed, and a record is limited
to 1 MiB before buffering. Malformed JSON, invalid UTF-8, oversized records, and
incomplete records at EOF produce an explicit protocol error and exit the worker.
The Elixir port also assembles bounded records independently of pipe read sizes.
`codex_framing_test.exs` deterministically splits raw records and UTF-8 bytes in
the actual packaged JavaScript source; separate tests exercise the real
`CodeMode.execute` worker with large source and nested results. Those framing
tests alone are not evidence of cross-provider-turn continuation behavior.

## Patch results

`apply_patch` parses operations and ordered line hunks before modifying files.
Anchors, EOF constraints, whitespace/punctuation matching, additions and
rename-with-edit follow the pinned parser/application semantics while preserving
workspace and symlink checks. Move destinations may create parent directories.
The legacy direct-call move form remains a Backplane compatibility extension.

Patches are not whole-patch atomic. Successful operations appear in `files`;
on a later failure they remain in `Error.details.files`. A failed write can
leave uncertain content and reports `:unknown_outcome` with `uncertain_files`.
Callers must inspect this evidence rather than treating an error as proof that
nothing changed. Malformed bodies are rejected before executing any operation.
