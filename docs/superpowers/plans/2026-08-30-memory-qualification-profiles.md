# Memory Qualification Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate GitHub-hosted Memory smoke thresholds from authoritative user-hardware performance thresholds, then publish `v0.6.2` through the existing release workflow.

**Architecture:** Add one pure profile module that owns canonical performance thresholds and derives GitHub `ci` thresholds by scaling only hardware-dependent values. Qualification and Recall evaluation accept an explicit profile and embed authority metadata in reports. GitHub Release invokes `ci`; direct commands default to authoritative `performance`.

**Tech Stack:** Elixir 1.18, ExUnit, Mix tasks, Ecto/PostgreSQL, GitHub Actions, GitHub CLI.

---

### Task 1: Centralize profile thresholds

**Files:**
- Create: `apps/backplane_memory/lib/backplane/memory/qualification/profile.ex`
- Create: `apps/backplane_memory/test/backplane/memory/qualification/profile_test.exs`

- [ ] **Step 1: Write the failing profile tests**

```elixir
defmodule Backplane.Memory.Qualification.ProfileTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Qualification.Profile

  test "performance preserves authoritative thresholds" do
    assert {:ok, :performance} = Profile.parse("performance")
    assert Profile.authoritative?(:performance)
    assert Profile.thresholds(:performance).qualification.ingest_events_per_second_min == 500
    assert Profile.thresholds(:performance).qualification.projection_p95_lag_ms_max_exclusive == 10_000
    assert Profile.thresholds(:performance).eval.retrieval_fusion_p95_ms_max_exclusive == 300
    assert Profile.thresholds(:performance).eval.e2e_p95_ms_max_exclusive == 800
  end

  test "ci scales only hardware-dependent thresholds to ten percent" do
    assert {:ok, :ci} = Profile.parse("ci")
    refute Profile.authoritative?(:ci)
    assert Profile.thresholds(:ci).qualification.ingest_events_per_second_min == 50.0
    assert Profile.thresholds(:ci).qualification.projection_p95_lag_ms_max_exclusive == 100_000.0
    assert Profile.thresholds(:ci).qualification.consolidation_coverage_min == 0.95
    assert Profile.thresholds(:ci).eval.recall_any_at_5_min == 0.95
    assert Profile.thresholds(:ci).eval.retrieval_fusion_p95_ms_max_exclusive == 3_000.0
    assert Profile.thresholds(:ci).eval.e2e_p95_ms_max_exclusive == 8_000.0
  end

  test "rejects unknown profiles" do
    assert {:error, :invalid_profile} = Profile.parse("fast")
  end
end
```

- [ ] **Step 2: Verify RED**

Run `devenv shell -- unbuffer mix test apps/backplane_memory/test/backplane/memory/qualification/profile_test.exs`.

Expected: compilation fails because `Profile` does not exist.

- [ ] **Step 3: Implement the pure profile module**

```elixir
defmodule Backplane.Memory.Qualification.Profile do
  @moduledoc "Threshold profiles for authoritative hardware and GitHub smoke qualification."

  @ci_scale 0.1
  @performance %{
    qualification: %{
      ingest_events_per_second_min: 500,
      projection_p95_lag_ms_max_exclusive: 10_000,
      consolidation_coverage_min: 0.95
    },
    eval: %{
      recall_any_at_5_min: 0.95,
      retrieval_fusion_p95_ms_max_exclusive: 300,
      e2e_p95_ms_max_exclusive: 800
    }
  }

  def parse("performance"), do: {:ok, :performance}
  def parse("ci"), do: {:ok, :ci}
  def parse(_), do: {:error, :invalid_profile}
  def authoritative?(:performance), do: true
  def authoritative?(:ci), do: false
  def thresholds(:performance), do: @performance

  def thresholds(:ci) do
    @performance
    |> put_in([:qualification, :ingest_events_per_second_min], 500 * @ci_scale)
    |> put_in([:qualification, :projection_p95_lag_ms_max_exclusive], 10_000 / @ci_scale)
    |> put_in([:eval, :retrieval_fusion_p95_ms_max_exclusive], 300 / @ci_scale)
    |> put_in([:eval, :e2e_p95_ms_max_exclusive], 800 / @ci_scale)
  end
end
```

- [ ] **Step 4: Verify GREEN and commit**

Run the Step 2 command; expect `3 tests, 0 failures`.

```sh
git add apps/backplane_memory/lib/backplane/memory/qualification/profile.ex apps/backplane_memory/test/backplane/memory/qualification/profile_test.exs
git commit -m "feat(memory): add qualification profiles"
```

### Task 2: Make M18 qualification profile-aware

**Files:**
- Modify: `apps/backplane_memory/lib/backplane/memory/qualification.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/qualification/runner.ex`
- Modify: `apps/backplane_memory/lib/mix/tasks/memory.qualify.ex`
- Modify: `apps/backplane_memory/test/backplane/memory/qualification_test.exs`
- Create: `apps/backplane_memory/test/backplane/memory/qualification_performance_test.exs`
- Modify: `apps/backplane_memory/test/mix/tasks/memory_qualify_test.exs`

- [ ] **Step 1: Write failing evaluation and command tests**

Add deterministic assertions that 75 events/s and 50,000 ms projection p95 pass `:ci` but fail `:performance`. Assert reports contain:

```elixir
assert ci.profile == :ci
refute ci.performance_authoritative
assert ci.thresholds.ingest_events_per_second_min == 50.0
assert performance.profile == :performance
assert performance.performance_authoritative
```

Extend the Mix task test to call `--profile ci`, decode the report, and assert `profile == "ci"`, `performance_authoritative == false`, and the effective 50 events/s threshold. Add an invalid-profile usage-error test.

- [ ] **Step 2: Verify RED**

```sh
devenv shell -- unbuffer mix test apps/backplane_memory/test/backplane/memory/qualification_test.exs apps/backplane_memory/test/mix/tasks/memory_qualify_test.exs --exclude memory_qualification_runtime
```

Expected: profile assertions fail.

- [ ] **Step 3: Implement profile-aware Qualification and Runner**

Default `Qualification.evaluate/2` and `Runner.run/1` to `:performance`. Use `Profile.thresholds(profile).qualification` in both hardware gates and add:

```elixir
%{
  profile: profile,
  performance_authoritative: Profile.authoritative?(profile),
  thresholds: thresholds,
  metrics: measurements,
  gates: gates,
  passed: Enum.all?(gates, fn {_gate, passed?} -> passed? end)
}
```

Record the concrete invoked profile and report-path contract in configuration, for example `mix memory.qualify --profile ci --report artifacts/memory-v2/memory-v2-m18-ci-smoke.json`.

- [ ] **Step 4: Parse `--profile` in `memory.qualify`**

Add `profile: :string` to `OptionParser`, default to `performance`, pass the parsed atom to `Runner.run/1` or `Runner.sandboxed_run/1`, and reject invalid values with:

```text
usage: mix memory.qualify --profile performance|ci --report <path>
```

- [ ] **Step 5: Separate authoritative runtime tests**

Move `Backplane.Memory.Qualification.IngestTest` from `qualification_test.exs` into `qualification_performance_test.exs`, rename it `Backplane.Memory.Qualification.PerformanceTest`, retain `@moduletag :memory_qualification_runtime`, and pass `profile: :performance` to the complete Runner workload.

- [ ] **Step 6: Verify both profiles and commit**

```sh
devenv shell -- unbuffer mix test apps/backplane_memory/test/backplane/memory/qualification_test.exs apps/backplane_memory/test/mix/tasks/memory_qualify_test.exs --exclude memory_qualification_runtime
devenv shell -- unbuffer mix test apps/backplane_memory/test/backplane/memory/qualification_performance_test.exs --include memory_qualification_runtime
git add apps/backplane_memory/lib/backplane/memory/qualification.ex apps/backplane_memory/lib/backplane/memory/qualification/runner.ex apps/backplane_memory/lib/mix/tasks/memory.qualify.ex apps/backplane_memory/test/backplane/memory/qualification_test.exs apps/backplane_memory/test/backplane/memory/qualification_performance_test.exs apps/backplane_memory/test/mix/tasks/memory_qualify_test.exs
git commit -m "feat(memory): profile M18 qualification"
```

### Task 3: Make Recall evaluation profile-aware

**Files:**
- Modify: `apps/backplane_memory/lib/backplane/memory/eval.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/eval/runner.ex`
- Modify: `apps/backplane_memory/lib/mix/tasks/memory.eval.ex`
- Modify: `apps/backplane_memory/test/backplane/memory/eval_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/eval_runner_test.exs`
- Create: `apps/backplane_memory/test/mix/tasks/memory_eval_test.exs`

- [ ] **Step 1: Write failing Eval profile tests**

Use a report with retrieval p95 `1_000` and e2e p95 `4_000`:

```elixir
assert Eval.thresholds_pass?(report, profile: :ci)
refute Eval.thresholds_pass?(report, profile: :performance)
```

Assert Runner and task reports expose `profile`, `performance_authoritative`, and effective 3,000/8,000 ms CI limits. Assert invalid task profiles fail with a usage error.

- [ ] **Step 2: Verify RED**

```sh
devenv shell -- unbuffer mix test apps/backplane_memory/test/backplane/memory/eval_test.exs apps/backplane_memory/test/backplane/memory/eval_runner_test.exs apps/backplane_memory/test/mix/tasks/memory_eval_test.exs
```

Expected: profile assertions fail.

- [ ] **Step 3: Implement profile-aware Eval, Runner, and Mix task**

Use `Profile.thresholds(profile).eval` for latency verdicts while leaving recall quality, outage availability, and provenance unchanged. Add profile/authority/effective-threshold metadata to Runner reports. Parse `--profile performance|ci` in `memory.eval`, default to `performance`, and pass the profile to `Runner.sandboxed_run/1` and `Eval.ensure_thresholds!/2`.

- [ ] **Step 4: Verify GREEN and commit**

Run the Step 2 command; expect all focused tests to pass.

```sh
git add apps/backplane_memory/lib/backplane/memory/eval.ex apps/backplane_memory/lib/backplane/memory/eval/runner.ex apps/backplane_memory/lib/mix/tasks/memory.eval.ex apps/backplane_memory/test/backplane/memory/eval_test.exs apps/backplane_memory/test/backplane/memory/eval_runner_test.exs apps/backplane_memory/test/mix/tasks/memory_eval_test.exs
git commit -m "feat(memory): profile recall evaluation"
```

### Task 4: Route GitHub Release through CI smoke profiles

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `test/release_config_test.exs`

- [ ] **Step 1: Write failing workflow-contract assertions**

Require `--profile ci` on both Memory commands, CI-specific report filenames, continued `--exclude memory_qualification_runtime`, and absence of `capture_performance_test.exs` from the workflow.

- [ ] **Step 2: Verify RED**

Run `devenv shell -- unbuffer mix run --no-start test/release_config_test.exs`.

Expected: new workflow assertions fail.

- [ ] **Step 3: Update workflow commands**

```yaml
mix memory.eval \
  --profile ci \
  --report artifacts/memory-v2/memory-v2-eval-ci-smoke.json \
  --longmemeval artifacts/memory-v2/memory-v2-longmemeval.jsonl \
  --sidecar artifacts/memory-v2/memory-v2-longmemeval-sidecar.json
BACKPLANE_MEMORY_QUALIFICATION_REAL_POOL=true mix memory.qualify \
  --profile ci \
  --report artifacts/memory-v2/memory-v2-m18-ci-smoke.json
```

Remove `capture_performance_test.exs` from the GitHub adapter test list. Keep migration, outage, privacy, hook, integration, browser, integrity, durability, and installed-release checks.

- [ ] **Step 4: Verify GREEN and commit**

Run the Step 2 command; expect all release configuration tests to pass.

```sh
git add .github/workflows/release.yml test/release_config_test.exs
git commit -m "ci(release): use memory smoke profiles"
```

### Task 5: Document smoke and hardware evidence

**Files:**
- Modify: `docs/qualification/memory-v2.md`
- Modify: `docs/deploy/memory-v2-release.md`

- [ ] **Step 1: Document explicit hardware commands**

Document `mix memory.qualify --profile performance` and `mix memory.eval --profile performance`, using `memory-v2-m18-performance.json` and `memory-v2-eval-performance.json` filenames.

- [ ] **Step 2: Document CI smoke semantics**

State that GitHub reports use 10% hardware-dependent thresholds, keep identical correctness/quality gates, and are not authoritative performance evidence. Require release records to distinguish CI smoke reports from separately captured hardware reports.

- [ ] **Step 3: Verify and commit**

```sh
rg -n "profile (ci|performance)|ci-smoke|performance_authoritative" docs/qualification/memory-v2.md docs/deploy/memory-v2-release.md
git diff --check
git add docs/qualification/memory-v2.md docs/deploy/memory-v2-release.md
git commit -m "docs(memory): separate smoke and performance evidence"
```

### Task 6: Verify, review, merge, and release v0.6.2

**Files:**
- Verify all files changed in Tasks 1-5.

- [ ] **Step 1: Run scoped verification**

```sh
devenv shell -- unbuffer mix test apps/backplane_memory/test/backplane/memory/qualification/profile_test.exs apps/backplane_memory/test/backplane/memory/qualification_test.exs apps/backplane_memory/test/mix/tasks/memory_qualify_test.exs apps/backplane_memory/test/backplane/memory/eval_test.exs apps/backplane_memory/test/backplane/memory/eval_runner_test.exs apps/backplane_memory/test/mix/tasks/memory_eval_test.exs --exclude memory_qualification_runtime
devenv shell -- unbuffer mix run --no-start test/release_config_test.exs
devenv shell -- unbuffer mix format --check-formatted
devenv shell -- unbuffer mix credo --strict
git diff --check
```

Expected: every command exits zero.

- [ ] **Step 2: Run authoritative local qualification**

```sh
MIX_ENV=test BACKPLANE_MEMORY_QUALIFICATION_REAL_POOL=true devenv shell -- unbuffer mix memory.qualify --profile performance --report artifacts/memory-v2/memory-v2-m18-performance.json
```

Expected: original 500/10,000 thresholds, `performance_authoritative=true`, and `passed=true` on user hardware.

- [ ] **Step 3: Review, push, and open PR**

Request independent review against `origin/main`, resolve Critical/Important findings, then:

```sh
git push -u origin codex/release-v0.6.2-gate
gh pr create --base main --head codex/release-v0.6.2-gate --title "ci(release): separate memory smoke and performance gates" --body "Separates GitHub smoke thresholds from authoritative user-hardware performance thresholds while preserving correctness and publication gates."
```

- [ ] **Step 4: Merge after green checks**

Resolve the created PR number and merge only after green checks:

```sh
pr_number="$(gh pr view codex/release-v0.6.2-gate --json number --jq .number)"
gh pr checks "$pr_number" --watch
gh pr merge "$pr_number" --squash --delete-branch
git fetch origin main
test "$(git rev-parse origin/main)" = "$(git ls-remote origin refs/heads/main | cut -f1)"
```

- [ ] **Step 5: Dispatch and verify v0.6.2**

Confirm no `v0.6.2` tag or release exists, dispatch `gh workflow run release.yml --repo gsmlg-opt/backplane --ref main -f version=0.6.2`, and watch the run to success.

Verify the gated tag target; six platform archives and checksums; deploy/Memory documents; CI smoke reports and manifest; installed migration smoke; Hex `backplane_mcp_protocol` version `0.6.2`; GHCR `0.6.2` and `latest` tags/digest; and Docker information appended to release notes.
