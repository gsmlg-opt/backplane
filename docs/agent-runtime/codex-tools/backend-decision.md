# Current Code Mode adapter scope — internal request #54

The current PR extends the existing packaged Deno process adapter. It does not
migrate to Denox. The source contract remains Codex revision
`46fdd5ef39735f4159cdcf0ec5e85c10521494e5`; current guarantees, fixtures, and
remaining native-engine differential limits are described in
[code-mode-conformance.md](code-mode-conformance.md). The milestone recorded
below is historical and does not describe these new changes.

# Code Mode backend decision — 2026-10-01

The current milestone repairs ordinary commands and the shared Conversation
runtime (R18, R19-runtime, R20, R21). Code Mode execution-backend selection and
migration are deferred by the user. Denox NIF is the preferred future candidate;
it is neither adopted nor verified by this milestone. No Denox dependency,
adapter, engine framework, or additional Deno process infrastructure is added.

Existing Code Mode profiles remain explicitly opt-in and fail closed on missing
lifecycle capabilities. Their current Deno adapter and native tests remain in
place. Shared nested dispatch tests use a scripted outer tool through production
Conversation admission, authorization, commits, interaction, and publication;
they are shared-runtime integration evidence, not native Code Mode conformance.

Backplane retains tools, authorization, approvals, budgets, Store commits,
invocation identity, and continuation ownership. A future Denox integration
would provide JavaScript execution and low-level engine lifecycle capabilities,
not scheduling or authorization authority. It must retain commit-before-dispatch,
exact grants/revisions, cancellation fences, and honest uncertain outcomes.

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
