# Memory Qualification Profiles Design

## Context

Backplane's release workflow currently treats absolute throughput and latency measurements from a shared GitHub-hosted runner as authoritative release gates. Two `v0.6.2` release attempts failed only the ingest throughput gate at 497.81 and 496.10 events per second against a 500 events per second threshold. The same merged code exceeded 1,190 events per second on dedicated local hardware. Correctness, durability, outage recovery, projection, provenance, and recall-quality gates passed.

GitHub-hosted hardware is suitable for smoke coverage but is not a stable performance baseline. Release success must therefore be separated from authoritative hardware qualification.

## Goals

- Keep GitHub release workflows fail-closed for correctness, durability, integrity, recovery, and artifact production.
- Retain lightweight performance smoke checks on GitHub at 10% of the authoritative hardware requirements.
- Keep the existing authoritative performance requirements unchanged for runs on user-controlled hardware.
- Make reports identify their profile so a GitHub smoke report cannot be mistaken for a hardware qualification report.
- Restore the normal `v0.6.2` release path after the profile change is merged.

## Non-goals

- Do not optimize or refactor the Memory ingest storage path.
- Do not globally lower the authoritative performance requirements.
- Do not introduce a new hosted performance service or self-hosted GitHub runner.
- Do not weaken non-performance release gates.

## Qualification profiles

Two explicit profiles will share the same production code paths and workload definitions.

### `performance`

This is the authoritative profile for user-controlled hardware. It preserves all current performance requirements and remains the default for direct/manual qualification commands so existing local use cannot silently become less strict.

Examples include:

- ingest throughput at least 500 events per second;
- projection p95 below the current 10-second ceiling;
- existing Recall V2 latency ceilings;
- the existing 2,000-event workload, 100-event batches, and 1,000-event warmup.

### `ci`

This is the GitHub-hosted smoke profile. It retains the same workloads and production paths but scales only hardware-dependent thresholds to 10% of the authoritative requirement:

- minimum throughput thresholds are multiplied by `0.1`;
- maximum latency thresholds are multiplied by `10`;
- quality ratios, integrity counts, durability counts, idempotency checks, outage recovery, provenance, migration, and functional assertions are unchanged.

The scaling rule is centralized rather than copied into workflow YAML or individual tests.

## Command and report contract

Qualification and evaluation commands accept an explicit profile option:

```sh
mix memory.qualify --profile performance --report <path>
mix memory.qualify --profile ci --report <path>
mix memory.eval --profile performance --report <path> ...
mix memory.eval --profile ci --report <path> ...
```

Invalid or missing profile values fail with a clear usage error. The command default remains `performance` outside GitHub workflows.

Every generated report records:

- `profile`: `performance` or `ci`;
- `performance_authoritative`: `true` only for `performance`;
- the effective thresholds;
- the unchanged workload and runtime metadata.

GitHub release artifacts use CI-specific names such as `memory-v2-m18-ci-smoke.json` and `memory-v2-eval-ci-smoke.json`. Dedicated hardware runs use performance-specific filenames. This prevents accidental promotion of a smoke report as production performance evidence.

## Workflow behavior

The GitHub release workflow invokes the `ci` profile explicitly for both Memory M18 qualification and Recall V2 evaluation. It continues to require every non-performance gate and the scaled smoke gates before building any release artifact.

Authoritative performance tests move to a separate performance test file or tag and are excluded from ordinary GitHub Test and Release jobs. The documented hardware command runs them explicitly with the `performance` profile.

After the profile change reaches `main`, `v0.6.2` is dispatched again. Publication verification must cover the tag target, all platform archives and checksums, installed migration smoke, Hex package, GHCR tags/digest, and final release notes.

## Testing

- Unit tests prove the exact threshold mapping for both profiles.
- Command tests prove explicit profile parsing, invalid-profile failure, and the default `performance` behavior.
- Report tests prove profile and authority metadata are serialized.
- Workflow contract tests prove GitHub uses `ci` explicitly and excludes authoritative performance tests.
- Existing correctness and durability tests remain unchanged.
- Dedicated performance tests prove the original thresholds remain intact and are runnable explicitly outside GitHub.

## Success criteria

- GitHub Release no longer depends on shared-runner absolute performance at the authoritative threshold.
- GitHub still exercises the production ingest/evaluation paths with 10% smoke thresholds.
- User-controlled hardware retains the original authoritative thresholds.
- Reports cannot confuse CI smoke evidence with hardware performance evidence.
- `v0.6.2` completes the full publication chain without changing the original performance targets.
