# Memory V2 Operations Runbook

This runbook covers the production Memory V2 data plane. Canonical
`bpm_events` rows are the accepted history; projections, summaries, activity,
lessons, and crystals are derived or governed records. Never delete or rewrite
canonical events as a repair shortcut.

Run source-tree commands from the repository root through `devenv shell`. An
installed OTP release has no Mix tasks; use the release-safe migration command
in the release plan instead.

## Security boundary

The public API/MCP/LLM endpoint listens on `4100`. The administration endpoint
is a separate Phoenix endpoint on `4101`, rooted at `/`. Until the platform has
application-level admin authentication, expose `4101` only on loopback, a
private overlay, or a trusted-network reverse proxy. Memory replay, audit,
governance, and raw-event views contain sensitive material and must not be
placed on public ingress.

## Back up and prove restoreability

Set a connection URL without embedding it in shell history, then take a
consistent custom-format backup:

```sh
pg_dump --format=custom --file=backplane-pre-memory-v2.dump "$DATABASE_URL"
pg_restore --list backplane-pre-memory-v2.dump > backplane-pre-memory-v2.list
test -s backplane-pre-memory-v2.list
```

Record the backup checksum, database server version, pgvector version, current
application revision, and highest migration version with the release record:

```sh
sha256sum backplane-pre-memory-v2.dump
psql "$DATABASE_URL" -Atc "show server_version"
psql "$DATABASE_URL" -Atc "select extversion from pg_extension where extname='vector'"
psql "$DATABASE_URL" -Atc "select max(version) from schema_migrations"
```

Restore the dump into a disposable database and run the consistency checks
below before calling the backup usable. A backup that has not been restored is
not rollback evidence.

## Migration preflight and live cutover

1. Confirm PostgreSQL and pgvector satisfy the versions used by CI (PostgreSQL
   17 for release smoke; pgvector must support `halfvec`, at least 0.7).
2. Confirm host capture is enabled and every connected host reports a healthy
   durable spool. A host continues accepting locally while Backplane is
   unavailable.
3. Alert on non-zero dead letters, an increasing oldest-event age, a full
   spool, projection failures, or discarded Oban jobs before changing schema.
4. Take and restore-test the pre-upgrade backup.
5. Export the canonical-event watermark:

   ```sh
   psql "$DATABASE_URL" -Atc \
     "select coalesce(max(inserted_at)::text,'epoch') from bpm_events" \
     > memory-v2-pre-upgrade.watermark
   ```

6. Run the new release's additive migrations while the old release continues
   serving capture. Use `mix ecto.migrate` from a source deployment or the
   installed-release command in `docs/deploy/memory-v2-release.md`.
7. Run consistency checks and a projection dry run. Only then switch the
   application process/image to the new version.
8. Observe host spool depth draining to zero, ingest accepted/duplicate/rejected
   counts, projection lag, queue depth, and dead letters through the trusted
   admin Overview and Activity pages.

Do not run `mix ecto.rollback` across the Memory V2 chain. Migrations 00006 and
00007 are intentionally irreversible; rollback is restore plus event replay.

## Consistency checks

Database checks must return zero rows or zero counts:

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
SELECT count(*) AS duplicate_stream_sequences
FROM (
  SELECT stream_id, sequence
  FROM bpm_events
  GROUP BY stream_id, sequence
  HAVING count(*) > 1
) duplicate;

SELECT count(*) AS orphan_events
FROM bpm_events event
LEFT JOIN bpm_streams stream ON stream.stream_id = event.stream_id
WHERE stream.stream_id IS NULL;

SELECT status, count(*)
FROM bpm_projection_states
GROUP BY status
ORDER BY status;
SQL
```

Run bounded, audited application checks from a source deployment:

```sh
devenv shell -- mix memory.projections.rebuild --dry-run \
  --max-subjects 500 --run-id pre-cutover
devenv shell -- mix memory.projections.rebuild --failed-only \
  --continue-on-error --page-size 100 --max-subjects 500 \
  --run-id failed-projections
devenv shell -- mix memory.activity.verify \
  --client CLIENT_ID --scope SCOPE --namespace NAMESPACE
```

Activity verification is exact-partition scoped. Repeat it for each active
client/scope/namespace partition. A non-zero drift count blocks cutover.

## Rebuild, retry, and heal

- Rebuild one canonical session:

  ```sh
  devenv shell -- mix memory.projections.rebuild \
    --host HOST_ID --session SESSION_ID
  ```

- Resume a bounded failed-only rebuild with a stable run identifier:

  ```sh
  devenv shell -- mix memory.projections.rebuild --failed-only \
    --continue-on-error --page-size 100 --max-subjects 500 \
    --run-id INCIDENT_ID
  ```

  Repeat the exact command while `limit_reached=true`. A stable run identifier
  resumes from durable per-subject checkpoints. Failed subjects are retried;
  successfully rebuilt subjects are not replayed. A dry-run checkpoint never
  suppresses a later real rebuild with the same identifier.

- Repair activity drift only after saving the verifier output:

  ```sh
  devenv shell -- mix memory.activity.verify \
    --client CLIENT_ID --scope SCOPE --namespace NAMESPACE \
    --from YYYY-MM-DD --to YYYY-MM-DD --repair
  ```

- Use `memory::diagnose` for read-only, exact-partition memory, projection,
  embedding, relation, lesson, lease, and circuit-breaker health.
- Use `memory::heal` only with an authenticated `memory.admin` caller after
  reviewing the diagnosis. Omitting `kind` retains the compatibility repair:
  clear expired coordination leases and close the circuit breaker.
- Targeted `memory::heal` repairs require a stable `idempotency_key`. Supported
  kinds are `coordination`, `failed_projections`, `reembed`, `graph`, `profile`,
  `activity`, `summary`, `crystal`, `relation`, `lesson`, and `dead_letter`.
  Supply the target named by the schema (`target_id`, `session_id`, `project`,
  dates, resolution/action/reason). Every success and failure is audited;
  repeating a successful key returns `already_applied` without duplicate work.
- Oban `discarded` jobs and projection `dead_letter` states require operator
  review before repair. Preserve the job arguments/error and canonical event
  identifiers, correct the cause, then use the bounded failed-only rebuild or
  exact-partition `dead_letter` heal. Do not edit a projection state to
  `complete` or mutate an event.

Uniform pipeline telemetry is emitted at `[:backplane, :memory, :pipeline]`
with `count`, `duration_us`, `stage`, `status`, `error_class`, and bounded
partition/session/project dimensions. Content, raw payloads, prompts, tool
input/output, and errors are never included in telemetry metadata.

## Host spool recovery and resynchronization

The capture spool is the host-local durability boundary. Its default path is
`<work_dir>/memory/capture_spool.db`; do not copy, delete, or edit it while the
host agent is running.

1. Stop the host agent cleanly and copy the spool file, adjacent SQLite/Turso
   files, host YAML, and the encryption key secret to protected storage.
2. If encryption is configured, verify the same 32-byte base64 key environment
   variable is available before restart. Starting encrypted data without its
   key is expected to fail closed.
3. Restart the same host identity. The uploader retries pending rows with
   bounded backoff; accepted and duplicate ACKs become acknowledged, retryable
   rejects remain pending, and permanent rejects become dead letters.
4. Inspect trusted admin host metrics: `spool_depth`, `spool_bytes`,
   `oldest_event_age_ms`, `retry_count`, and `dead_letter_count`. A recovered
   spool is healthy only after pending depth drains and the server shows the
   corresponding accepted or duplicate events.
5. Permanent dead letters are evidence, not a retry queue. Record event ID and
   reason, correct the adapter/policy/schema issue, and recapture or replay from
   the original approved source. Never change a dead-letter row to pending in
   the database by hand.

The host agent also has a legacy local memory outbox. Diagnose it from a
source checkout with `Backplane.HostAgent.Memory.Diagnostics.snapshot/1` or
requeue only its failed outbox rows with:

```sh
devenv shell -- mix do --app backplane_host_agent cmd mix agent.memory.resync
```

That command does not requeue capture-spool dead letters. On reconnect, fact
set hashes drive server-to-host reconciliation; compare the diagnostics hash
per scope before and after resync. Tombstone purge is destructive and must be
explicit (`agent.memory.tombstones --purge`) only after retention and server
state have been verified.

## Incident evidence

For every recovery retain: UTC time range, release revision, host/client/scope/
namespace, event IDs and stream sequences, spool counters, projection-state
rows, Oban job IDs/errors, recall trace IDs, audit IDs, commands run, and the
post-repair consistency output. Redact content and credentials from tickets and
logs; identifiers and aggregate counts are normally sufficient.
