# LocalCommand macOS session helper

Build explicitly on the target host with `mix backplane.command.build`. The
packaged C11 source requires a compiler and the macOS SDK; Linux can also build
the launcher/probe source. Normal compilation does not run a native build.
Hex ships source, not generated binaries. `LocalCommand.start_link/1` on macOS
rejects a missing or incompatible helper with this build instruction.
`:session_helper_path` accepts a trusted absolute executable snapshot; the path
is pinned at construction, like Linux bootstrap executable paths.

The helper forks a child, calls `setsid`, then starts the existing blocked shell
launcher with literal arguments. Before acknowledging execution, Elixir checks
its parent, process group and session against the Port-owned helper and child
PIDs using `proc_pidinfo` and `getsid`. Startup does not depend on `/proc`, a
third-party `setsid`, Python, or PATH-visible process inspection commands.

Cleanup uses `kill(-pgid, 0)`: success or EPERM proves presence, ESRCH proves
absence, and other failures retain uncertainty. The check includes a group whose
leader exited. TERM/KILL target that same group. Confirmation additionally waits
for the original session helper PID to disappear; reused PIDs conservatively
retain the obligation. Pending-launch and backend-shutdown confirmation use the
same authoritative liveness boundary. A deliberate new session escapes this
process-group scope; this is not an OS sandbox.

`--process PID` serves native Code Mode: it prints the kernel start time and `R`
or `Z` (exited, unreaped) from `sysctl(KERN_PROC_PID)`, which also reads zombies,
or `absent` when the PID does not exist. Code Mode pairs PID with that start time,
so a reused PID is never mistaken for its Deno worker; probe failures stay uncertain.

This helper supports ordinary raw pipe commands. First-party PTY and acknowledged
pipe half-close remain the Linux capabilities below; macOS hosts can supply their
own verified PTY adapter. To run the portable lifecycle tests after building:

```sh
mix test test/backplane/agent_runtime/tools/local_command_portable_test.exs
```

## Optional Linux LocalCommand PTY helper

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

## Pipe input half-close

`LocalCommand.start_link(pipe_stdin: true)` uses this helper for non-PTY commands.
It requires the separate `--probe-pipe` capability (`BACKPLANE_PIPE 1`); a legacy
PTY-only helper is rejected before advertising input-close support. This probe
checks procfs/pidfd support without requiring a controlling terminal. The explicit
build command remains `mix backplane.pty.build` and generated binaries remain
excluded from Hex packages.

`--pipe` takes the same arguments as `--run`, but starts the child with ordinary
stdin/output pipes in its verified session. Packet4 input `E` requests EOF: the
guardian flushes all previously accepted `I` bytes, closes the child's stdin pipe
write end, then returns `E` to acknowledge closure. Output and child lifetime are
independent; final `F` plus successful broker exit still prove resource cleanup.
The child sees literal input bytes, including Ctrl-D. PTY mode does not support
half-close. Default raw Erlang Port pipes retain their existing behavior.
