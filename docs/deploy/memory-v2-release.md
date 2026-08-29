# Memory V2 Release and Rollback Plan

This plan is required for a release that contains Memory V2 migrations. The
canonical `bpm_events` stream is the rollback boundary. Schema rollback alone
is unsafe because migrations 00006 and 00007 are irreversible.

## Release gates

Dispatch the release workflow from `main` only. Qualification resolves the
checked-out main revision to one immutable commit SHA; every build, package,
container, and GitHub release target must use that same gated SHA.

Do not publish until the release workflow has produced both:

- `memory-v2-qualification`: focused migration, outage, privacy, adapter, and
  Recall V2 CI-smoke artifacts whose reports declare `profile=ci` and
  `performance_authoritative=false`; and
- `installed-release-migration-smoke`: a Linux x64 release extracted from its
  tarball and used to migrate a fresh PostgreSQL/pgvector database twice (apply
  and idempotent no-op).

Follow `docs/operations/memory-v2.md` for backup, preflight, consistency, and
host-spool checks.

GitHub-hosted performance smoke gates use 10% of the authoritative hardware
requirements. They do not replace `profile=performance` reports produced on
controlled hardware. Keep those reports as separate release evidence when
available; they are not required for GitHub artifact publication and must not
be inferred from CI-smoke results.

## Installed-release migration command

An OTP release does not include Mix. Point the extracted new release at the
production boot TOML and run migrations without starting its HTTP endpoints:

```sh
export BACKPLANE_CONFIG=/etc/backplane/backplane.toml
export SECRET_KEY_BASE='<production secret>'
/opt/backplane/bin/backplane eval '
path = Application.app_dir(:backplane_system, "priv/repo/migrations")
{:ok, versions, _apps} =
  Ecto.Migrator.with_repo(Backplane.Repo, fn repo ->
    Ecto.Migrator.run(repo, path, :up, all: true)
  end)
IO.puts("applied_migrations=#{length(versions)}")
'
```

Run it a second time and require `applied_migrations=0`. The old release may
continue serving capture during these additive migrations. If the central
service is stopped for the process switch, host agents continue accepting into
their durable local spools.

## Forward cutover

1. Record the pre-upgrade event watermark and restore-tested backup.
2. Run the new installed release's migrations twice as above.
3. Run the consistency and dry-run rebuild checks.
4. Replace the application process/image without changing the database.
5. Verify public health on `4100` and trusted admin health on `4101`.
6. Require connected host spools to drain, no new permanent rejects, bounded
   projection lag, no unexplained activity drift, and FTS recall during an
   optional-provider outage.
7. Record the post-cutover event watermark and qualification artifact digest.

## Rollback that preserves accepted events

A binary rollback is safe only while its schema compatibility has been
explicitly proven. For any rollback crossing an irreversible migration:

1. Stop public ingestion at the reverse proxy. Leave host agents running so
   new events queue locally; do not disable capture hooks.
2. Record the incident time and final event watermark. Export every canonical
   event accepted after the pre-upgrade watermark and the parent streams those
   events reference:

   ```sh
   watermark="$(cat memory-v2-pre-upgrade.watermark)"
   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
     -c "\\copy (select stream.* from bpm_streams stream where exists (select 1 from bpm_events event where event.stream_id = stream.stream_id and event.inserted_at > '$watermark'::timestamptz)) to 'memory-v2-rollback-streams.csv' with (format csv, header true)"
   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
     -c "\\copy (select * from bpm_events where inserted_at > '$watermark'::timestamptz order by inserted_at,id) to 'memory-v2-rollback-events.csv' with (format csv, header true)"
   sha256sum memory-v2-rollback-streams.csv memory-v2-rollback-events.csv
   ```

3. Preserve the failed database and take an additional full dump. Never run a
   destructive downgrade against the only copy.
4. Restore the pre-upgrade dump into a new database. Start the compatible old
   binary against that new database with public ingress still closed.
5. Replay the exported CSV files through staging tables with the same columns
   as `bpm_streams` and `bpm_events`, then insert with conflict protection:

   ```sql
   BEGIN;
   CREATE TEMP TABLE rollback_bpm_streams (LIKE bpm_streams INCLUDING DEFAULTS);
   CREATE TEMP TABLE rollback_bpm_events (LIKE bpm_events INCLUDING DEFAULTS);
   \copy rollback_bpm_streams FROM 'memory-v2-rollback-streams.csv' WITH (FORMAT csv, HEADER true)
   \copy rollback_bpm_events FROM 'memory-v2-rollback-events.csv' WITH (FORMAT csv, HEADER true)
   INSERT INTO bpm_streams AS current_stream
   SELECT * FROM rollback_bpm_streams
   ON CONFLICT (stream_id) DO UPDATE SET
     next_sequence = GREATEST(current_stream.next_sequence, EXCLUDED.next_sequence),
     last_window_sequence = GREATEST(current_stream.last_window_sequence, EXCLUDED.last_window_sequence),
     last_event_at = GREATEST(current_stream.last_event_at, EXCLUDED.last_event_at),
     closed_at = GREATEST(current_stream.closed_at, EXCLUDED.closed_at),
     updated_at = GREATEST(current_stream.updated_at, EXCLUDED.updated_at);
   INSERT INTO bpm_events
   SELECT * FROM rollback_bpm_events
   ON CONFLICT (id) DO NOTHING;
   COMMIT;
   ```

   The stream upsert advances allocation watermarks when the restored backup
   already contains the stream, so reopening capture cannot reuse an exported
   sequence. This requires the target schema to understand every exported
   stream and canonical event column. If it does not, do not drop fields:
   restore into the newest compatible schema or replay the envelopes through
   the normal authenticated ingest contract.
6. Compare exported stream and event IDs/counts with the restored rows, rebuild
   projections, verify exact-partition activity, and retain the evidence.
7. Reopen public ingestion. Hosts upload everything captured while ingress was
   closed; duplicates are harmless through durable event idempotency.

Rollback is complete only when pre-upgrade, during-upgrade, post-upgrade, and
outage-spooled event IDs are all present exactly once and projection/aggregate
checks pass.
