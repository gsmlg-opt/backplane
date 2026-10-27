# Verified MCP stdio guardian

Verified mode owns exactly one target direct child, the guardian process, and
its local stdin/stdout/exec-status pipes. It does not own daemonized descendants
or certify remote execution, side effects, or process-group termination.
Ordinary STDIO remains the default and needs no helper or C compiler.

Build explicitly from the umbrella, package, or dependency consumer:

```sh
mix backplane.mcp.stdio.build
# Optional destination, including an installed release's priv directory:
mix backplane.mcp.stdio.build --output /absolute/priv/bin/backplane-mcp-stdio-guardian
priv/bin/backplane-mcp-stdio-guardian --probe
```

The package task resolves sources from its own compiled source directory, not
from the consumer's current directory or a symlinked build priv path. The shell
script compiles C11 with warnings as errors, probes a temporary executable and
atomically replaces the destination. `CC` selects the compiler. Linux and macOS
are supported; unsupported platforms fail explicitly. No generic Mix compiler,
`on_load`, application startup or transport activation builds the helper.
Releases and containers shipping verified mode must explicitly build/probe and
copy this executable through their existing package build workflow.

Use `cleanup: :verified` in STDIO transport options. `guardian_path` may select a
trusted built helper. Missing or incompatible helpers fail their bounded probe
before any target launch. The environment, cwd and argv are passed through the
same Port environment/cwd contract as ordinary STDIO. Target stderr remains
separate from protocol stdout.

The helper waits for an acknowledged version/identity handshake before forking.
A close seals input, closes target stdin, allows up to a quarter of the remaining
budget (capped at 250 ms) for EOF exit, sends TERM, then KILL at half the original
budget if necessary. Every signal first performs nonblocking waitpid and is sent
only to the guardian's still-unreaped direct child. No process-group signal or
post-reap PID probe is used. Actual waitpid status is retained even when the
target exits nonzero. At reap, `FIONREAD` snapshots the finite unread stdout
bytes. The helper drains that snapshot in bounded reads across queue flushes
before closing its local pipes; it does not await EOF or later descendant
writes. The original close deadline still bounds a blocked output consumer.
A failed snapshot emits a typed error rather than silently dropping buffered
output. An unrelated descendant retaining stdout cannot extend the deadline.

Input/output queues each have a fixed 1 MiB bound, input packets have at most
65,536 data bytes, and output reads use at most 16 KiB. Both directions are
nonblocking. Full target output pauses reads without blocking control input;
full input rejects the exchange with a typed error. The guardian processes close
while queues are saturated. If the host will not drain the guardian's output,
the native deadline still stops the attempt; a missing receipt remains
unconfirmed. The transport also uses non-suspending Port commands and retains
one immutable close report while remaining sealed for inspection.

Confirmation requires a valid activation/close-correlated receipt **and** an
observed successful guardian `:exit_status`. A receipt records actual target
reap, exit/signal status and local pipe closure before the guardian exits. Port
DOWN, stdout EOF, helper exit alone, a close command, or deadline teardown is not
substituted for missing facts. Partial target/pipe facts remain visible if the
helper exits nonzero. Local cleanup may be confirmed after a nonzero target exit;
this does not claim the target operation succeeded. Failed/uncertain cleanup is
never automatically retried, and a late Port event cannot promote a stored
unconfirmed report.

## Wire protocol version 1

Packets have a four-byte unsigned big-endian body length, including a one-byte
type. Zero or oversized lengths fail before allocating dynamic buffers. Control
and target bytes have distinct packet types, so target output cannot forge a
receipt. All integers below use network byte order.

| Type | Direction | Payload after type |
| --- | --- | --- |
| 1 HELLO | helper to BEAM | version u16 (=1), activation nonce 16 bytes |
| 2 ACK | BEAM to helper | activation nonce 16 bytes |
| 3 STARTED | helper to BEAM | activation nonce 16 bytes, direct-child PID u32 |
| 4 DATA_IN | BEAM to helper | 0..65,536 target stdin bytes |
| 5 DATA_OUT | helper to BEAM | target stdout bytes (at most 16 KiB per read) |
| 6 CLOSE | BEAM to helper | activation nonce, close nonce 16 bytes, remaining budget u32 ms |
| 7 RECEIPT | helper to BEAM | activation nonce, close nonce, PID u32, status kind u8, status u32, reaped u8, pipes-closed u8, TERM-sent u8, KILL-sent u8 |
| 8 ERROR | helper to BEAM | bounded diagnostic code u32 |
| 9 TARGET_EXIT | helper to BEAM | PID u32, status kind u8, status u32 |

Status kind 0 means exit code; 1 means terminating signal. Receipt booleans are
strict 0/1, and confirmation requires reaped=1 and pipes-closed=1. TARGET_EXIT
alone is partial evidence; it seals admission but does not imply guardian exit.
The separate close nonce correlates a single immutable close attempt. The public
activation/close IDs qualify report resource IDs; raw wire nonces are not included
in reports. ERROR codes 1..15 identify pipe/setup/fork/identity/frame/queue/exec
failures without copying target arguments, environment or arbitrary stderr.

## Focused checks

After explicit build:

```sh
python3 test/native/stdio_guardian_protocol_test.py priv/bin/backplane-mcp-stdio-guardian
mix test test/backplane/mcp_protocol/transport/stdio_cleanup_test.exs test/backplane/mcp_protocol/transport/stdio_test.exs
```

Native tests use real POSIX children for EOF, TERM/KILL, nonzero exit,
buffered multi-chunk JSON-RPC after target exit and during close, descendant-held
stdout, saturation, packet bounds and control/data separation.
ExUnit checks real JSON-RPC bytes, argv/env/cwd, responsive retained reports,
helper loss, deadline exhaustion and negative receipt/helper-exit combinations.
The fault helper is explicitly synthetic and never launches a target; positive
cleanup confirmation comes from the built native guardian.
