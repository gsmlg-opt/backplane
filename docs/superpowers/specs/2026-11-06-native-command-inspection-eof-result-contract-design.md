# Native command inspection, stdin EOF and scoped result contracts

Scope: internal requests #151–#153, implemented on main for the next unified
release (1.10.58). The user's established instruction authorizes autonomous
implementation and publication without another design approval round.

## Ownership and decisions

Keep Command/LocalCommand as command execution and cleanup authority, ResourceRegistry
as owner/incarnation authority, and Execution/Conversation as admission and effect
settlement authority. Do not add a host process mirror or alternate native dispatcher.

For #151, add a public `Codex.Commands` inspection facade and a separate bounded
recent-record map in ResourceRegistry. Original command results add `command_id`
while retaining the existing active-only `session_id`. Capture full bounded backend
output before normal terminal acknowledgement removes the session. Default history
bounds are 64 records, 16 MiB and five minutes. Inspection logs use byte cursors;
inspection polling has a separate cursor from write_stdin. Only finalized inspection
records can be removed/cleared; cleanup obligations and receipts are independent.
Backend completed output for issued sessions remains pinned until release
acknowledgement, under the existing finite backend session capacity. Thus delayed
first collection does not race the ordinary five-second backend cache expiry.

For #152, add optional `Command.close_stdin/3` and `write_stdin`'s optional boolean
`eof`. Write supplied bytes before closing. Raw Erlang Ports cannot half-close;
therefore extend the existing Linux native helper with opt-in `pipe_stdin: true`.
Its pipe mode retains the same verified startup, process identities, output bounds,
cleanup and reaping protocol. It flushes queued input before closing the pipe's
write end and sends a close acknowledgement; this does not terminate the child or
close output. Reject later input. Legacy adapters/raw pipes and PTYs explicitly
report unsupported input-close. Literal Ctrl-D remains ordinary input.

For #153, select a result contract from the trusted descriptor and invocation
identity after binding/auth checks and before durable intent/effect. The selector
cannot inspect tool arguments or returned data. Persist finite positive native
external-size and JSON-value allowances in the operation receipt. Root and nested
native calls reuse that selection. Code Mode accepts a host-issued one-record
allowance tied to the pending call ID; envelope overhead is bounded separately.
Reset to the ordinary framing limit on the next record. Preserve exact accepted
values and retain existing defaults, provider-output accounting, program limits
and unrelated tool allowances.

## Alternatives considered

A host-maintained process registry would duplicate lifecycle ownership. Global tool
output enlargement would widen unrelated tools and still miss JSON framing limits.
Sending Ctrl-D or closing an Erlang Port would not provide pipe half-close. These
alternatives do not satisfy the requested contracts.

## Verification and delivery

Exercise real Linux helper pipe EOF and existing PTY protocol/cleanup, real native
command list/log/poll/finalization and history bounds, direct/nested large ordered
image content with real Deno, persisted contracts and independent transport bounds.
Run the full standalone runtime package gate, source static checks and canonical
remote CI/release gates. Publish unified official packages/archives/image and verify
exact versions and source provenance independently. Downstream adoption and production
deployment are outside this task.
