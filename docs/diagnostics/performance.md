# Diagnostics performance pilot

Run the controlled T13 workload from the repository root after compiling the test applications.

```sh
DIAGNOSTICS_BENCHMARK_PG_BIN=/path/to/postgresql/bin \
  elixir --erl '+S 8:8' -pa '_build/test/lib/*/ebin' scripts/diagnostics_benchmark.exs
```

The PostgreSQL binary path can be omitted when `initdb` and `pg_ctl` are on `PATH`. The harness creates a private spool and PostgreSQL cluster with a Unix socket. It loads synthetic, schema-valid envelope fields and removes its temporary resources on exit. It uses synchronous spool and PostgreSQL commit settings and a controlled acknowledgement transport.

## Method and pilot gates

These gates apply to this fixed workload. They were set before running the pilot.

| Phase | Workload and measurement | Gate |
| --- | --- | --- |
| Normal Reporter | 16 rounds of 64 requests per mode, after warmup. Each request performs the same small application operation and calls `Reporter.report`. The enabled transport acknowledges batches between rounds. Time each request with the monotonic clock. | Enabled p95 minus disabled p95 ≤ 250 µs and enabled p99 minus disabled p99 ≤ 700 µs. Every enabled observation is accepted and drained. |
| Reporter failure storm | Eight concurrent producers, 5,000 requests each per mode, paced in 250-request bursts with 10 ms between bursts. The enabled Reporter has a 1,000-event or 4 MiB admission limit and its transport returns an unavailable result. Sample BEAM process RSS and queue health with 20 ms between samples. | Enabled p99 minus disabled p99 ≤ 1,500 µs. Sampled RSS stays within 64 MiB of its own pre-storm baseline. Pending observations and bytes stay within their limits. Drops are visible and the counters account for all 40,000 requests. |
| Host spool and drain | Four sources offer 1,200 events each with 512-byte synthetic messages, mixed ordinary and priority classes, in 64-event API batches. A temporary Turso spool has 4 MiB of payload capacity and a 16 MiB disk budget. Start the real uploader against the controlled acknowledgement transport after the offline backlog is loaded. Measure database plus WAL after every append and drain batch. | Observed combined allocation ≤ 16 MiB. Quota refusal is visible. Every admitted event is confirmed, and pending data drains within 30 seconds. |
| PostgreSQL ingest and paging | 100 batches of 32 events and 256 distinct issue signatures. Record Ecto commit telemetry and wall-clock batch ingest through encoded durable receipt, drain the projector, and traverse 25 full 30-row keyset pagesets. | Commit p95 ≤ 20 ms, encoded batch response p95 ≤ 150 ms, query p99 ≤ 25 ms. Durable receipts account for every event, and each traversal covers each issue exactly once. |

The harness uses nearest-rank percentiles. Spool allocation is sampled at batch boundaries. RSS is sampled for the BEAM process only, separate from disk allocation and PostgreSQL server memory. Measured latency covers the named local boundaries and excludes network round trips, external notifications, and model calls.

## Measured pilot

All 11 gates passed on 2026-11-27 at 17:41 UTC. The machine was an Apple M1 Max with 32 GiB RAM, Darwin arm64, OTP 28, Elixir 1.20.4, eight BEAM schedulers, Turso 3.1.18, and PostgreSQL 17.12 from Postgres.app. PostgreSQL reported `fsync=on` and `synchronous_commit=on`.

| Measurement | Unit | p50 | p95 | p99 |
| --- | --- | ---: | ---: | ---: |
| Normal request, Reporter disabled | µs | 2.58 | 2.67 | 5.88 |
| Normal request, Reporter enabled | µs | 138.96 | 160.17 | 208.29 |
| Storm request, Reporter disabled | µs | 3.08 | 3.83 | 7.00 |
| Storm request, Reporter enabled | µs | 3.46 | 4.08 | 272.83 |
| PostgreSQL commit | µs | 72.75 | 119.63 | 151.13 |
| Encoded receipt for 32 stored events | ms | 21.123 | 26.027 | 28.229 |
| Keyset issue page, up to 30 rows | µs | 124.38 | 181.96 | 261.63 |

- The enabled Reporter accepted and drained all 1,024 normal observations. During the unavailable-transport storm, 1,000 observations were pending and 39,000 were visibly dropped at admission. The steady pending payload was 911,141 bytes. The largest sampled reservation was 1,184,146 bytes. Over 11 samples, BEAM RSS rose from 129,328 to 140,528 KiB, a difference of 10.94 MiB. The disabled storm peaked at 136,368 KiB over 10 samples.
- The offline spool offered 4,800 events, stored 4,090 with 4,193,679 pending payload bytes, and returned 710 quota refusals. Combined database and WAL file length peaked at 6,622,240 bytes. The uploader confirmed all 4,090 admitted events in 41 batches over 1.483 seconds, leaving zero pending bodies. Combined file length after checkpoint was 6,094,848 bytes, including durable receipt records and reusable database pages.
- PostgreSQL persisted all 3,200 events in 100 receipt batches. The projector drained all 3,200 events in 4.102 seconds. All 25 traversals returned the same 256 unique issues via 225 bounded queries in total.

The results establish the pilot budgets for this workload, hardware, and database configuration. Use the same workload and gates when comparing storage, scheduler, or transport changes.

## Integrated candidate replay

The same harness and 11 gates passed after the historical import and issue regrouping changes, at 18:04 UTC on 2026-11-27. Normal request p99 was 247.58 µs enabled and 5.71 µs disabled. Unavailable-transport storm p99 was 286.88 µs enabled and 8.88 µs disabled, with 6.78 MiB additional sampled RSS, 1,000 retained observations, and 39,000 visible drops. The spool held 4,090 admitted records, returned 710 quota refusals, and drained in 1.283 seconds. Peak database and WAL allocation was 6,692,280 bytes. PostgreSQL commit p95 was 75.46 µs, 32-event receipt p95 was 22.076 ms, and page query p99 was 220.46 µs. All 3,200 events projected and all 25 keyset traversals returned 256 unique issues.
