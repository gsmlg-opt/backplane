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
  `exec` and function `wait` contracts. The opt-in Deno worker has no ambient
  filesystem or network access. Nested calls re-enter the admitted Conversation
  dispatcher with the existing run, authority, revision, budget, and audit path.
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
relevant MCP/plugin adapters; Code Mode needs `Codex.ResourceRegistry` and Deno;
service and hosted tools need host-owned adapters and credentials. Selecting no
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
