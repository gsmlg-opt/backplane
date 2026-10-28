# Resource retirement and host composition implementation plan

> For agentic workers: execute the approved spec task by task, with disjoint file ownership and coordinated integration. Work in the existing main checkout; no branches/worktrees.

**Goal:** implement #141–#143 and publish verified official 1.10.50 packages.

**Architecture:** keep Conversation as the owner of ACK and cleanup. Bind native registration to real Registry workers; turn validated scope cancellation into typed durable retirement. Provide trusted host data separately from provider context.

**Tech stack:** Elixir/OTP, ExUnit, real Deno, MCP stdio fixtures, GitHub Actions and Hex.

## 1. Regressions and public context

- [x] Extend headless_test.exs with original resolver preparation/timeout hooks using host_context and a real nested effect. Check Store intent/result ACK and worker closure.
- [x] Extend plugin_wait_retirement_test.exs to run direct/Deno cases with transparent execution/presentation adapter as well as native backend, including exec and resumed wait.
- [x] Extend codex_resource_scope_test.exs to assert actual retained scope/outer proofs and use public Reconciliation with authoritative Store after cancellation.
- [x] Run new cases before fixes and retain failures under /tmp/backplane-1.10.50-internal.

Run owning Runtime tests, serialized with `flock /tmp/backplane-ir50-beam.lock devenv shell --no-tui -- env MIX_ENV=test mix do --app backplane_agent_runtime cmd mix test test/backplane/agent_runtime/headless_test.exs test/backplane/agent_runtime/plugin_wait_retirement_test.exs test/backplane/agent_runtime/codex_resource_scope_test.exs --seed 0`.

## 2. Portable retirement validation

- [x] In tool_effects.ex validate the exact resource_scope_retirement schema from the approved spec and existing public aggregate receipt fields.
- [x] In codex/reconciliation.ex accept the new type and nested reference, preserving exact intent, Session, source generation and nested digest checks.
- [x] Add focused tests for actual public records and malformed/foreign records; no fabricated lifecycle acceptance evidence.

Record construction from an already validated report:

```elixir
Evidence.public(%{
  schema_version: 1, record_type: :resource_scope_retirement,
  identity: ToolEffects.cancellation_identity(operation),
  stop_generation: generation,
  provenance: %{session_binding_identity: operation[:session_binding_identity]},
  cancellation: report, executor_down: true, resources: :confirmed,
  local_cleanup: :confirmed, outcome: :unknown
})
```

Seal with `Evidence.seal(record, "retirement_digest")`, validate against original operation, and retain only when all actual cleanup requirements pass.

## 3. Conversation and native execution integration

- [x] In conversation.ex merge provider_context compatibility data with host_context for tool hooks, strip inspection capabilities, and retain original provider-only context for provider effects. Validate host_context as a map at admission.
- [x] Pass register_code_mode through trusted backend context; bind its token, effect caller and exact invocation to a real Registry continuation and worker before CodeMode starts/resumes guest execution.
- [x] In codex/code_mode.ex register the worker after adoption and before begin_worker, and register a fetched wait continuation before resume. Standalone execute/resume remain compatible.
- [x] Replace cooperative_outer module matching with current invocation-bound registration. Clear registration at outer settlement; never infer execution from family metadata.
- [x] In finish_cooperative_cleanup create scope proofs only after real executor and resources close; include scope references alongside plugin references in outer_retirement and durable cleanup evidence.
- [x] Run focused cases and inspect combined diff.

## 4. Documentation and release

- [x] Update Runtime EMBEDDING.md/CODEX.md/PERSISTENCE.md for public host_context, transparent native adapter and durable resource retirement contracts.
- [ ] Run full Runtime, strict compile/format/Credo, configured Dialyzer, workflow contract, package/consumer qualification and applicable exact-SHA CI; record unrelated failures without repairing them.
- [ ] Commit scoped changes with fixes #141–#143, push main, dispatch canonical unified release workflow for 1.10.50 after required gates.
- [ ] Verify all terminal publication jobs, five official Hex packages/fresh exact-version consumers, archives and container provenance; close eligible issues with concrete evidence.
- [ ] Review final clean tree and local/remote/tag convergence. No deployment or downstream upgrades.
