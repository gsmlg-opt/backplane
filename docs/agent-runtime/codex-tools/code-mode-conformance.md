# Code Mode source contract conformance

The selected source is `openai/codex` revision
`46fdd5ef39735f4159cdcf0ec5e85c10521494e5`. Backplane retains its
permission-denied Deno process adapter. This change does not migrate to Denox.
The focused evidence below was obtained with Deno 2.8.3 on Linux.

## Independent reference fixtures

`apps/backplane_agent_runtime/test/fixtures/code_mode_source/contract.json`
records the source revision, source paths, SHA-256 hashes, reference defaults,
JavaScript programs, and independent expected observations. Expectations come
from the pinned helper description, pragma parser, runtime defaults, and exec
freeform grammar. They do not come from Backplane's helper implementation.
The fixture provenance explains this distinction.

The referenced native source establishes:

- Execution as an async module, including top-level await and module exports.
- Exec/wait time-slice defaults of 10,000 milliseconds, and an exec output
  default of 10,000 tokens.
- First-line pragma parsing with leading whitespace, CRLF, nullable optional
  fields, and nonnegative integer values. Unsupported fields, malformed JSON,
  negative/fractional values, and empty source are invalid.
- Normalized `tools.*` methods, raw custom input, and `ALL_TOOLS` discovery.
- Text and data-URL/MCP image/audio output, generated images and output hints.
- State store/load, immediate notification, successful early exit, running
  control yields, and discarding pending timers at complete evaluation.

The source-contract fixtures run against Backplane's actual packaged Deno
worker. They are **source-derived golden comparisons, not native differential
captures**: the native Codex engine was not executed to produce or verify the
reference outputs.

## Runtime checks

`codex_source_conformance_test.exs` contains 20 passing focused tests. In
addition to the reference programs, they verify:

- Continued execution after a time slice, incremental output, a control flush
  while detached, wait rejection for unknown or completed cells, and terminal
  handle removal after success or output-bound failure. Terminal failures cannot
  be overwritten by later queued completion frames.
- An admitted Conversation notification arrives before tool completion.
- A later wait dispatches a nested tool through the newly committed catalog,
  exact revised authority and backend. The fixture publishes the revision
  through an admitted catalog tool; it does not mutate Conversation state.
- Non-nil deadline and slice generations captured while armed cannot terminate
  a resumed cell.
- Explicit control and generator yields wait for admitted callbacks to settle.
- Wait refreshes shared stored data after another cell writes it, preserving the
  resumed cell's prior writes.
- Stored data is isolated by owner and incarnation. Released handles, mismatched
  incarnations and closed owners cannot write late state.
- Unawaited in-flight callbacks and crashed dispatchers retain `unknown_outcome`;
  callback processes shut down. Ordinary JavaScript exceptions remain distinct.
- Detached notifications obey the hard retained-output bound. File reads,
  ambient Deno access and network fetches do not succeed.

Focused validation command, run from `apps/backplane_agent_runtime` with the
configured Deno executable on `PATH`:

```sh
mix test test/backplane/agent_runtime/codex_source_conformance_test.exs
```

The broader package includes existing CPU-loop interruption, process identity
cleanup, owner cancellation, framing, resource, and Conversation tests. Results
of those suites must be reported separately; this focused result does not imply
that all package or umbrella checks passed.

## Host adaptations and remaining acceptance boundary

Authority, tool admission and commit, credentials, cancellation, persistent
conversation state, and media publication remain host-owned. Deferred cells
cannot dispatch using an old Conversation effect closure: dispatch waits for a
current wait effect. This also means a time slice is deferred while an admitted
nested callback is active.

Deno permissions deny filesystem, network, environment and subprocess access.
The adapter has a 64 MiB V8 old-space limit plus independent source, record,
retained-output, stored-state, callback-count and execution-time bounds. A V8
old-space limit is not an operating-system RSS quota. Per-call output budgets
use an explicitly approximate four-bytes-per-token estimate and preserve whole
media records; they do not reproduce the native tokenizer. Host pragma bounds
of 300,000 milliseconds and 262,144 output tokens are stricter than the source's
JavaScript-safe-integer limits. Legacy generator yields and return values remain
Backplane extensions.

These checks establish the tested Deno adapter behavior and source-contract
subset. They do not prove complete native Codex output envelopes, tokenization,
engine scheduling, or native-reference differential parity. Issue #54 explicitly
asks for differential fixtures against the selected source. If that requirement
means execution against the native reference engine or captured native traces,
it remains unvalidated and #54 should remain open. Source-contract golden tests
must not be presented as that missing evidence.
