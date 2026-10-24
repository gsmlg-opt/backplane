# Deferred candidate ownership and metadata search

## Owner isolation (#88)

DynamicRuntime keeps independent Dynamic instances keyed by the exact caller,
run ID and incarnation. An absent caller uses a private host-direct identity;
present callers must be nonempty strings. Run IDs must be nonempty strings and
incarnations positive integers. The private identity grants no authority.

Candidate bounds apply per owner. Partitions remain until Runtime shutdown;
there is no implicit refresh, expiry or eviction. Plugin receipts retain their
separate existing Dynamic state. Low-level Dynamic name collisions, snapshots,
and publication rules remain unchanged within each partition.

Publication still requires strict catalog admission and the current producer-bound
Conversation callback. A rejected stage leaves the owner's old partition intact.
An accepted stage consumes candidates; subsequent Conversation cancellation can
discard its pending catalog without restoring those candidates. Hosts must not
infer retry/reset semantics from cancellation. Results become executable only at
the next provider turn and cannot authorize another call in the same batch.

Validation uses the public DynamicRuntime API with an unmatched query and no
staging context, followed by successive real Conversations sharing one Runtime.
The second run failed before the fix with `dynamic tool namespace collision`.
Additional tests cover callers, run IDs, incarnations, host-direct use, invalid
identities, duplicate candidates, catalog collisions and failed-stage rollback.
Scoped CT07 and Conversation catalog tests cover publication, stale producers,
strict/current catalog checks and cancellation. Commands and results are recorded
in the delivery report; temporary red/green logs are development evidence only.
