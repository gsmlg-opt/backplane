# Codex command host adapters

`exec_command` and `write_stdin` retain the host command adapter's admission,
owner/incarnation fences, bounded output, deadlines and confirmed cleanup path.
The Runtime commits the authorized invocation before dispatch. PTY support adds
no OS sandbox and does not grant additional command or workspace authority.

## Proven non-start refusals

Adapters may implement the optional `Command.validate_refusal/3` callback. Return
`:ok` only when trusted backend evidence proves that the exact invocation never
executed. A missing job, generic launch failure, task exit, or error metadata is
insufficient. Missing or rejected proof retains uncertain settlement semantics.

`LocalCommand` authenticates prelaunch workspace/capacity refusals with a
per-server HMAC bound to the session, owner, incarnation and exact error. The
opaque proof remains in the internal error cause and is removed from the model
response after validation. Proof does not accumulate permanent backend receipts.
The unused resource is withdrawn only for a validated refusal that created no
backend reservation; existing reservations require confirmed cleanup and receipt
acknowledgement. The resulting `{is_error: true, error: ...}` tool result is
committed normally and permits provider continuation. Ambiguous launch or cleanup
failures remain `unknown_outcome` and stop the conversation.

## Host PTY capability

The optional `Command.capabilities/1` callback may advertise:

```elixir
%{
  pty: %{
    verified: true,
    platforms: [{:unix, :linux}],
    rows: 24,
    columns: 80
  }
}
```

This is a trusted host assertion about its adapter implementation, never a
provider-supplied capability or an OS sandbox guarantee. The current
`:os.type()` must appear in `platforms`; absent/unverified support rejects
`tty: true` before resource reservation. Rows and columns default to 24 and 80
and must be integers between 1 and 1000. Dimensions belong to host configuration;
the pinned Codex argument schema has no resize operation.

The adapter receives `tty: true` and `terminal: %{rows: ..., columns: ...}` in
its `start/3` request. It must return the same bounded job handle used by ordinary
commands, preserve raw input bytes (including control characters) in `write/4`,
and support incremental `read/4`. The numeric session remains scoped to its
owner and incarnation. A completed task or closed terminal is not proof of OS
process-tree cleanup: `cancel_confirmed/3` must reconcile actual owned processes,
and `acknowledge_release/2` consumes confirmed evidence. The bundled Linux
`LocalCommand` supplies pipes only; PTYs require a host adapter.

The native Linux regression uses a test-only Python `openpty`/controlling-terminal
adapter over `LocalCommand`'s verified process group. It checks 80 by 24 terminal
dimensions, owner/incarnation rejection, incremental input, Ctrl-C delivery,
session retirement and disappearance of the owned OS process group. Python is
not a Runtime dependency or a bundled production PTY implementation.
