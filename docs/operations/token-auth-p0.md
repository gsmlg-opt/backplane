# Existing-token authentication hotfix (P0)

Implemented September 30, 2026 against `301ffd41bfadfc806af7d71dc773359ce57c0d02`.
P1 issuance, indexed credentials, migrations, and credential rotation are **not**
part of this patch. Bcrypt cost is unchanged. No changes are authored in
`backplane_ai_protocol`, `backplane_agent_runtime`, or LLM forwarding code.

## Implementation

- `apps/backplane_auth/lib/backplane/auth/tokens.ex`: bounded compact-JWT
  structural preflight before signing-key SQL/JOSE. This only selects a path;
  existing signature, algorithm, issuer, audience, time, token/principal state,
  and OAuth scope checks remain authoritative. Dotted opaque credentials retain
  fallback behavior.
- `apps/backplane_auth/lib/backplane/auth/resource_auth_plug.ex`: bounded headers;
  database clients still precede unrestricted configured credentials. Cache
  overload/unavailability returns 503 with `Retry-After: 1`, never unrestricted
  fallback. Existing ordinary errors and Google envelopes remain intact.
- `apps/backplane_system/lib/backplane/clients/auth_cache.ex`: protected ETS
  authorization snapshots, direct full-SHA256 positive lookup, current-client
  lookup, independent freshness lease, separate bounded negative cache, and one
  single-flight bcrypt task per admitted digest. No plaintext is persisted or
  stored as verification evidence. Current scopes/metadata are not cached as
  permission grants. FIFO positive eviction is separate from negative traffic.
- `apps/backplane_system/lib/backplane/clients/activity.ex`: bounded per-client
  activity marks without a request task/message; one supervised batch writer,
  CAS acknowledgements preserving newer observations, capped retry backoff, and
  SQL `GREATEST` preventing timestamp regression across nodes.
- `clients.ex`, `clients/auth_supervisor.ex`, and system application supervision:
  mutation barriers before database writes, targeted committed-state propagation,
  PubSub invalidation, and one-for-all restart of cache, activity, and workers.
  Uninitialized/expired state is rejecting, not evidence of an empty database.

Warm authentication does not enumerate clients or query SQL. Only cold legacy
scans enumerate candidates. Periodic refresh, bounded cache eviction, and activity
maintenance run outside the request's warm lookup. Existing sandbox isolation is
retained; production-path tests and the benchmark do not rely on that branch.

## Bounds and freshness

Configure boot-time application environment under
`config :backplane_system, :client_auth, ...`; restart after changing it.

| Setting | Default |
| --- | ---: |
| `max_token_bytes` | 16,384 (Bearer header: this plus 7 bytes) |
| `positive_capacity` | 4,096 |
| `negative_capacity` | 1,024 |
| `negative_ttl_ms` | 5,000 |
| `max_workers` | 1 |
| `max_waiters` | 64, including queued admission tickets |
| `verification_timeout_ms` | 10,000 |
| `refresh_interval_ms` | 15,000 |
| `snapshot_max_age_ms` | 30,000 |
| `activity_capacity` | 4,096 client IDs |
| `activity_batch_size` | 100 |
| `activity_interval_ms` | 30,000 minimum per client/node |

The task supervisor permits `max_workers + 2` tasks: bcrypt workers, one refresh,
and one activity writer. A verification deadline stops waiting callers and
further candidate checks, but an executing bcrypt task retains its permit until
it actually exits; timeout cannot free a slot while native work still executes.
Activity retries back off up to 30 seconds. Full activity capacity drops additional
approximate marks rather than growing a queue or disrupting authentication.

Local mutations invalidate before the write and fence older snapshots/results.
Connected instances receive PubSub invalidation and reject until authoritative
reload. Dropped events, disconnected nodes, and external database edits rely on
the **30-second maximum snapshot lease**, not globally instantaneous revocation.
The lease starts **before** the database load, so slow loads cannot extend stale
authority. Failed loads never renew it. Requests already authorized before the
invalidation point are not retroactively cancelled.

## Verification actually run

The following scoped command passes **166 tests, zero failures** (system 46,
auth 52, llama 53, admin 1, API 14):

```sh
devenv shell --no-tui -- mix test \
  apps/backplane_system/test/backplane/clients_test.exs \
  apps/backplane_system/test/backplane/clients/auth_cache_test.exs \
  apps/backplane_system/test/backplane/clients/activity_test.exs \
  apps/backplane_auth/test/backplane/auth/tokens_test.exs \
  apps/backplane_auth/test/backplane/auth/resource_auth_plug_test.exs \
  apps/backplane_auth/test/backplane/auth/resource_auth_production_test.exs \
  apps/backplane_api/test/backplane/api/auth/resource_auth_compatibility_test.exs \
  apps/backplane_admin/test/backplane/admin/live/clients_live_test.exs \
  apps/backplane_llama/test/backplane/llm/resource_authorization_test.exs \
  apps/backplane_llama/test/backplane/llm/protocol_route_test.exs \
  apps/backplane_llama/test/backplane/llm/proxy_plug_test.exs \
  apps/backplane_llama/test/backplane/llm/router_test.exs
```

Coverage includes unchanged evidence beyond 60 seconds, expired/failed/slow
refresh, mutation publication fences, current scopes, rotation/disable/deletion,
negative-cache creation/TTL/capacity, late results, remote invalidation, worker
failure/dead callers, admission overload, 1,000 coalesced successes, raced flushes,
retry, monotonic SQL timestamps, both auth headers, JWT key-query preflight,
OAuth resource binding, default/Google errors, and owner/task-group restart.
The actual public production cache wrapper is exercised serially in
`ResourceAuthProductionTest`; its global environment override never runs in an
async test. Isolated cache tests inject only clock/loader/verifier dependencies.

Warnings-as-errors compilation passes. Explicit positional-file scoped strict
Credo checks 14 changed source/test/script files and reports no issues. Scoped
format checking and `git diff --check` pass. A first Credo invocation using this
dependency's ineffective flag-based filters instead checked 1,752 files and
reported 12 unrelated existing issues (LLM/admin/Relayixir/excluded apps); those
are not repaired here. The admin test also retains an existing missing-form-ID
warning. The worker-failure test intentionally logs a terminating test task.

Two old API compatibility assertions implied unrestricted PAT LLM access despite
the baseline's `ResourceAuthorization` already enforcing `:client_token` scopes.
Fixtures now grant explicit `llm::models`/`llm::invoke` for permitted operations;
the restored restricted PAT case asserts the existing 403 envelope instead of
loosening authorization.

Not run locally: the full umbrella test suite, full clean-tree strict Credo,
Dialyzer, a real multi-node partition, live upstream OAuth/LLM calls, or a sustained
production traffic/load experiment. Release workflow checks are separate from
these local results and must be reported from their actual run.

## Reproducible production-like measurements

```sh
devenv shell --no-tui -- env MIX_ENV=dev mix run --no-start \
  scripts/benchmark_client_auth.exs
```

The script refuses sandbox authentication and uses a real connection pool in an
already-migrated dedicated `_test` database (default `backplane_test`). It refuses
a nonempty clients table and creates/deletes only its own ephemeral fixtures;
never run it against production. Both before/after paths execute the actual
resource-auth plug. The baseline is compiled from the pinned Git revision under
renamed modules with separate ETS tables. Set `BACKPLANE_AUTH_BENCH_BASELINE` to
that retained revision when reproducing. Bcrypt **cost 12** is measured from the
generated hash, not reduced. Trace counters count both `verify_pass/2` and
`no_user_verify/0`, plus per-request tasks; telemetry counts scans/enumeration,
SQL/signing/client queries, and activity writes without token-labelled metrics.

The checked-in `token-auth-p0-measurements.jsonl` contains the actual complete run.
Durations below are microseconds, measured at the authentication boundary only,
without upstream latency or model-list construction. Cold/invalid percentiles
have only one/three samples and are diagnostics, not capacity predictions.
Different ETS iteration order means cold valid lookup positions differ; no
general cold-valid speedup is claimed.

| Active clients | Warm requests | Before p50/p95 (us) | After p50/p95 (us) |
| ---: | ---: | ---: | ---: |
| 1 | 1,000 | 1,954 / 4,035 | 10 / 20 |
| 8 | 1,000 | 1,996 / 2,218 | 12 / 17 |
| 32 | 1,000 | 1,971 / 4,033 | 11 / 18 |

For each 1,000-success warm batch: bcrypt **0 -> 0** (the old cache was already
warm), full client enumerations **1,000 -> 0**, signing-key queries
**1,000 -> 0**, request tasks **1,000 -> 0**, and activity writes
**1,000 -> 1**. SQL **2,000 -> 1** includes the one explicitly flushed activity
write; **after request authentication itself performs zero SQL**.

| Workload | Before -> after scans | Before -> after bcrypt calls | Notes |
| --- | --- | --- | --- |
| Cold valid, 1/8/32 clients | 1 -> 1 each | 1/1/9 -> 1/1/24 | Order-dependent match position; still O(N). |
| Three repeated invalid, 1/8/32 | 1 -> 1 each | 1/8/32 -> 1/8/32 | Dummy bcrypt 1 -> 0 each; separate negative cache. |
| Three unique invalid, 1/8/32 | 3 -> 3 each | 3/24/96 -> 3/24/96 | Dummy bcrypt 3 -> 0 each; zero signing-key SQL after. |
| Eight concurrent same invalid, 8 clients | 8 -> 1 | 64 -> 8 | Dummy bcrypt 8 -> 0; observed workers 8 -> 1. |

At 32 clients, three unique-invalid requests have before p50/p95
5,339,468 / 5,341,453 us and after 5,162,962 / 5,178,097 us. Invalid requests still
query OAuth activation when constructing their existing rejection/challenge;
periodic client snapshot SQL can also fall within long measurement windows.
Those queries are recorded separately in the JSON, not hidden as warm-path work.

Real-bcrypt saturation with 96 concurrent callers and 8 clients observes:

- Same token: **1 worker, 64 waiters, 64 ingress tickets**, one scan/eight bcrypt
  calls, 32 service-unavailable responses; warm valid authentication succeeds.
- Different tokens: **1 worker, 1 tracked waiter, 64 ingress tickets**, one
  scan/eight bcrypt calls, 95 service-unavailable responses; warm valid
  authentication succeeds. All workers/waiters/ingress drain to zero.

P0 bounds capacity; it cannot guarantee fairness for new legitimate legacy tokens
under attack. Large cold scans can hit the deadline. Eviction/restart requires
legacy bcrypt again. P1 is the separate remedy for that remaining cold O(N) cost.

## Release, deployment, and rollback

Commit P0 independently, push its immutable SHA, and dispatch the existing
`release.yml` on `main` with the next verified patch version. Wait through
qualification, release builds/migration smoke, GitHub assets, Hex/HexDocs, Docker,
and post-publish metadata. Verify tag SHA, checksums, and image revision/digest.
The normal release build versions package metadata; no excluded-app source is
authored as part of this fix.

An application restart is required: dev hot reload cannot install the new
supervision tree. For an explicitly authorized `vultr-01` deployment, its existing
service is `podman-backplane.service`, using host networking and
`ghcr.io/gsmlg-dev/backplane:latest` with pull-always. Verify that tag resolves to
the just-released digest immediately before restart; preserve the prior image
for rollback. Do not run image pruning, production migrations, token rotation,
or configuration rewriting. Verify both endpoints, authentication rejection, new
code in the image, service restarts, and unchanged client credential/scope state.

P0 leaves credential storage and schema unchanged, so the previous credential-
compatible image can be restored. Its performance/resource vulnerabilities return
on rollback. Do not reuse this rollback guarantee after future P1 digest-only
credential issuance. With a pull-always service, rollback requires deliberately
selecting the retained old digest (a local `latest` retag alone is insufficient).
