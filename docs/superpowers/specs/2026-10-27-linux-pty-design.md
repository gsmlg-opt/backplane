# First-party Linux PTY command transport

Date: 2026-10-27

Status: proposed for user approval; implementation has not started.

Issue: [#115](https://github.com/gsmlg-opt/backplane/issues/115), targeting the
next release after 1.10.42. Runtime baseline is
`2b7a3318a5fbb31b5a49824b01a3343dac043d0b`, with the separately verified #118
procfs correction in local commit `bded83d2`. Unrelated Memory changes are excluded.

## Outcome and approach

Add an opt-in PTY transport inside `Tools.LocalCommand`, preserving the original
`exec_command` / `write_stdin` schema, native Session ownership, reservations,
refusal/cleanup receipts, incremental cursors and response budgets. A packaged
libc C Port helper supplies an actual controlling terminal and cleanup across
ordinary job-control process groups in that terminal session.

| Approach | Tradeoff |
| --- | --- |
| Private LocalCommand transport and C Port helper, recommended | Reuses the existing command lifecycle and OTP Port boundary; requires an explicit native build and verified Linux capabilities. |
| Separate first-party Command adapter | Repeats reservation, output retention and confirmed-release machinery and increases compatibility work. |
| Shell/Python wrapper or NIF | A wrapper does not establish the required terminal/cleanup lifecycle; a NIF exposes the VM to native failures unnecessarily. |

A C11 compiler and Linux headers are build prerequisites. No new Hex dependency,
NIF, runtime Python, shell-wrapper substitute or downstream source patch is added.

## Public construction and platform contract

Build the optional helper from the official package source:

```sh
mix backplane.pty.build
```

Start the existing backend with trusted options:

```elixir
{:ok, server} = LocalCommand.start_link(pty: true)
{:ok, command} = Command.new(%{adapter: LocalCommand, server: server})
```

`pty` defaults to false. PTY options belong to the backend server; no ignored
keys are added to `Command.new/1`. Add backend `terminal_rows` and
`terminal_columns` options, defaulting to 24 and 80 and bounded by the existing
Command terminal range 1..1000. A trusted absolute `pty_helper_path` may select
the same versioned first-party helper protocol; the default resolves its packaged
`priv` path. No model-visible path selection is introduced.
Even on a PTY-enabled server, select this transport only for an invocation with
`tty: true`; omitted/false tty keeps the existing pipe execution and formatting.

`LocalCommand.capabilities/1` advertises verified Linux PTY support and finite
dimensions only after checking the native helper version, PTY allocation and
required process-observation syscalls. The supported kernel is Linux 5.3 or
later, with working `pidfd_open` and `pidfd_send_signal`; version text alone is
insufficient. Initially verify native Linux amd64 and arm64 builds. Other
platforms retain their existing command-adapter behavior and an unsupported
first-party PTY result. LocalCommand's existing Linux platform restriction stays.

Enabling PTY when prerequisites are missing returns a structured startup error.
A tty request never silently falls back to pipes. Pipe-only construction does
not require the helper or a C compiler. Existing custom Command adapters remain
supported and unchanged. No resizing API or new native tool schema is added.

## Transport and launch ordering

Keep LocalCommand as the lifecycle owner; factor private transport operations
for launch, input, frame decoding and cleanup. The current pipe branch retains
its launcher, framing and callback contracts. PTY cleanup does not change the
integer process-group arguments passed to existing pipe cleanup callbacks.

The helper has a Port-facing broker and a separate guardian outside the terminal
session. The guardian owns the PTY master and terminal session leader. The target
child uses `setsid`, opens the slave as its controlling terminal, sets dimensions,
connects stdin/stdout/stderr to it and directly executes the selected executable
and argv. Normal terminal echo, signals and line discipline apply.

Use a versioned packet4 binary protocol with separate bounded control, output,
diagnostic and terminal-status frames. Arbitrary terminal bytes cannot impersonate
control records. The maximum frame size is 65,536 bytes; larger output is split
and input is chunked without reordering. Keep the existing hard output-byte cap.
Broker/guardian queues must be bounded and nonblocking, with cancellation and
cleanup evidence taking priority. Full terminal/Port output cannot prevent the
guardian noticing cancellation, lifeline EOF or its cleanup deadline. Exhausted
buffering triggers the existing output-limit cleanup behavior; do not accumulate
an unbounded stream or block cleanup while trying to flush it.

Launch ordering is reservation/intent acknowledgement, helper readiness with exact
launch identity, BEAM identity validation and explicit ACK, then target exec.
The native helper does not execute a target before that ACK. Startup refusal,
exec failure and ambiguous dispatch retain the existing native distinctions.
Report terminal-child exit separately from helper exit and cleanup completion.

For PTY output, retain raw bytes internally and project concatenated text as a
binary, without inserted newlines. `Codex.Tools.output_text/1` already supports
binary output. Preserve prompts without LF, CR/LF and terminal escape sequences.
Hold incomplete UTF-8 suffix bytes across frames/polls before advancing a visible
cursor; held bytes count against the hard cap. Invalid complete UTF-8 and a final
incomplete suffix use deterministic replacement text in that read projection;
do not let JSON failure discard a consumed chunk. This text API does not promise
lossless invalid-byte transport. No change to pipe line joining or the native
response-budget calculation is needed. Apply that budget once through the
existing tool path.

`write_stdin` sends ordinary bytes and control bytes to the same master. It does
not translate Ctrl-C into a whole-session cancel: terminal line discipline
delivers the normal foreground signal. Explicit command cancellation and Session
closure use the separate helper control protocol.

## Terminal-session cleanup and proof

The declared cleanup scope includes every ordinary foreground/background
job-control process group remaining in the terminal session. A process that
deliberately creates a different session is outside this contract. This is not
a cgroup or OS confinement feature.

The guardian keeps the terminal session leader unreaped until final reconciliation,
pinning the session identity. Leader exit alone never proves that descendants are
gone. On normal command exit, explicit cancel, Session close or broker lifeline
EOF, the guardian closes execution admission and performs bounded cleanup:

1. Inspect session membership through fresh procfs scans, preserving the #118
   ENOENT/ESRCH vanished-entry semantics and all other observation errors.
2. Acquire pidfds and verify exact session membership before signalling each
   remaining process. Validate identity on both sides of acquisition. Do not
   signal an unchecked numeric PID or an unrelated reused identity.
3. Send TERM and resume job-control-stopped jobs with CONT so they can process
   it. Reuse the existing bounded TERM grace, then establish a quiescent census
   using pidfd STOP on newly observed members, confirmed stopped threads and fresh
   scans. KILL collected live members and observe their exits. Continue discovery
   within the same cleanup deadline. Failure to establish completeness/quiescence,
   an uninterruptible task or observation error is uncertainty; no timeout increase
   or success assumption is added.
4. Confirm all captured processes exited and a complete final census finds no
   executing session member except the pinned exited leader. Reap helper-owned
   children and that leader, then close the PTY master. An externally parented
   zombie is exited, although its procfs entry may await its own reaper; do not
   claim every procfs entry vanished. Return exact launch-token/session evidence.
5. The broker reaps the guardian and emits final proof only after successful
   guardian completion, then exits. LocalCommand needs both final proof and the
   broker Port exit before producing its existing confirmed-release receipt.

Cleanup completion is a lifetime fact, separate from the terminal command's exit
status. A completed child can still have pending cleanup; a dead helper does not
prove a stopped session. PID/Port identifiers are never accepted as substitutes
for the original launch token and native owner/incarnation identity.
This is bounded observed convergence under ordinary job control, not an atomic
kernel membership snapshot against hostile forking, externally resumed processes
or namespace changes. Failure to establish that boundary remains uncertain.

The broker and guardian communicate through a private CLOEXEC lifeline socket.
Broker death/EOF makes the surviving guardian attempt bounded session cleanup.
If the broker dies before returning complete proof, LocalCommand retains
`unknown_outcome`, even if cleanup later succeeds. If the guardian dies, the broker
reports uncertainty; killing the terminal leader alone does not cover job-control
groups. No sidecar/observer subsystem is introduced to manufacture confirmation
after these abnormal failures. Normal cancel and Session close keep the broker
alive until proof or the deadline; forced Port closure without proof is uncertain.

Retain existing asynchronous cleanup workers, token fencing, completed-output TTL,
owner death handling, workspace identity checks and receipt acknowledgement.
Native temporary files/processes belong to that launch and are cleaned only by
their owning lifecycle. No managed development process is restarted for tests.

## Build and packaging

Ship C sources, build script, versioned protocol documentation and the Mix build
task in the official runtime Hex package. Build atomically for the current target
into `priv`; generated binaries are ignored in Git and excluded from portable Hex
source packaging. Do not reuse a cached wrong-target binary. The build command
fails explicitly on unsupported targets or unavailable compiler/syscalls.

Official Linux OTP archives and Docker images invoke the task during their
existing native build before release assembly. Mac builds skip Linux helper
assembly and retain explicit unsupported PTY behavior. The package verifier builds
from unpacked official source and uses public construction only. No installation
downloads, prebuilt binary distribution or automatic compiler requirement for
pipe-only Hex consumers is introduced.

## Implementation scope after approval

- `apps/backplane_agent_runtime/lib/backplane/agent_runtime/tools/local_command.ex`;
  private `local_command/pty.ex` and additive terminal-session support in
  `local_command/procfs.ex`, preserving the already committed #118 fix.
- New runtime `c_src/local_command_pty.c`, `c_src/build_pty.sh`, `c_src/README.md`,
  Mix task `lib/mix/tasks/backplane.pty.build.ex`; runtime `mix.exs` packaging and
  the generated-helper entry in `.gitignore`.
- Runtime PTY/native lifecycle tests, `EMBEDDING.md`, `CODEX.md` and `README.md`.
- `scripts/verify_agent_runtime_package.sh` and focused package-consumer fixtures;
  `.github/workflows/agent-runtime.yml`, `.github/workflows/release.yml` and
  `Dockerfile` only for native helper build/verification integration. Synchronize
  existing workflow contract tests when changing those commands.

No Command schema, Kernel, Conversation, provider, Memory, database, dependency
lockfile or downstream application change is included. Session/Registry behavior
changes belong only to the separate #117/#119 design. Serialize overlapping
LocalCommand/procfs edits and all shared Mix/Devenv build state.

## Required acceptance

1. Through the selected original native tools, observe isatty on fd0/1/2,
   controlling-session identity, default/custom dimensions, prompt output without
   LF, ordinary input, incremental polls and foreground Ctrl-C behavior.
2. Preserve exact CR/LF/escapes, split UTF-8 and deterministic invalid-byte text,
   cursor advancement once, hard retention cap and response budget independently.
3. Run an actual interactive shell with foreground and surviving background jobs
   in additional process groups. Explicit cancel and public Session.close must
   confirm all declared OS processes stopped, including after leader exit.
4. Cover normal child/helper exits, backend/owner shutdown, startup/exec failure,
   lost broker/guardian proof and bounded uncertainty. Use exact cleanup evidence
   in failures; do not weaken assertions, enlarge deadlines or infer closure from
   absent callbacks. Tests clean only their own resources.
5. Preserve intent-before-dispatch, native owner/admission/binding identity,
   reservations, refusals, release receipts, stored tool history and pipe tests.
   A target marker must prove no target effect before READY/ACK; cancellation or
   lifeline EOF before ACK must retain positive non-dispatch proof. Exercise tty
   and non-tty invocations on one enabled backend. Saturate output while cancelling
   and while closing the lifeline; cleanup must still progress within its bound.
6. Build with strict C warnings, run focused runtime suites, native Linux amd64
   and arm64 package consumers, and extracted package/release checks. Verify the
   helper is present and executable in official Linux release artifacts.

Source-tree tests, native platform results, installed official-package acceptance
and downstream Synapsis adoption are separate evidence. No real Provider call,
cross-platform terminal support or production deployment is claimed.

Approval selects explicit opt-in construction/build, the verified Linux/pidfd
requirement, broker/guardian proof boundary and ordinary terminal-session scope.
Then implement, verify and complete the already requested unified release.
