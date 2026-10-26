# Session-owned Codex resources

## Explicit closure reconciliation

Recovery-enabled Sessions expose `initial_cleanup`, `cleanup_revision` and
`reconciliation` alongside their latest `cleanup`. The first close result remains
available even after independent evidence confirms closure. Ordinary `close/2`
returns the cached latest result; it never retries a failed cleanup itself.

After fencing admission and establishing exact run/component evidence, obtain
the owner manifests, persist receipts with `Codex.Reconciliation.reconcile/2`,
then apply `ResourceRegistry.reconcile_owner/3`,
`MultiAgent.reconcile_child/2` / `reconcile_close/2`, and finally
`Session.reconcile_close/2` in ownership order. Registry projection requires the
exact fenced owner and preserves failed acknowledgement obligations separately
from physical shutdown. Applying receipts calls neither cleanup nor
acknowledgement again. The Session requires confirmed Registry and every owned
manager; managed child Sessions borrow the shared manager rather than owning its
entire lifetime.

The Session stays `phase: :closed`; its old binding remains unusable. Exact
receipt reapplication is a no-op. Missing evidence, a live unfenced executor,
unresolved mutation effects or a timeout retains uncertainty and reservations.
Reconciliation starts no new work and sends no Goal idle signal. A root run
already terminal `unknown_outcome` retains its original outcome/journal and effect
evidence; lifetime closure is a separate receipt. Host policy decides any future
independent admission. See
[the persistence contract](../../../apps/backplane_agent_runtime/PERSISTENCE.md)
and [embedding guide](../../../apps/backplane_agent_runtime/EMBEDDING.md).

## Optional Linux PTY resources

The ordinary `exec_command`/`write_stdin` tools support the first-party Linux PTY
after an explicit `mix backplane.pty.build` and backend `pty: true`. Only a
`tty: true` request selects it. Existing numeric Sessions, owner/incarnation
checks, output cursors and budgets apply. Cancellation/Session close must confirm
the original terminal session's remaining ordinary job-control groups, guardian
proof, broker reaping and Port exit. Missing helper proof remains uncertain; it
does not authorize numeric-PID cleanup retries or command replay. Terminal jobs
are process-local and cannot be imported from an archived child.

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

## Managed child Sessions

A root Session owns its collaboration manager. Each stable managed child may
also own a separate Session for commands, plans and Code Mode cells. These child
Sessions share the root manager; attaching a child does not rebind the manager's
root owner. Host owner PIDs may differ between root and child Sessions.

The existing `child_options/3` callback returns the child's fresh Session binding
alongside its normally admitted catalog. The host retains the Session by the
stable `parent.child.agent_id`, while each callback receives a new run ID,
`parent.child.attempt_id` and increasing `parent.child.incarnation`:

```elixir
child_options = fn request, run_id, parent ->
  # These functions are host-owned; they do not call the manager synchronously.
  session = child_sessions.fetch!(parent.child.agent_id)
  authority = child_authority.(run_id, parent.authority)
  {:ok, binding} = Session.bind(session, authority,
    incarnation: parent.child.incarnation)
  {:ok, profile} = catalog_for_child.(binding, authority)

  {:ok,
   [run_id: run_id,
    incarnation: parent.child.incarnation,
    session_binding: binding,
    registry: profile.registry,
    tools: profile.tools,
    authority: profile.authority] ++ conversation_options.(request, run_id)}
end
```

`child_sessions`, `child_authority`, `catalog_for_child` and
`conversation_options` represent the host's existing allocation, policy, catalog
and provider/Store integration. Fetch native collaboration contracts with
`MultiAgent.contracts/3` before invoking the manager's tools and keep them in
host-owned state for catalog construction. `child_options/3` runs inside the
manager: it must not call the manager, including through a profile that discovers
collaboration contracts synchronously. Preserve the original contract schemas,
backend `family` metadata and collaboration bindings. Attach the fresh Session
binding to descriptor backend contexts, as `Codex.profile/4` does for its returned
registry; building a profile does not itself grant authority.

After validating those options, MultiAgent records the exact prospective
association and calls `Session.adopt_managed_child/3` before starting the child
Conversation. Hosts do not need an additional adoption call. Adoption requires
the actual manager caller, the exact reserved binding and run/incarnation, a
stable manager/agent association, and authority within the Session reservation.
Catalog admission can narrow this authority. A root Session cannot be reused as
a child, and one child Session cannot be reassigned to another manager or child.
Each invocation still checks the child's current binding, caller, grants,
revisions and ancestor authority.

Successful completion prepares local resources, acknowledges the Store finish,
and detaches before releasing execution capacity. The idle child retains its
resources and remains a manager cleanup obligation even if its Conversation is
unloaded. Follow-up uses that same Session with a fresh run/token and higher
incarnation. A second Session is refused while the old resource owner remains
open; a new Session becomes eligible only after confirmed closure. Closed
Session infrastructure cannot bind again.

Child cancellation, local Session close and V2 target-only interruption close
only that child's resources. Root, siblings and independently running descendants
remain available. V1 recursive close and root Session close attempt every targeted
child Session, including idle completed children, even after an earlier uncertain
result. A successful retained Conversation snapshot is not a Session-close
receipt. Off-manager workers require independent close evidence and keep
observation responsive while waiting. Session infrastructure loss is monitored
across follow-ups; manager loss makes each adopted Session close locally.

Unknown adoption, startup, prompt, receipt, finish or cleanup acknowledgements
retain the exact obligation and execution reservation. They do not authorize
retry, replacement or effect replay. Run notifications carry private full
admission/binding correlation; stale notifications cannot settle a newer run.
These capabilities remain process-local and are excluded from public manager
records and checkpoints.

Once adoption was accepted or may have been accepted, the manager attempts local
cleanup after startup or admission failure. Explicitly rejected foreign/root
bindings are not closed by that manager. Allocations rejected before adoption,
and allocations made by a callback that raises before returning its options,
remain the host's responsibility. Closing resources leaves the host-supervised
Session infrastructure alive for inspection; normal infrastructure shutdown still
tears down its own Registry and supervisors.
