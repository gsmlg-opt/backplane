# Optional Linux LocalCommand PTY helper

Build explicitly with `mix backplane.pty.build`. Normal Mix compilation and
pipe-only construction do not need a compiler. Requires Linux, C11 headers/libc,
a working compiler (`CC`), procfs, `pidfd_open` and `pidfd_send_signal` (normally
Linux 5.3+). The build compiles atomically and runs actual PTY/pidfd probes before
installation. Startup repeats the probe. Sources ship in Hex; generated target
binaries do not. Official Linux OTP/Docker assembly includes the built helper.

Enable with `LocalCommand.start_link(pty: true)`. Trusted optional
`terminal_rows`/`terminal_columns` default to 24/80 and accept 1..1000;
`pty_helper_path` accepts an absolute first-party executable. Each invocation
selects the transport only for `tty: true`. Terminal execution has ordinary
line discipline, echo and foreground control-byte signal handling.

## Version 1 wire protocol

The Port uses unsigned big-endian packet4 lengths; maximum payload 65,536 bytes.
Terminal bytes use `O` output / `I` input frames and cannot impersonate control.
Input is chunked at 65,535 bytes. No line delimiters are added to terminal output.
Queues and session membership are finite; saturation initiates cancellation.
Every descriptor used for broker/guardian IPC or the pre-exec gate is CLOEXEC.

`--probe` prints `BACKPLANE_PTY 1` and exits zero only after actual procfs,
pidfd-open/send-signal and controlling-terminal allocation checks.

`--run TOKEN OWNER INCARNATION SESSION ROWS COLUMNS CLEANUP_MS OUTPUT_LIMIT EXE ARGS...`
uses literal argv/environment/cwd. OWNER is base64url-encoded by Elixir. The target
executes directly, after terminal setup and an authenticated acknowledgement.

| Tag | Direction | Payload |
| --- | --- | --- |
| R | helper → BEAM | `1 TOKEN B B_START G G_START C C_START SID ROWS COLS OWNER INCARNATION SESSION` |
| A | BEAM → helper | Exact TOKEN; opens the one-shot exec gate |
| I | BEAM → helper | Ordinary terminal input/control bytes |
| C | BEAM → helper | Cancel the declared terminal session |
| O | helper → BEAM | Raw terminal output |
| X | helper → BEAM | Original terminal child exit status, independent of helper exit |
| L | helper → BEAM | Bounded output/input transport limit exceeded |
| F | helper → BEAM | Exact R identity followed by `|EXIT|confirmed/uncertain|closed/unknown|dispatched/never_started/unknown|reaped|REASON` |

The guardian owns the master and keeps the original terminal session leader
unreaped until final reconciliation, pinning SID identity. Complete procfs scans
keep ENOENT/ESRCH vanished-entry behavior; other observation errors are uncertain.
Each live member uses a pidfd with starttime/session validation before and after
acquisition. Cleanup sends TERM/CONT, then freezes all observed threads and repeats
complete membership discovery before KILL; it confirms exits with pidfds and a
final census. Externally parented zombies are exited. A bounded failure to establish
quiescence, unreadable procfs, too many members or a D-state process stays uncertain.
The guarantee covers ordinary job-control groups in this session. A deliberate
new session escapes the declared scope. This is no OS confinement boundary.

The guardian sends private cleanup evidence then exits. The broker reaps it
before final F, then exits. Elixir requires both exact positive F and broker Port
exit zero for an existing confirmed-release receipt. Neither leader exit, EOF,
Port.close nor helper exit alone proves cleanup. The child exit remains separate.

The private socket is also a lifeline: broker death/EOF makes the surviving
guardian attempt bounded cleanup. Lost broker or guardian proof remains
`unknown_outcome`; there is no recovery sidecar or numeric-SID retry. The guardian
exits at its deadline even when cleanup cannot be proved. Output queues and IPC
are nonblocking; a stalled consumer cannot prevent lifeline handling/cleanup.
UTF-8 projection holds partial suffixes between polls and deterministically
replaces invalid/final incomplete bytes; this text API is not lossless binary I/O.

Run the real native protocol suite with:

```sh
python3 test/native/pty_protocol_test.py
```

Python is only a test driver, never a production transport dependency. Native
architecture/official-package/release validation are distinct evidence.
