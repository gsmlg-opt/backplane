# Memory Hook Activation Sessions Design

## Problem

Claude Code reuses its persistent `session_id` when a saved conversation is resumed. Backplane Memory V2 deliberately gives a Memory session exactly one stream, closes that stream on session end, and rejects all later appends. Reusing the raw Claude ID after it has closed therefore makes resumed hook ingestion fail with `:stream_closed`.

The backend invariants remain unchanged:

- `register_session/2` stays insert-only and idempotent.
- A closed stream never reopens.
- One Memory session maps to one event stream.
- Session end appends `session.ended`, closes the stream, and enqueues the legacy summary once.

## Decision

A hook-created Memory session represents one Claude activation: the interval from one effective `SessionStart` through its matching `SessionEnd`. The persistent Claude conversation ID remains the lookup key used by hook-local state, but a resumed activation receives a fresh derived Memory session ID.

Lifecycle rules:

- `SessionStart source=startup`: map the fresh Claude ID to itself.
- `SessionStart source=resume`: create and persist a fresh fixed-length `claude-run` Memory ID containing a Claude-ID hash prefix and a random UUID.
- `SessionStart source=clear`: identity-map Claude's new post-clear ID.
- `SessionStart source=compact`: reuse the current mapping; compaction does not create a new activation.
- Every observation hook resolves the Claude ID through the current mapping before building its body or idempotency key.
- `SessionEnd` attempts to close the resolved Memory session, then compare-and-deletes only the mapping it used even if the non-blocking HTTP request failed.

This keeps each activation ordered and terminal without weakening stream closure.

## Hook State

The hook package will add one small shared Python helper in `priv/hooks`. Existing shell entrypoints continue to parse hook JSON once and remain the only installed commands.

State is local and per user:

- Prefer `$XDG_RUNTIME_DIR`; otherwise use a UID-qualified directory beneath `$TMPDIR` or `/tmp`.
- Create the directory with mode `0700`.
- Hash the persistent Claude session ID for the filename so untrusted IDs never become paths.
- Store a bounded JSON record with the Claude ID digest and current Memory session ID using mode `0600`.
- Serialize updates with an exclusive lock and publish them with atomic replacement.
- Session end removes a mapping only when its stored Memory ID still equals the ID that was closed, preventing a late end hook from deleting a newer activation.

If state cannot be read or created, hooks remain non-blocking and emit no request. They must not fall back to a raw ID for `resume`, because that ID may already name a closed stream.

## Data Flow

1. `SessionStart` asks the helper to establish or reuse an activation mapping.
2. It posts the resolved ID to `/api/memory/session/start`.
3. Prompt, tool, compact, subagent, stop, and commit hooks resolve the same mapping and post observations under that ID.
4. Tool-derived idempotency keys include the resolved Memory ID, so identical Claude tool IDs cannot collide across activations.
5. `SessionEnd` resolves and posts `/api/memory/session/end`, then conditionally removes the mapping.

The HTTP API, database schema, event taxonomy, and backend session functions do not change.

## Error Handling

- Malformed hook JSON, missing required fields, invalid state, lock failures, and HTTP failures exit successfully without blocking Claude Code.
- Invalid or stale state is not trusted as a Memory ID.
- `compact` without existing state and non-start hooks without state emit no request; a subsequent valid `SessionStart` repairs the lifecycle.
- State files contain no tool input, tool output, prompt content, credentials, or headers.

## Verification

Focused hook tests will prove:

- startup, observations, end, resume, observations, and end use two distinct Memory IDs;
- compact retains the current activation ID;
- clear accepts Claude's new ID without inheriting an old mapping;
- all ten hook entrypoints resolve the activation mapping;
- idempotency keys use the resolved ID;
- two Claude IDs remain isolated;
- stale state is replaced safely and late SessionEnd cleanup cannot delete a newer mapping;
- state directory/file permissions and hashed filenames are enforced;
- malformed state and state I/O failures remain non-blocking;
- the existing quoting, large-stdin, curl timeout, installer merge, and explicit event-mapping contracts stay green.

## Rejected Alternatives

- Reopen a closed stream: violates terminal stream semantics.
- Leave streams open on SessionEnd: loses closure and exactly-once summary behavior.
- Attach multiple streams to one Memory session ID: violates the one-session/one-stream invariant.
- Ignore only `SessionEnd reason=resume`: does not help a normally exited session resumed later.
- Derive identity from PID or time independently in each hook: does not provide a stable cross-hook activation ID.
