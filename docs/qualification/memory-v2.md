# Memory V2 Qualification and Evaluation

The release workflow runs the reproducible `ci` smoke profile on Ubuntu with
Elixir 1.18, OTP 28, PostgreSQL 17, and pgvector. GitHub-hosted hardware is not
an authoritative performance baseline: minimum throughput gates use 10% of the
`performance` requirement and maximum latency gates use 10 times its ceiling.
All correctness, durability, quality, outage, provenance, and migration gates
remain unchanged. The downloadable artifact is named
`memory-v2-qualification` and contains:

- `memory-v2-m18-ci-smoke.json`: measured ingest, projection, consolidation,
  outage, and retry/contention smoke gates;
- `memory-v2-eval-ci-smoke.json`: Backplane's coding-corpus metrics and CI
  threshold data;
- `memory-v2-longmemeval.jsonl`: LongMemEval-shaped, explicitly non-comparable
  retrieval export;
- `memory-v2-longmemeval-sidecar.json`: Backplane provenance/format metadata;
- `memory-v2-replay-browser.json`: real headless-Chrome evidence for paginated
  replay, controls, cursor movement, disconnect/reconnect state, and live PubSub;
  and
- `qualification-manifest.txt`: git revision and SHA-256 digests.

These are Backplane results. Agentmemory's published numbers are reference
targets and must not be reported as Backplane evidence.

Every report records `profile` and `performance_authoritative`. A `ci` report
has `performance_authoritative=false` and must not be represented as hardware
performance evidence. Direct commands default to the authoritative
`performance` profile.

## Reproduce locally

Use a disposable `backplane_test` database. The evaluation task is deliberately
restricted to `MIX_ENV=test` and rolls back its seeded corpus:

```sh
mkdir -p artifacts/memory-v2
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps \
  devenv shell -- mix ecto.create

MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps \
  devenv shell -- sh -c \
    'psql -h "$PGHOST" -d backplane_test -c "CREATE EXTENSION IF NOT EXISTS vector"'

MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps \
  devenv shell -- mix ecto.migrate

MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps \
  devenv shell -- mix test \
    apps/backplane_memory/test/backplane/memory/m18_migration_chain_test.exs \
    apps/backplane_memory/test/backplane/memory/m18_migration_matrix_test.exs \
    apps/backplane_memory/test/backplane/memory/qualification_test.exs \
    --exclude memory_qualification_runtime

MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps \
  devenv shell -- mix test \
    apps/backplane_host_agent/test/backplane/host_agent/memory/capture_outage_contract_test.exs \
    apps/backplane_host_agent/test/backplane/host_agent/memory/capture_performance_test.exs \
    apps/backplane_host_agent/test/backplane/host_agent/memory/event_envelope_test.exs \
    apps/backplane_host_agent/test/backplane/host_agent/memory/integration_plugin_contract_test.exs \
    apps/backplane_api/test/backplane/api/memory_m18_outage_qualification_test.exs

MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps \
  devenv shell -- mix test \
    apps/backplane_memory/test/backplane/memory/qualification_performance_test.exs \
    --include memory_qualification_runtime

MIX_ENV=test BACKPLANE_MEMORY_QUALIFICATION_REAL_POOL=true \
  MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps \
  devenv shell -- mix memory.qualify \
    --profile performance \
    --report artifacts/memory-v2/memory-v2-m18-performance.json

MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps \
  devenv shell -- mix memory.replay.browser_qualify \
    --report artifacts/memory-v2/memory-v2-replay-browser.json

MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps \
  devenv shell -- mix memory.seed_bench

MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps \
  devenv shell -- mix memory.eval \
    --profile performance \
    --report artifacts/memory-v2/memory-v2-eval-performance.json \
    --longmemeval artifacts/memory-v2/memory-v2-longmemeval.jsonl \
    --sidecar artifacts/memory-v2/memory-v2-longmemeval-sidecar.json
```

The evaluator exits non-zero if its guarded thresholds fail. Inspect the report
rather than relying only on exit status. The `performance` profile retains the
required top-5 hit rate of at least 95%, 100% provenance for returned
auto-derived records, FTS-only availability during provider outage, and
retrieval/fusion p95 below 300 ms (excluding query embedding and LLM latency).
The `ci` profile changes only hardware-dependent latency ceilings.

The replay browser gate starts the routed admin LiveView on loopback, seeds 121
events to exercise multi-page loading, drives playback through Chrome DevTools
Protocol, forces a websocket disconnect/reconnect, and publishes event 122 over
the replay PubSub topic. It fails unless the already-connected page receives the
new row without a reload. The task is test-only; pass `--browser PATH` or set
`CHROME_BIN` when Chrome is not installed at a standard path.

The M18 ingest measurement runs against the normal Ecto connection pool in the
disposable qualification database. The surrounding contract tests retain SQL
sandbox isolation and exclude the `memory_qualification_runtime` workload.
The measurement exercises the production `Ingest.ingest_batch` and
`Events.Store.append_batch_tagged` path through the durable Oban projection-job
insert. Oban runs in manual test mode only to prevent background execution from
contaminating ingest timing; the gate additionally requires one unique durable
projection job per accepted event. Projection lag starts at the ingest ACK and
ends only after the production `ProjectionRepairWorker` job is completed and
all four deterministic projection states are `complete`.

## Production qualification record

Attach the workflow CI-smoke artifact and installed-release smoke result to the
release. Record authoritative `performance` reports separately when they are
run on controlled hardware; their absence does not block GitHub artifact
publication and a CI-smoke report is not a substitute. Also record:

- release tag, commit, OTP/Elixir/PostgreSQL/pgvector versions, and artifact
  checksums;
- restored backup evidence and schema migration versions;
- capture-outage result (lost accepted events must be zero);
- privacy fixture result (spool/database leakage must be zero);
- duplicate replay/import effects (must be zero);
- activity consistency result (fixture discrepancy must be zero);
- host enqueue p95 and projection-lag observations; and
- any unavailable adapter, provider, or channel with an explicit skipped-state
  reason rather than silently treating it as passed.

Keep reports under the workflow run's artifact retention and copy their digests
into durable release notes. Do not upload real prompts, tool payloads,
credentials, or unredacted replay content as qualification artifacts.
