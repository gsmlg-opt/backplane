# LocalCommand on macOS (#159)

## Goal and scope

Allow the existing LocalCommand adapter to execute ordinary commands on macOS
without Linux procfs or a separately installed setsid executable. Preserve the
Runtime/Command ownership, execution budgets, cancellation, and confirmed-release
contracts. Sigma can continue to supply its own PTY transport. Backplane's optional
verified PTY and pipe-half-close implementation remains Linux-specific.

## Design

Keep Linux's existing setsid and procfs implementation. Add an explicitly built,
first-party native command helper for macOS session creation and kernel process
observations. Ship its source in the Runtime package and expose
`mix backplane.command.build`; never invoke a compiler during normal compilation
or backend startup. Fail with an actionable capability error when the required
helper is unavailable.

A shell-only ps/kill implementation would require parsing platform-specific output
and cannot reliably distinguish observation errors from process disappearance.
Requiring GNU setsid would add a consumer dependency without solving identity or
cleanup checks. A small native helper keeps those operations within one audited
platform boundary and preserves existing caller APIs.

All launcher, session, owner-cancellation and shutdown checks must use the correct
platform observer. Group-leader disappearance alone does not prove group cleanup.
Unreadable identity, malformed helper output, permission failures and timed-out
observations remain uncertain; they cannot issue a confirmed-release receipt.
Trusted executable paths are resolved and validated at construction, keeping
subsequent PATH changes outside dispatch and cleanup decisions.

## Verification and delivery

Add portable functional tests covering execution, deadlines, output budgets,
cancellation, remaining descendants after leader exit, concurrent sessions and
owner/backend shutdown. Run these in an isolated standalone Runtime source package
on Linux, macOS Intel and macOS ARM64. Native helper construction is explicit in CI.
Keep Linux's existing complete Runtime and native PTY suites.

Run the workflow/release contract checks and inspect the combined diff, then commit
and push only this scope on main. Release the next patch through release.yml after
required verification. Preserve pre-existing unrelated local publication edits.
Report any independent baseline failures separately; do not repair or bypass them.
