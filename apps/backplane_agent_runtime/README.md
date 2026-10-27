# Backplane Agent Runtime

A standalone embedded OTP execution package. Hosts own sessions, repositories,
configuration, history, UI and public protocols. Optional tools and their backends
start only when selected by the host. No Phoenix, database, Sigma or Backplane
server application is required.

Optional first-party Linux PTY support uses the existing `exec_command` and
`write_stdin` tools. Build with `mix backplane.pty.build`, then start
`Tools.LocalCommand` with `pty: true`; `tty: true` selects the real controlling
terminal per invocation. Ordinary pipe consumers require no compiler. Actual
PTY/pidfd probes must pass; see [native build and cleanup contract](c_src/README.md)
and [Codex terminal setup](CODEX.md#first-party-linux-pty).

Trusted host backends can return `ToolEffects.reject(operation, error)` for a
proved rejection before dispatch, preserving provider continuation without
weakening uncertain-effect handling. Existing adapters returning plain errors
must adopt this explicit contract; see [EMBEDDING.md](EMBEDDING.md).

Optional `hooks.prepare_tool/2` allows, denies or transforms function/custom input
before final validation, authorization, exact-input approval and invocation commit.
Approval input edits require fresh approval, and nested preparation preserves the
outer execution fence; see [EMBEDDING.md](EMBEDDING.md).

Optional `hooks.tool_effect_timeout/2` selects a finite budget for each final
validated and approved invocation before its intent commits. Return `:default`,
`{:ok, milliseconds}` in `1..2_147_483_647`, or `{:error, %Error{}}`. The selector
runs once within the remaining preparation/approval admission allowance, with a
pinned catalog and no runtime interaction, publication or dispatch callbacks.
It cannot replace arguments, identity, backend or authority.

Direct and supported nested tool backends get `backend_context.effect_deadline.()`:

```elixir
{:ok, %{selected_timeout_ms: selected, deadline_ms: expiry,
        remaining_ms: remaining, paused: false}}
```

Read this callback repeatedly to divide initialization, serial work and settlement
within one shared diminishing allowance. The runtime clips that allowance by
finite root and enclosing tool budgets. Human waits freeze active time, return
`paused: true` and `deadline_ms: nil`, then resume with the retained remainder.
Completed/cancelled/expired effects return `{:error, %Error{class: :resource_conflict}}`.
The expiry uses live-VM monotonic milliseconds and may be negative. Never persist
it. The ordinary one-hour option caps, provider total/idle behavior, independent
cleanup limit and low-level `Execution.run/5` contract remain unchanged.

Preparation and backend contexts support token-bound host feedback:

```elixir
{:ok, receipt} = context.append_feedback.(%{
  id: "stable-host-id", text: "Additional context", source: "sigma-hooks", stage: "PreToolUse"
})
```

The four required values are nonempty UTF-8 strings. ID/source/stage allow 256
bytes each; text allows 64 KiB. String field names also work; unsupported fields
and duplicate atom/string aliases fail validation. Runtime supplies the complete
invocation correlation; callers cannot supply identity or authority. A receipt
means the Store acknowledged the canonical record and its producer remained live.
Check `receipt.store_mode`: `:ephemeral` explicitly does not establish durability.
Input rewrites retain invocation identity; feedback acceptance does not imply
approval, dispatch or success. Cancellation and completed producers fence callbacks.

`Conversation.status(pid).conversation.host_feedback` is an ordered collection of
JSON-safe string-keyed records containing `id`, `text`, `source`, `stage`,
`correlation`, `revision`, `store_mode` and `projected`. At the next natural
provider boundary, each record projects once as a user message after the full
tool-result batch: content starts with `[Host feedback]`, and `host_feedback`
metadata carries provenance/correlation. This never starts an extra turn or grants
system authority. Context resets retain the ID ledger. For a replacement run,
pass `host_feedback: previous.conversation.host_feedback` alongside
`messages: previous.messages`; preserve original record identity, even across
runs. Marked canonical messages also reconstruct missing ledger records with
original identities when only messages are supplied. Missing old ledgers default to
empty; restoring `run:` remains inspection-only and does not replay callbacks.

Hosts can bind their own collaboration tool names and schemas to the existing
supervised MultiAgent lifecycle with `Codex.MultiAgent.bind_contract/3` and
`call_bound/2`. Binding grants cover the original descriptor and explicit action;
host adapters convert arguments and results without rewriting admitted invocation
identities. See [host-named collaboration contracts](EMBEDDING.md#host-named-collaboration-contracts)
and the packaged `examples/host_collaboration.exs` example.

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


Long-running interactive turns can explicitly select `run_timeout: :infinity`
and optionally `provider_idle_timeout: 300_000`. Work quotas, tools, commits,
cleanup and native-command limits remain bounded. See `EMBEDDING.md` for the
separate timeout policies and `PERSISTENCE.md` for conservative recovery.

`Backplane.AgentRuntime.Goal` is an optional persistent thread owner for explicit
objectives, token accounting and automatic continuation through the host's
existing Session admission. Enable it with host-owned `Goal.Store` and
`Goal.Host` adapters, then bind each Conversation run. The three existing Goal
tools can use this owner through `Codex.ExtensionRuntime`; ordinary runs create
no Goal. See [EMBEDDING.md](EMBEDDING.md#persistent-thread-goals) for setup and
[PERSISTENCE.md](PERSISTENCE.md#goal-records-and-accounting-recovery) for recovery.
Terminal runs can remove exactly delivered receipt subsets with the
`{:goal_outbox_acknowledged, at, %{run_id: id, incarnation: current, receipts: receipts}}`
Kernel command through the existing Store CAS boundary. It preserves the terminal
outcome and execution evidence; a lost acknowledgement requires reloading the run.

## Plugin connection cleanup

`Plugins.Session` activates an immutable installation for one run. Adapter start,
discovery, calls and close execute in owned supervised workers so cleanup/status
remain responsive. Each activation is recorded before allocation; its connection
is acknowledged before catalog preparation. Failed catalogs retain their cleanup
obligations while skills and healthy components remain available.

`Plugins.Session.close(session, cleanup_timeout: 5_000, timeout: 100)` seals new
catalog/tool admission and starts one shared finite cleanup budget. The optional
`timeout` observes the close; timing out does not cancel or restart it. Repeat
`close/2` or call `cleanup_status/1` to inspect the same retained close identity,
component activation IDs, activation errors and cleanup evidence. The finite
cleanup range is `1..3_600_000` ms. Read-only skill/resource access remains usable.
Interrupted tool calls retain uncertain execution outcomes independently of
connection cleanup; `snapshot/1` retains their call IDs and bounded diagnostics.

`stop/1` returns `:ok` and terminates the coordinator only when every owned
obligation is confirmed. Otherwise it returns a structured `:unknown_outcome`
and keeps the sealed Session available. Failed/lost cleanup callbacks run once;
process DOWN alone does not improve their retained result. Reports live only in
the Session; hosts persist required evidence through their existing lifecycle
adapter. ResourceRegistry's existing confirmation rules remain unchanged.

Legacy adapters explicitly confirm their declared scope with `:ok`, `:done` or
`{:ok, :confirmed | :released | :done}`. Other success-shaped maps provide no
confirmation. The default MCP adapter validates separate transport, client-worker
and supervisor evidence and uses one-shot connections from construction. Plugin
stdio requires the explicitly built `mix backplane.mcp.stdio.build` guardian;
missing/unsupported helpers make that component unavailable before target launch.
A trusted `guardian_path` Session option selects a specific built guardian.
Verified stdio receipts cover the direct child, guardian and local pipes; hosts
own descendants or external effects beyond that scope.
