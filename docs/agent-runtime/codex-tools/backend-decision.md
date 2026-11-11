# Code Mode backend decision

## Current decision — 2026-11-10

Denox is retired as a candidate for the next Code Mode backend. Backplane
currently uses the packaged Deno process adapter. Selection of its successor
remains open.

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
