# Session-owned Codex resources

`Backplane.AgentRuntime.Codex.Session` is an opt-in, supervised host resource
owner. Each user turn still runs in a new, finite `Conversation`, with a unique
run ID, its own incarnation, fresh budget and deadline, and its own admitted
catalog and exact authorization. Retained resources do not carry execution
authority into another run.

## Host integration

Supervise the Session independently of its host owner so host death can close
admission and retain bounded cleanup evidence for inspection:

```elixir
{:ok, session} = Session.start_link(owner_pid: host_pid, cleanup_timeout: 3_000)
authority = %{run_id: "turn-A", caller: "host", grants: ["exec_command"]}
{:ok, binding} = Session.bind(session, authority, incarnation: 1)

{:ok, profile} = Codex.profile(:pinned_local,
  %{session_binding: binding, workspace: workspace, command: command,
    caller: %{run_id: authority.run_id}}, authority)

{:ok, conversation} = Conversation.start_link(
  run_id: authority.run_id,
  incarnation: binding.run_incarnation,
  session_binding: profile.session_binding,
  registry: profile.registry,
  tools: profile.tools,
  authority: profile.authority,
  provider: provider,
  store: store,
  context: store_context,
  work: 100,
  run_timeout: 60_000
)
```

After receiving A's acknowledged `run_completed` event, bind a different run ID
for B, build B's profile from B's current authority, and start a new Conversation
with that profile's binding. B can address A's retained numeric command session,
Code Mode `cell_id` and collaboration task names when B's current catalog and
grants authorize the relevant tool. `Session.close(session)` explicitly ends the
resource lifetime. `Session.status(session)` reports admission phase and cleanup
evidence. Binding maps contain internal process capabilities and must remain in
host memory; they are not provider arguments or journal records.

## Completion and failure

Natural completion first checks that resource cleanup is unambiguous, active
Code Mode dispatchers have settled, and retained children do not require recovery.
It prepares detachment, immediately fencing A's dispatch callbacks while blocking
B's admission. Only a successfully acknowledged durable run finish permits the
final detach acknowledgement and new binding. Failure to commit or acknowledge
detachment closes the session; it never silently transfers uncertain work.

Explicit run cancellation, provider/tool failure, storage failure, run death,
session close and host death close admission and reconcile resources. A host
close immediately fences registry admission, then gives the active Conversation
a bounded interval to acknowledge effect-worker fencing. Registry and child-tree
cleanup are attempted within the remaining shared deadline even if that
acknowledgement fails. Every retained child is attempted despite another child's
uncertain settlement; partial runtime attachment also closes admission and
reconciles the runtimes that accepted this session. Failed cleanup or fencing
retains `unknown_outcome`
evidence and rejects new binding. Confirmed resource cleanup does not establish
successful settlement of a failed or interrupted execution intent.

Session resource identity uses a fresh random owner ID and process incarnation;
restart creates a different resource owner and never restores handles or
automatically re-executes journal effects. `Conversation` rejects supplying both
a restored `:run` and `:session_binding`. Previously used run IDs cannot bind
again. Session turn-history retention is bounded by `max_turns` (default 1024,
allowed 1 through 100000); reaching capacity requires explicit session close and
fresh host session creation.

## Authority and collaboration

Every Codex backend dispatch validates the exact current binding, run ID and run
incarnation before accessing the session resource owner. Execution intent,
approval matching, catalog/descriptor revisions, grants, budget reservations
and callback generations remain properties of the current Conversation. A's
late callbacks and grants address A's fenced process and binding, never B's
authority. Code Mode refreshes metadata and nested dispatch callbacks on B's
`wait`; detached pending tool requests remain unexecuted until that authorization
boundary. It cannot retain an active uncertain effect for automatic transfer.

Collaboration preserves child identities and their existing bounded runs. A
later root rebind changes root authorization and caps future child collaboration
spawns by the latest root grants, without changing an in-flight child's admitted
authority. Followups to completed children keep their canonical task names and
carry the child's remaining budget/deadline through the existing replacement
protocol. Closing the Session closes the retained child tree and confirms its
cleanup before reporting success.

Focused regressions exercise real A-to-B command stdin, a Deno cell with a queued
nested call authorized under B, an active child and subsequent child followup,
fresh B budgets/revisions, stale/foreign binding rejection, failed finish
acknowledgement, uncertain cleanup, cancellation and native host-death cleanup.
