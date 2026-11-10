# Memory Plan 4 — Host Collectors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The host agent periodically snapshots git checkouts, services and host info, uploads a snapshot only when it changed, and the gateway deterministically turns snapshot diffs into `fact` records written by `host_collector`.

**Architecture:** Host side: a `Collectors.Scheduler` under `CaptureSupervisor` runs collector modules, fingerprints each `(collector, unit)` snapshot, and appends changed ones to the existing capture spool as `host.snapshot.collected` events (no session). Gateway side: `Events.Store` enqueues a `HostSnapshotWorker` per such event; `HostSnapshots.apply/1` diffs the snapshot against per-`(host, collector, unit)` state and writes/forgets facts through `Records`. No LLM.

**Tech Stack:** Elixir umbrella, Ecto/Postgres, Styx jobs, existing host-agent Turso spool.

**Spec:** `docs/superpowers/specs/2026-11-09-memory-simplification-design.md` (§6.6, §4 anti-goal "same snapshot every time", §8.7)

## Global Constraints

- Snapshot→fact mapping is deterministic; no LLM call anywhere in this plan (spec §6.6).
- Facts from snapshots have `writer: "host_collector"`, `integration: "host_collector"`, `host_id` = reporting host (spec §6.3, §6.6).
- Disappearance only invalidates facts whose writer is `host_collector`; `agent`/`user` facts are never auto-invalidated (spec §6.6).
- Disappearance counts only when that unit's scan was **complete**; collector disabled, root removed, or partial failure never invalidates (spec §6.6).
- Only report on content change (fingerprint); identical snapshots are never re-uploaded (spec §4, §6.6).
- Remote URLs leave the host only as `Backplane.MemoryRepository.normalize_remote/1` output (credentials stripped).
- Schema/context in `backplane_memory`; migration in `apps/backplane_system/priv/repo/migrations`; host code in `backplane_host_agent` (spec §5).
- Out of scope: memory-agent enrichment of collector facts (spec §6.6 "only when needed"), admin UI changes (collector facts show in the existing Records page via `writer`), and plugins (Plan 5).
- Commits: Conventional Commits; never add "Generated with Claude Code" or a `Co-Authored-By: Claude` trailer.
- macOS dev: Postgres.app on localhost:5432 (`unset PGHOST`); never devenv. Run tests from the umbrella root: `mix test apps/<app>/test/...`.

## Review Focus

1. A git remote like `https://user:ghp_token@github.com/o/r.git` must never appear in the event payload or a fact — only `github.com/o/r`. (Task 5 test)
2. A missing/unreadable scan root, missing `git`/`docker` binary, or a failing command must never mass-forget facts: unit is skipped or `complete: false`. (Tasks 2, 5, 6)
3. An older snapshot arriving after a newer one (offline spool, retries) is ignored, not applied backwards. (Task 2 test)
4. Volatile output (docker "Up 3 hours", launchd PIDs, listening-port order) must not change the fingerprint → no re-upload on an idle host. (Tasks 6, 7 tests)
5. A root with more than 500 repos produces a bounded event marked `complete: false` (never an oversize event stuck in the spool, never a mass-forget). (Task 5 test)

---

## Snapshot contract (shared by all tasks)

Envelope (host → gateway), built by the Scheduler:

| field | value |
|---|---|
| `event_type` | `"host.snapshot.collected"` |
| `integration` / `client_id` | `"host_collector"` |
| `agent_id` | `"host-collector"` |
| `session_id` | absent |
| `occurred_at` | collection time (ISO-8601) — the gateway uses this as `observed_at` and for ordering |
| `idempotency_key` | `"host_collector:<collector>:<unit>:<fingerprint>:<occurred_at>"` |
| `event_id` | `UUID7.generate()` |

Payload (top level of the envelope `payload`):

```json
{"collector": "git|docker|systemd|launchd|host", "unit": "<string>", "complete": true, "items": [ ... ]}
```

`unit` = absolute root path for `git`; `"local"` for every other collector. Items:

| collector | item | item key |
|---|---|---|
| git | `{"path", "repository_id" (string or null), "branch" (string or null), "head": {"commit","subject","committed_at"} or null}` | `path` |
| docker | `{"name","image","state","ports"}` (`ports` = sorted list of strings) | `name` |
| systemd | `{"name","description"}` | `name` |
| launchd | `{"label"}` | `label` |
| host | exactly one `{"hostname","os","addresses" (sorted),"listening" (sorted by port: [{"port","process"}])}` | `"host"` |

Fingerprint = `sha256` hex of canonical JSON of `%{"complete", "items" (sorted by item key)}`.

Facts per item (H = host_id; `{t,k}` = subject; property in **bold**):

| collector | subjects | property → content |
|---|---|---|
| git | `{host,H}`, `{path,path}`, plus `{repo,repository_id}` when non-null | **git_checkout** → `"Git checkout of <repository_id or "a local repository (no remote)"> at <H>:<path> (branch <branch or "detached">)."`; **git_head** (only when head non-null) → `"Latest commit in <H>:<path>: <commit[0,7]> \"<subject>\" (<committed_at>)."` |
| docker | `{host,H}`, `{service,name}` | **docker_container** → `"Docker container <name> on <H>: image <image>, state <state>, ports <ports joined ", " or "none">."` |
| systemd | `{host,H}`, `{service,name}` | **systemd_service** → `"systemd service <name> runs on <H>: <description>."` |
| launchd | `{host,H}`, `{service,label}` | **launchd_job** → `"launchd job <label> is loaded on <H>."` |
| host | `{host,H}` | **os** → `"<H> runs <os>."`; **hostname** → `"<H> has hostname <hostname>."`; **ip_addresses** → `"<H> IP addresses: <addresses joined ", ">."`; **listening_ports** → `"<H> listens on TCP ports: <"port (process)" joined ", ">."` (`process` omitted when null) |

A fact's **slot id** = `property <> "|" <> Enum.join(subject_keys, ",")` using `Records.normalize_subjects/1` keys.

---

### Task 1: Gateway snapshot payload + fact mapping (pure)

**Files:**
- Create: `apps/backplane_memory/lib/backplane/memory/host_snapshots/facts.ex`
- Test: `apps/backplane_memory/test/backplane/memory/host_snapshots/facts_test.exs`

**Interfaces:**
- Produces:
  - `Backplane.Memory.HostSnapshots.Facts.validate(payload :: map()) :: {:ok, %{collector: String.t(), unit: String.t(), complete: boolean(), items: [map()]}} | {:error, atom()}` — rejects unknown collector (`:unknown_collector`), blank unit (`:invalid_unit`), non-boolean complete, non-list items, items missing their key field (`:invalid_item`).
  - `Facts.item_key(collector :: String.t(), item :: map()) :: String.t()`
  - `Facts.facts(host_id :: String.t(), collector :: String.t(), item :: map()) :: [%{subjects: [map()], subject_keys: [String.t()], property: String.t(), content: String.t(), slot: String.t()}]` — exactly the table above.

- [ ] **Step 1: Write failing tests** — one per collector asserting exact `property`, `content`, `subject_keys` (e.g. git item `%{"path" => "/srv/app", "repository_id" => "github.com/o/r", "branch" => "main", "head" => %{"commit" => "abcdef123456", "subject" => "fix x", "committed_at" => "2026-11-10T01:00:00Z"}}` on host `"db02"` → two facts; `git_checkout` content `"Git checkout of github.com/o/r at db02:/srv/app (branch main)."`, subject_keys `["host:db02", "path:/srv/app", "repo:github.com/o/r"]`, slot `"git_checkout|host:db02,path:/srv/app,repo:github.com/o/r"`). Plus: null remote → `"a local repository (no remote)"` and no repo subject; null head → only `git_checkout`; host item → 4 facts; `validate/1` error cases.
- [ ] **Step 2: Run** `mix test apps/backplane_memory/test/backplane/memory/host_snapshots/facts_test.exs` — Expected: FAIL (module undefined).
- [ ] **Step 3: Implement** `facts.ex` (pure; subjects normalized via `Backplane.Memory.Records.normalize_subjects/1`).
- [ ] **Step 4: Run** the test — Expected: PASS.
- [ ] **Step 5: Commit** `feat(memory): map host snapshot items to deterministic facts`

### Task 2: Gateway snapshot apply + state table

**Files:**
- Create: `apps/backplane_system/priv/repo/migrations/20261110000005_create_memory_host_snapshots.exs`
- Create: `apps/backplane_memory/lib/backplane/memory/host_snapshots/state.ex` (schema `memory_host_snapshots`)
- Create: `apps/backplane_memory/lib/backplane/memory/host_snapshots.ex`
- Test: `apps/backplane_memory/test/backplane/memory/host_snapshots_test.exs`

**Interfaces:**
- Consumes: Task 1 `Facts.validate/1`, `Facts.facts/3`, `Facts.item_key/2`; `Records.remember/1`, `Records.forget/2`.
- Produces: `Backplane.Memory.HostSnapshots.apply(event :: %Backplane.Memory.Events.Event{}) :: {:ok, %{written: non_neg_integer(), forgotten: non_neg_integer()}} | {:ok, :stale} | {:error, term()}`

Table `memory_host_snapshots`: `host_id` text, `collector` text, `unit` text, `collected_at` utc_datetime_usec, `event_id` binary_id, `slots` jsonb (map slot id → `%{"item" => item_key, "hash" => sha256(content)}`), timestamps; unique index `(host_id, collector, unit)`.

Algorithm (one transaction; lock the state row with `FOR UPDATE`, inserting it first if absent):
1. If state exists and `state.collected_at >= event.occurred_at` → `{:ok, :stale}` (no writes).
2. `new` = slot → `{item_key, fact}` for all items. For each new slot whose hash differs from `state.slots[slot]` (or is absent): `Records.remember(%{"kind" => "fact", "writer" => "host_collector", "integration" => "host_collector", "host_id" => event.host_id, "agent_id" => event.agent_id, "subjects" => ..., "property" => ..., "content" => ..., "observed_at" => event.occurred_at, "source_event_ids" => [event.id], "request_key" => "host_collector:" <> event.id <> ":" <> sha256_hex(slot)})`.
3. Removed slots = in state but not in `new`. Forget a removed slot when `complete` is true, OR when its item key is present in this snapshot (the item changed shape). Otherwise (incomplete and item absent) keep it in the new state. Forget = every active record with `kind "fact"`, `writer "host_collector"`, `host_id` = H, same `property` and `subject_keys` → `Records.forget(id, "no longer present in host collector snapshot (<collector>:<unit>)")`.
4. Save state: `collected_at`, `event_id`, `slots` = new slots ∪ kept slots.

- [ ] **Step 1: Write failing tests** (insert events with `Backplane.Memory.Events.Store.append/1` or a factory, then call `apply/1`):
  - first snapshot with 2 git repos → 3–4 facts, all `writer "host_collector"`, `source_event_ids == [event.id]`, `observed_at == occurred_at`;
  - same content again (newer `occurred_at`) → `%{written: 0, forgotten: 0}`;
  - branch change → only `git_checkout` rewritten; old one `superseded`;
  - complete snapshot missing a repo → its facts `forgotten` with the reason above; `memory::get`-style `Records.get/1` shows reason;
  - `complete: false` snapshot missing a repo → nothing forgotten, slot kept, next complete snapshot without it forgets it;
  - an `agent`-written fact with the same slot is never forgotten;
  - a user-forgotten collector fact is not re-written while its content is unchanged;
  - older `occurred_at` after a newer one → `{:ok, :stale}` and no record changes (Review Focus 3);
  - invalid payload → `{:error, _}`, no writes.
- [ ] **Step 2: Run** `MIX_ENV=test mix ecto.migrate && mix test apps/backplane_memory/test/backplane/memory/host_snapshots_test.exs` — Expected: FAIL.
- [ ] **Step 3: Implement** migration, schema, `apply/1`.
- [ ] **Step 4: Run** the test — Expected: PASS.
- [ ] **Step 5: Commit** `feat(memory): apply host snapshot diffs as host_collector facts`

### Task 3: Gateway ingest + worker wiring

**Files:**
- Modify: `apps/backplane_memory/lib/backplane/memory/ingest/event_validator.ex` (`@canonical_types`)
- Modify: `apps/backplane_memory/lib/backplane/memory/events/types.ex` (`@types`)
- Create: `apps/backplane_memory/lib/backplane/memory/workers/host_snapshot_worker.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/events/store.ex` (next to `enqueue_projection_repair/1` and `enqueue_projection_repairs/1`)
- Modify: `docs/architecture/memory.md` (new "Host collectors" section: contract, diff/forget rules, worker)
- Test: `apps/backplane_memory/test/backplane/memory/workers/host_snapshot_worker_test.exs`

**Interfaces:**
- Consumes: Task 2 `HostSnapshots.apply/1`.
- Produces: `Backplane.Memory.Workers.HostSnapshotWorker` (Styx, `queue: :memory`, `max_attempts: 5`, args `%{"event_id" => id}`, unique on `event_id`, `period: :infinity`); `enqueue(event_id :: String.t())`.

Worker `perform/1`: load the event; `apply/1` → `{:ok, _}` → `:ok`; `{:error, reason}` from payload validation → `Logger.warning` + `{:cancel, reason}`; other errors → `{:error, reason}` (retry). Store: in both the single-insert and batch paths, after projection enqueue, enqueue the worker for inserted events with `event_type == "host.snapshot.collected"` inside the same transaction (failure → `{:error, :transaction_rolled_back}` like projection repair).

- [ ] **Step 1: Write failing tests** — end to end through `Backplane.Memory.Ingest.ingest_batch/3` (use `IngestFixtures.valid_event/1` + `ingest_auth_context/1`, override event_type/integration/payload, drop `session_id`): result `"accepted"`; draining the `:memory` queue (`Styx` testing helper used by existing worker tests) yields the expected facts; duplicate upload (same idempotency key) → `"duplicate"`, no second job effect; invalid payload → job cancelled, warning logged, no records.
- [ ] **Step 2: Run** `mix test apps/backplane_memory/test/backplane/memory/workers/host_snapshot_worker_test.exs` — Expected: FAIL (`invalid_event` / module undefined).
- [ ] **Step 3: Implement** type registration, worker, store hook, docs section.
- [ ] **Step 4: Run** the test plus `mix test apps/backplane_memory/test` — Expected: PASS, 0 failures.
- [ ] **Step 5: Commit** `feat(memory): ingest host snapshots and apply them in a worker`

### Task 4: Host collector scheduler, config and spool emission

**Files:**
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/collectors/collector.ex` (behaviour)
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/collectors/command.ex` (runner)
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/collectors/scheduler.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/config.ex` (`parse_capture/3` gains `collectors`; `sample_yaml/1` documents it)
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/capture_supervisor.ex` (start Scheduler when `collectors.enabled`)
- Test: `apps/backplane_host_agent/test/backplane/host_agent/collectors/scheduler_test.exs`, `.../config_test.exs` (extend)

**Interfaces:**
- Produces:
  - `@callback collect(config :: map(), env :: %{runner: runner, os: :linux | :darwin | :other, home: String.t()}) :: [%{collector: String.t(), unit: String.t(), complete: boolean(), items: [map()]}]` — return `[]` when the collector is unavailable on this host (binary missing, wrong OS).
  - `Collectors.Command.run(cmd :: String.t(), args :: [String.t()], opts :: keyword()) :: {:ok, String.t()} | {:error, :not_found | {:exit, integer()} | :timeout}` — `System.find_executable/1` first; `System.cmd(..., stderr_to_stdout: false)` inside a `Task` with `opts[:timeout]` default `5_000` ms. `runner` in `env` has this signature.
  - `Collectors.Scheduler.start_link(opts)`, `run_once(server) :: %{emitted: n, unchanged: n}`.
- Config (`capture.collectors`, defaults): `enabled` = capture enabled; `interval_ms` 900_000; `initial_delay_ms` 60_000; `git: %{enabled: true, roots: [home], max_depth: 4, max_repos: 500}`; `docker: %{enabled: true}`; `services: %{enabled: true}` (systemd on Linux, launchd on macOS); `host: %{enabled: true}`; `state_path` = `<dirname(capture.db_path)>/collector_state.json`.

Scheduler: for each enabled collector module, `collect/2` → for each snapshot compute fingerprint (contract above); skip when equal to `state[collector <> ":" <> unit]`; else build the envelope (contract above; privacy map same as `Hooks.ClaudeCode`) and `spool_module.append(spool, envelope)`; on `{:ok, _}` or `{:duplicate, _}` update and persist state (write `state_path <> ".tmp"` then `File.rename/2`); on append error keep old state (retry next run). A collector that raises is logged with `Logger.warning` and skipped for that run. Collector modules list defaults to Tasks 5–7 modules and is injectable via `opts[:collectors]`.

- [ ] **Step 1: Write failing tests** with a fake collector module and the real `Spool.Turso` in a tmp dir (as `capture_runtime_test.exs` does): first `run_once` emits 1 event with the contract fields; second unchanged run emits 0 (Spec §8.7 "no re-report"); changed items emit 1; state survives Scheduler restart (still 0 emitted); append failure leaves state unchanged so the next run emits; a raising collector does not stop others; config parsing defaults + overrides.
- [ ] **Step 2: Run** `mix test apps/backplane_host_agent/test/backplane/host_agent/collectors/scheduler_test.exs apps/backplane_host_agent/test/backplane/host_agent/config_test.exs` — Expected: FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** the tests — Expected: PASS.
- [ ] **Step 5: Commit** `feat(host_agent): schedule host collectors and spool changed snapshots`

### Task 5: Git collector

**Files:**
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/collectors/git.ex`
- Test: `apps/backplane_host_agent/test/backplane/host_agent/collectors/git_test.exs`

**Interfaces:**
- Consumes: Task 4 behaviour and `env.runner`.
- Produces: `Collectors.Git` (`collector: "git"`, one snapshot per configured root; `unit` = expanded absolute root).

Walk each root to `max_depth` without following symlinks; a directory containing `.git` (dir or file) is a repo — record it and do not descend further. Skip directories whose name starts with `.` and `node_modules deps _build target vendor Library venv`. Per repo: `git -C <path> config --get-regexp ^remote\..*\.url$` → `Backplane.MemoryRepository.select_remote/1`; `git -C <path> symbolic-ref --short -q HEAD` (non-zero → `branch: nil`); `git -C <path> log -1 --format=%H%x1f%s%x1f%cI` (non-zero/empty → `head: nil`). Root missing or unreadable → no snapshot for that root. `git` not found → `[]`. Any walk error below the root or a git command error other than the documented non-zero cases → `complete: false`. More than `max_repos` repos → keep the first `max_repos` by path, `complete: false`.

- [ ] **Step 1: Write failing tests** using real `git init` repos in a tmp root (skip with `@tag :git` only if `git` is absent): repo with remote `https://user:ghp_token@github.com/o/r.git` → item `repository_id == "github.com/o/r"` and the token string appears nowhere in `inspect(snapshot)` (Review Focus 1); nested repo not reported; `node_modules`/dot dirs skipped; detached HEAD → `branch: nil`; empty repo → `head: nil`; missing root → no snapshot; `max_repos: 2` with 3 repos → 2 items, `complete: false` (Review Focus 5); fake runner returning `{:error, :not_found}` → `[]`.
- [ ] **Step 2: Run** `mix test apps/backplane_host_agent/test/backplane/host_agent/collectors/git_test.exs` — Expected: FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(host_agent): collect git checkouts`

### Task 6: Service collectors (docker, systemd, launchd)

**Files:**
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/collectors/docker.ex`, `.../collectors/services.ex`
- Test: `apps/backplane_host_agent/test/backplane/host_agent/collectors/docker_test.exs`, `.../services_test.exs`

**Interfaces:**
- Produces: `Collectors.Docker` (`collector: "docker"`), `Collectors.Services` (`collector: "systemd"` on `:linux`, `"launchd"` on `:darwin`, `[]` otherwise). `unit` = `"local"`.

Docker: `docker ps --format {{json .}}` → per line `name` (`Names`), `image` (`Image`), `state` (`State`, not `Status`), `ports` (`Ports` split on `", "`, sorted, empty → `[]`). systemd: `systemctl list-units --type=service --state=running --no-legend --plain --no-pager` → `name` = first column, `description` = remaining columns after LOAD/ACTIVE/SUB. launchd: `launchctl list` → skip header, `label` = third column, drop labels starting with `com.apple.`; PIDs and exit codes are ignored. Binary not found → `[]`; non-zero exit (daemon down) → `[]` (unavailable, never an empty complete snapshot).

- [ ] **Step 1: Write failing tests** with fake runners and recorded output fixtures: parsing; docker output differing only in `Status` ("Up 2 hours" vs "Up 3 hours") yields identical snapshots (Review Focus 4); launchd output differing only in PIDs yields identical snapshots; docker non-zero exit → `[]` (Review Focus 2).
- [ ] **Step 2: Run** `mix test apps/backplane_host_agent/test/backplane/host_agent/collectors/docker_test.exs apps/backplane_host_agent/test/backplane/host_agent/collectors/services_test.exs` — Expected: FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(host_agent): collect docker containers and system services`

### Task 7: Host info collector

**Files:**
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/collectors/host_info.ex`
- Test: `apps/backplane_host_agent/test/backplane/host_agent/collectors/host_info_test.exs`

**Interfaces:**
- Produces: `Collectors.HostInfo` (`collector: "host"`, `unit: "local"`, exactly one item).

`hostname` from `:inet.gethostname/0`; `os` = `uname -sr` output (fallback `:os.type/0` inspect); `addresses` from `:inet.getifaddrs/0`, excluding loopback, IPv4 `169.254.0.0/16`, IPv6 `fe80::/10`, sorted strings; `listening`: Linux `ss -ltnpH`, macOS `lsof -nP -iTCP -sTCP:LISTEN` → unique `{port, process}` sorted by port then process; command failure → `listening: []` and `complete: false` (`addresses`/`os` still reported).

- [ ] **Step 1: Write failing tests** with fake runner/fixtures for both OSes: parsing; same ports in different order → identical snapshot (Review Focus 4); duplicate IPv4/IPv6 listeners on one port collapse to one entry; failure path → `complete: false`.
- [ ] **Step 2: Run** `mix test apps/backplane_host_agent/test/backplane/host_agent/collectors/host_info_test.exs` — Expected: FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** — Expected: PASS; then `mix test apps/backplane_host_agent/test` — 0 failures.
- [ ] **Step 5: Commit** `feat(host_agent): collect host info and listening ports`

### Task 8: Live verification (controller)

- [ ] Start the dev gateway (`elixir --sname bpgw -S mix backplane.run`, Postgres.app) and a dev host agent whose config has `capture.collectors.git.roots: [<tmp root>]`, `interval_ms: 30000`, `initial_delay_ms: 1000`.
- [ ] `git init` a repo with a remote in the tmp root → within one interval a `host.snapshot.collected` event and `git_checkout` fact (`writer host_collector`, `host_id` = agent host) exist (spec §8.7).
- [ ] Next interval with no change → no new event (spool `captured_count` unchanged, no new `bpm_events` row).
- [ ] Remove the repo → its facts `forgotten`; `memory::search` default results no longer return them.
- [ ] Set `git.enabled: false`, restart → nothing forgotten.
- [ ] Gate: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`, memory + host_agent suites, `mix run --no-start test/ci_workflow_test.exs`.
