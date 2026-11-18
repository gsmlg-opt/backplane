# Code Mode backend decision

## Current decision — 2026-11-18

The user requested removing Deno while preserving Code Mode, including `exec`,
`wait` and JavaScript tool orchestration. Migration is authorized; a replacement
backend has not yet been adopted. The current Deno adapter remains in place until
its required guarantees can be preserved. Denox remains retired as a candidate.

The installed and latest published `duskmoon_quickbeam` 10.1.8 was assessed as a
candidate. Its bare native runtime does not provide the required capability
boundary: `apis: false` retains privileged native BEAM handlers, and user code
can spawn a new runtime with browser APIs enabled. This is a confirmed upstream
blocker, tracked in
[duskmoon-dev/duskmoon-bundler#41](https://github.com/duskmoon-dev/duskmoon-bundler/issues/41)
(Bug, `internal request`, severity blocker). No dependency patch, global
scrubbing, private-handler override or reduced isolation is permitted as a local
workaround.

The conditional recommendation is a dedicated external QuickBEAM runner per
cell, retaining the existing bounded NDJSON protocol and OS process identity
cleanup. This is a proposed design, not an implemented or approved backend
selection. Native-engine crashes and stuck callbacks would remain outside the
gateway BEAM. Running the engine externally does not itself close the ambient
capability gap; the upstream strict mode is required first.

### Candidate assessment

Read-only native probes used the installed compiled 10.1.8 artifacts on Linux,
Elixir 1.18.5 / OTP 28, without changing dependency sources or starting gateway
tools. The parent independently reproduced the capability bypass. Architecture
assessment also exercised the remaining bounded engine probes below.

| Requirement | Observed result |
| --- | --- |
| Denied ambient authority | Failed: a bare runtime could access privileged host capabilities and create a child runtime with browser APIs enabled. |
| Supported handler restriction | `Runtime.init/1` always merges default BEAM handlers. No supported strict allowlist configuration was found. |
| CPU interruption | A synchronous loop returned `InternalError: interrupted` with an evaluation timeout. |
| JavaScript heap cap | A 32 MiB `ArrayBuffer` under a 16 MiB cap failed with out-of-memory. This is not a BEAM/native/RSS quota. |
| Retained async generator | Successive calls retained generator state and returned yielded then completed values. |
| Module exports/top-level await | Native `load_module/3` executed an awaited export; that API has no evaluation-timeout parameter. |
| Direct module loading | Bare-runtime imports of `node:fs`, file URLs, HTTPS and data URLs rejected. Do not use the filesystem-reading `script:` startup option for user input. |
| Native engine shutdown | Source confirms atomic interruption and native worker-thread join. |
| Host callback shutdown | An already-started handler completed after `QuickBEAM.stop/1` returned. Native-thread join alone does not establish all-effects cleanup. |
| Synchronous callback deadline | A 150 ms sleep callback completed successfully after about 159 ms despite a 10 ms evaluation timeout. A host deadline must remain independently enforceable. |
| Alternative `QuickBEAM.VM` interpreter | Dynamic function construction and async-generator initial yield were unsupported in probes. Its public evaluation API also starts fresh mutable state per request. It cannot currently preserve the Code Mode contract. |

### Unblock and migration acceptance

First adopt a published upstream version with a supported native capability
policy: only explicitly allowed host handlers, no implicit process messaging,
lookup, RPC or privileged child runtimes, and denied ambient module/addon,
filesystem, network, environment and subprocess access. Verify these restrictions
while allowed asynchronous callbacks still work. Issue closure alone is not
qualification.

Then review the runner design and migrate without changing Backplane ownership
of grants, admission, catalog revisions, Store commits, nested dispatch,
owner/incarnation fences or uncertainty semantics. Preserve generator and module
state, time slices, refreshed authority on `wait`, output/media/notification
behavior and generation-fenced timers. Fence callbacks before cancellation;
confirm actual runner death before releasing resources. Unsettled effects or
unconfirmed cleanup remain `unknown_outcome`.

Acceptance must include existing source-contract, framing, slicing, cleanup,
ResourceRegistry and Conversation regressions, explicit ambient-capability bypass
tests, and isolated package verification with Deno absent. Remove Deno-specific
startup options, JS transport, executable detection, CI setup and current runtime
documentation only as part of the verified replacement. Historical evidence must
remain distinguishable from current behavior. No migration implementation,
runtime/package suite pass, commit or release is claimed by this assessment.

The source contract is Codex revision
`46fdd5ef39735f4159cdcf0ec5e85c10521494e5`. See
[Code Mode conformance](code-mode-conformance.md) for current guarantees,
fixtures, and native-engine differential limits.

## Historical milestone — 2026-10-01

This milestone repaired ordinary commands and the shared Conversation runtime
(R18, R19-runtime, R20, R21). It deferred backend migration and recorded Denox
as a candidate. It did not adopt or verify that candidate.

Existing Code Mode profiles remain explicitly opt-in and fail closed on missing
lifecycle capabilities. Their current Deno adapter and native tests remain in
place. Shared nested dispatch tests use a scripted outer tool through production
Conversation admission, authorization, commits, interaction, and publication;
they are shared-runtime integration evidence, not native Code Mode conformance.

Backplane retains tools, authorization, approvals, budgets, Store commits,
invocation identity, and continuation ownership. A replacement backend must
preserve commit-before-dispatch, exact grants and revisions, cancellation
fences, and accurate reporting of uncertain outcomes.

## Deferred engine checklist

- [ ] Interrupt synchronous JavaScript execution.
- [ ] Enforce resource and memory limits.
- [ ] Cancel callbacks without late dispatch.
- [ ] Confirm execution-thread/runtime shutdown.
- [ ] Verify permission isolation.
- [ ] Verify continuation behavior across provider turns and cancellation.
- [ ] Fence engine timers by generation (R19-engine-deferred).

These obligations remain in full-compatibility reporting. Deferral is not a fix
or compatibility proof. No engine implementation or benchmark is part of this
milestone; existing generator-continuation and native-wire limits still apply.
