# Skill Protocol v1 Migration And Rollback

Status: operational sequence for BP-06. Run database commands only against the intended environment with the normal release controls and backups.

## Upgrade Sequence

Use an expand, adopt, publish, verify sequence.

### 1. Expand

Deploy and run migration `20260911000001_create_skill_revisions`. It adds the `skill_protocol` OAuth resource, publication fields on `skills`, immutable `skill_revisions`, a deferred current-revision foreign key, and indexes. Existing Skill rows remain present and initially have `publication_status = 'pending'` with no fabricated revision.

Keep the v1 HTTP surface disabled during a separately controlled rollout with:

```elixir
config :backplane_skills, :skill_protocol_v1_enabled, false
```

The switch is application configuration. When false, the v1 router returns not found; it does not remove revisions or blobs. The default is enabled, so deployments requiring an explicit rollout must set false before starting the upgraded release.

### 2. Adopt Writers

Deploy the code that publishes through `Backplane.Skills.Publication` before exposing the read API. Archive ingestion and generated-skill writers publish an immutable revision and update `skills.current_revision` coherently. A failed or invalid replacement records publication status/diagnostics and must leave the prior current revision intact.

Do not restore an older writer or cleanup implementation once new revisions are being published. Blob deletion must continue to consult both mutable Skill rows and retained `skill_revisions` through `Publication.referenced_blob?/1`.

### 3. Backfill And Publish

Run a dry-run first and retain the complete report:

```elixir
Backplane.Skills.Publication.backfill(dry_run: true)
```

Review every report group: `publishable`, `unchanged`, `missing`, `invalid`, and `unsupported`. Resolve missing blobs and invalid bundles where history permits. A missing historical archive cannot be reconstructed from mutable metadata without changing its bytes and identity; leave it reported rather than inventing a revision.

Apply only after approving the dry-run report:

```elixir
Backplane.Skills.Publication.backfill()
```

Backfill is idempotent. Re-running it reports already committed items as `unchanged`; it does not create a second revision for the same artifact. Preserve the apply report for audit and comparison with the dry run.

Publication order is: write/verify the content-addressed blob, commit the immutable revision, then move the mutable current pointer in the same database transaction. Do not garbage-collect an artifact after publication while any mutable row or historical revision references its blob.

### 4. Enable And Verify

Enable `:skill_protocol_v1_enabled`, restart or deploy through the normal configuration path, and verify:

1. Catalog returns only enabled, ready current descriptors visible to the caller.
2. Resolve without a revision returns the expected current exact manifest.
3. Resolve and artifact fetch for an older retained revision return its original metadata and bytes.
4. Disabled, deleted, withdrawn, or denied Skills return unavailable/not-found semantics and never bytes.
5. A package client verifies the artifact digest and prepares its resources through real HTTP.

## Withdrawal

Withdrawal or live disablement makes the affected revision unavailable. Exact requests return `revision_unavailable` (HTTP 410 where disclosure policy permits) or concealed not-found/authorization errors. The server never falls back to latest, and clients must persist known denial/withdrawal state for offline decisions.

Retain immutable rows and blobs unless an explicit retention policy proves that no supported consumer can reference them. Withdrawal is an availability decision, not permission to rewrite a revision or silently substitute another artifact.

## Rollback

The migration refuses to roll down while `skill_revisions` contains any retained publication. This is intentional and non-destructive. Do not bypass the guard or manually drop the table, trigger, foreign key, or blobs.

Before reverting application code to a version with old replacement cleanup behavior:

1. Disable the v1 feature switch.
2. Freeze all archive, generated-skill, and backfill publication writers.
3. Confirm no publication jobs or operator commands are active.
4. Preserve the database and content-addressed blob store.
5. Prefer a forward fix that keeps the expanded schema and retention-aware cleanup.

A schema rollback is permitted only when `skill_revisions` is empty. If retained rows exist, rollback requires an explicit data-retention/export decision outside this migration; it is not an ordinary deploy rollback. The tested empty-schema path rolls down and reapplies cleanly.

## Known History Limits

Legacy rows with a valid retained archive can be backfilled. Rows without an archive, with a missing blob, or with invalid content are reported as `unsupported`, `missing`, or `invalid`. Those records remain usable only through compatibility behavior supported by the old surface; they are not advertised as valid v1 publications. No migration step fabricates metadata, bytes, digests, or revision history.
