# Memory local development runbook

Status: **local L01–L18 accepted; source CI green; Memory qualification passed; release command verified locally; final CI/publication pending**.
The evidence levels and retained failures are in [acceptance](local-e2e-acceptance.md).

The local stack remains running: public `http://localhost:4220`, Admin
`http://localhost:4221/memory`, host A4222 and host B4223. Memory opens directly;
source host and repository are optional filters. The browser shows264 memories
(255 primary/9 isolated). Original B uses `.devenv/memory-local-isolated`;
temporary B and the owned relay are stopped. Both hosts' actual direct/MCP health
is online/canonical/stalefalse/pending0.

Test-count correction: historical1413/0 and1394/0 runs loaded two files with
one shared ExUnit module name. Those counts are retained observations, not proof
of unique coverage. Task72 repairs the registration and reruns both suites; see
the final verification section for the corrected count. Current corrected
results are21/0 for both files together and1394/0 (5 excluded) for all178 Memory
files; see the acceptance report's Task72 Astra4 section.

A20 passed Memory1413/0 (5 unchanged exclusions), Admin134/0, focused39/0,
scoped quality and strict dev compilation; actual gateway cold restart loaded it.
Task127's supported audited exact16 retry completed through normal gateway workers.
Independent data/history/audit checks passed. Two new normal scheduler jobs were
separately reviewed, both completed attempt1/errors0; original failed reports and
error histories remain intact. Eleven historical provenance additions are
attributed, not described as byte-identical rows. L18 is accepted from the retained
composite repeat/restart/recovery evidence; no cross-machine validation occurred.
The preceding pool is exhausted. The newly authorized five-round pool allocates
four rounds to Task72 registration/browser compatibility, Relayixir observation and the release compile scope, with1 unallocated; prior counters are retained.
Stages04Sol2/Astra20 ceiling21; Task127 instrumentationSol1/2 consumed no product round. See [the checklist](local-dev-checklist.md#current-resume-boundary-2026-10-21-authorized-continuation).
The nine-app selective attempt at307b04cd was cancelled. Subsequent main
3be889c3 prepared full1.10.28 alongside Auth#73; preserve that newer release plan.
Release39560571890 at4ec9bd95 passed Memory qualification and all four host-agent
builds, but both Backplane builds failed the new Admin metadata refresh command.
Task30 repairs only its compile scope, verified by25 release tests,8 workflow
contracts and an actual production warm compile/metadata check; publication remains pending, with no gate waived.

Use the status above and the acceptance report for the current outcome. Earlier
probe observations below retain their original evidence boundaries; a historical
subset failure or pending gate does not override the accepted composite. Never
repeat a consumed one-time repair or restore an old topology from a report.

## Latest verified local recovery commands

The retained oct20-a stack has passed cold host-first automatic join, current
Crystal revision repair, targeted projection rebuild/checkpoint and local capture
policy restoration. The retained repeated workflow now has composite local acceptance: consult
[the acceptance matrix](local-e2e-acceptance.md) for current gates; older failed
runs below remain historical evidence.

Run these only with exclusive ownership of the recorded fixture lifecycle and
without another Mix/build/live probe running. The policy probe keeps the gateway
alive; the host-first probe deliberately stops both owned services, starts the
host first and restores a healthy stack. Use a fresh case ID after any prior run.

```sh
uv run scripts/memory_local_policy.py --case-id l09-capture-policy-001
python3 scripts/memory_local_host_first.py --case-id l01-host-first-002
```

Those exact cases already ran successfully; choose new suffixes to repeat.
Reports live under `.devenv/memory-local-evidence/oct20-a/capture-policy-*` and
`host-first-*`. Exact original YAML bytes and store identities are preserved;
reports include owner ACK and canonical exact-once evidence after negotiation.
Do not request protected owner diagnostics before the host has negotiated its
partition. Empty-schema stats takes `{}`, without scope or agent arguments:

```sh
curl --silent --show-error --json '{}'   http://127.0.0.1:4222/memory/memory-local-oct20-a/call/stats
```

The paired negative-error probe is available as
`python3 -B scripts/memory_local_negative_parity.py --case-id negative50-002`.
It creates/forgets only its own synthetic marker and verifies owner ACK. Actual
case002 passed all8 error pairs after the routing11 host restart, including
unknown-method and idempotency-conflict meaning. It preserved20 pre-existing
active IDs. Use a fresh case ID for a new run; retain original failed reports.
The local Memory-specific unknown-method response does not change generic Hub
forwarding. Later credential-revocation probes qualified existing/warm/cold
rejection; see the acceptance report for the remaining shared offline gates.

Never run `mix memory.projections.rebuild` beside a live gateway: the task calls
app.start and would start duplicate gateway/Styx supervisors. The verified current
R2 rebuild used `Backplane.Memory.Projections.Rebuild.session/2` from a minimal
`mix run --no-start --no-compile` controller starting only Repo and required
libraries, followed by the read-only governance checkpoint. Its execution log is
`oct20-a/governance42-005-r2-rebuild.log`; this is function execution, not CLI proof.

## Environment and tested preparation

Run from the repository root. Use the full supported shell, including its compiler
environment, rather than adding only `.devenv/profile/bin` to PATH.

```sh
devenv shell -- elixir --version
devenv up postgres
```

The PostgreSQL command stays in the foreground. The project cluster uses the
socket `/tmp/devenv-e733526/postgres`; it is separate from any system PostgreSQL
server. Never reset or remove an existing developer database.

In another shell, the following command was tested successfully:

```sh
devenv shell -- sh -c 'MIX_ENV=test mix ecto.migrate'
```

The verified environment is macOS arm64, Elixir 1.18.5, OTP 28.5.0.6,
PostgreSQL 17.11, Rust/Cargo 1.95.0, and Nix clang 21.1.8.

An earlier mixed Rust/system-linker build produced an unloadable `ex_turso` NIF.
The following full-shell rebuild resolved that failure without dependency patches:

```sh
devenv shell -- sh -c 'MIX_ENV=test mix deps.compile ex_turso --force'
devenv shell -- elixir -pa _build/test/lib/ex_turso/ebin -e 'IO.inspect(Code.ensure_loaded(Turso.Native))'
```

The loader returned `{:module, Turso.Native}`. This verifies the test build;
the development stack subsequently cold-started successfully. Later cold-start,
outage and recovery evidence closes local startup acceptance in the current report.

## Lifecycle CLI

Copy [the nonsecret host template](examples/host-agent.local.yaml.example) to a
gitignored `.devenv` path. It requires a separately registered host identity and
host credential, a nondefault bound scope matching its entitlement, and absolute
paths for three different stores: commands, capture spool, and edge mirror.
Registration and fixture provisioning passed for the retained oct20-a fixture; see local-setup.log.
The template's plaintext mirror opt-in is for supported local development only.

The configuration-only fixture script prepares two registered hosts, exact
partitions, separate private store paths, an OpenRouter route and a distinct
gateway resource credential. It requires `OPENROUTER_API_KEY` in the environment;
it never prints the secret. Apply development migrations before running it:

```sh
devenv shell -- mix ecto.migrate
MEMORY_LOCAL_RUN_ID=oct20-a devenv shell -- mix run --no-start scripts/memory_local_setup.exs
```

Both commands passed for `oct20-a` (`dev-migrate.log`, `local-setup.log`).
Setup writes the manifest
under `.devenv/memory-local-fixtures/oct20-a/fixture.json`, the primary host config
under `primary/host.yaml`, and the resource bearer in private `resource-token`.
Setup creates configuration and identities only, never final memories or worker
outputs. Use a new run ID for a separate fixture; reuse it for delivery retries.

After the indexed-client-credential upgrade, do not reuse a legacy resource
bearer or rerun full fixture setup merely to repair authentication. For an existing
fixture, stop the owned services, retain a supported PostgreSQL process, apply
migrations, then use the bounded cutover entrypoint:

```sh
MEMORY_LOCAL_RUN_ID=oct20-a devenv shell -- mix run --no-start scripts/memory_local_resource_cutover.exs
```

This entrypoint starts Repo, PubSub, the client authorization supervisor and the
credential vault with their runtime libraries; it does not start gateway jobs.
It requires the existing matching private fixture and client identity. Valid issued
credentials are retained; an active legacy fixture client with no issued digest
receives a server-issued replacement while keeping its ID and scopes. The encrypted
vault update is transactional. The private0600 token file is published atomically
after commit; retry repairs a failed file publication without another rotation.
Inactive identities and unavailable/mismatched issued credentials are refused.
Host YAML, provider keys, settings and unrelated clients are outside this operation.

A historical local Memory migration collided with the published auth version
`20261020000001`. The published auth migration stays unchanged; forward migration
`20261020000007` reconciles the old hash-only schema or validates an already indexed
schema. Historical Memory migration coverage uses a test fixture. Do not edit
migration receipts, reset the database or recreate Memory tables. Stop if schema
validation rejects an unexpected shape. Actual cutover verification is tracked in
[the acceptance checklist](local-dev-checklist.md).

The CLI supports these commands. Gateway and host restarts passed; the retained
repeat/restart/recovery composite now closes local L18. Commands that stop or
restart services require exclusive ownership of the fixture lifecycle:

```sh
python3 scripts/memory_local_dev.py start --config .devenv/memory-local-fixtures/oct20-a/primary/host.yaml --host-first --timeout 180
python3 scripts/memory_local_dev.py status
python3 scripts/memory_local_dev.py service gateway stop
python3 scripts/memory_local_dev.py service gateway start --timeout 180
python3 scripts/memory_local_dev.py service host restart --timeout 180
python3 scripts/memory_local_dev.py stop
```

Start launches `devenv up` and a separate `devenv shell` running `mix agent.run` from `apps/backplane_host_agent`, sets
`BACKPLANE_HOST_AGENT_CONFIG` for the host, waits for bounded HTTP readiness, and
records private logs and process ownership under `.devenv/memory-local/`.
It refuses occupied public/Admin/host ports or an existing recorded stack.
Stop validates PID, process group, user and kernel process birth identity before
signaling. An ownership mismatch retains state and refuses termination. Inspect
the recorded processes instead of deleting state and adopting unrelated services.
Per-service operations use the same identity checks and preserve the peer service
and existing stores. They are intended for bounded outage/restart acceptance;
stopped records remain explicit, and occupied replacement ports are rejected.
The current harness passed 26 synthetic lifecycle tests. A real bounded host cycle removed all four original host processes, preserved the gateway process identity and restored all three endpoints; see oct20-a/harness-host-cycle-bounded-1792434510816315000.json. Earlier failed lifecycle probes remain in the acceptance report.

For a second local host beside the existing gateway, use a separate state directory
and its fixture's dedicated port/configuration:

```sh
python3 scripts/memory_local_dev.py --state-dir .devenv/memory-local-isolated start --host-only --config .devenv/memory-local-fixtures/oct20-a/isolated/host.yaml --host-port 4223 --timeout 180
python3 scripts/memory_local_dev.py --state-dir .devenv/memory-local-isolated status
python3 scripts/memory_local_dev.py --state-dir .devenv/memory-local-isolated service host restart --timeout 180
python3 scripts/memory_local_dev.py --state-dir .devenv/memory-local-isolated stop
```

`--host-only` checks and owns only its host endpoint/process, never adopts or stops
the gateway, and rejects `--host-first`. Synthetic lifecycle tests cover host
restart/stop beside a gateway with unchanged process identity. The second real
host was started successfully in this mode using a private alternate
`isolated/host-relay.yaml` config; `fixture-relay.json` points to that config.
Its online relay4224 forwards to gateway4220 while local API4223 stays independent.
That relay topology and its first two failed shared runs are historical. The
current original isolated host runs directly beside the gateway; the temporary
relay is stopped. Later independent-capability, lease/revoke and cold-closure
evidence closes the local L13 composite.

The preparation-only foreground PostgreSQL process must be stopped through its
own controlling session before transferring lifecycle ownership to this CLI.
Do this only after database-dependent tests finish; do not terminate another
developer's database process.

Required URLs after a successful start are:

- Public gateway: `http://localhost:4220`
- Admin Memory: `http://localhost:4221/memory`
- Host loopback API: `http://127.0.0.1:4222`

These URLs serve the retained synthetic fixture. Local L01–L18 have accepted
evidence at the levels in the current acceptance report; release remains blocked. The trusted Admin
surface, gateway resource bearer and host token are separate authentication boundaries.

## Repeatable API workload

The provider and synthetic workload phases have executed against the actual
stack; see the acceptance report for individual outcomes and remaining gates:

```sh
python3 scripts/memory_local_acceptance.py provider --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json
python3 scripts/memory_local_acceptance.py workload --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json
```

To repeat the accepted L07 queries without creating new fixture memories, run:

```sh
python3 scripts/memory_local_acceptance.py recall --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json
uv run scripts/memory_local_browser.py --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json --recall-report .devenv/memory-local-evidence/oct20-a/api-recall-1792438285143881000.json
```

Replace the report argument with the path printed by the preceding API command.
The shown report is the retained successful run. The recall phase discovers
expected IDs through the fixture's supported `list` API and checks exact and
paraphrased queries through direct HTTP and MCP. It requires online V2 traces,
successful vector retrieval, an expected hit, a 2048-token budget and a finite
duration below 15 seconds. It compares selected IDs when the preference inventory
is unchanged. The browser checks the twelve Memory pages and all four matching
trace pages, including query, partition, selection, exclusions, typed provenance
and budget. It records the displayed embedding model; automatic comparison to an
expected model occurs only when the input case supplies `query_embedding_model`.
The API phase does not independently verify stored vector labels. These checks
remain subsets of L01–L18 acceptance.

Individual phases are `discover`, `write`, `capture`, and `inspect`. Writes use a
stable idempotency key. Capture sends a synthetic Codex session lifecycle with
four independent sessions, stable source IDs, and repeated delivery of each
event to check deduplication. The `provider` phase first requires unauthenticated
gateway rejection, then verifies real structured chat and a 2560-dimension
embedding with the private resource bearer. It stores no bearer or vector body.
Inspect
waits for canonical settlement and checks useful recall through the host facade.
Each invocation saves bounded synthetic request/response observations under
`.devenv/memory-local-evidence/<run-id>/api-*.json`, including failed observations.
Capture through this driver is adapter evidence; it does not prove a real CLI
hook ran. Provider, browser, governance, outages and complete L01–L18 evidence
remain separate required checks.

The real runtime probe executed an actual synthetic Claude session; its four
hook receipts were correlated with canonical events:

```sh
python3 scripts/memory_local_runtime.py --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json
```

It runs one synthetic Claude session with repository SessionStart,
UserPromptSubmit, Stop and SessionEnd hooks, isolated configuration and activation
directories, no tools or MCP servers, and a $0.10 provider budget. It uses the
available OpenRouter credential only through the child environment. Hook receipts
must subsequently correlate with canonical events; the script does not promote
invocation alone into successful capture or full acceptance.

The browser driver uses an isolated headless installed Chrome through a pinned
Playwright package in uv's transient environment:

```sh
uv run scripts/memory_local_browser.py --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json --observe-write
```

It visits the selected partition's operator pages, waits for actual LiveView
connection, saves viewport screenshots/text, and checks page errors. The optional
write probe opens Memories first, writes through the real host facade, then
requires the new row within five seconds without reloading. The clock starts
before durable host acceptance, so a passing observation includes transport and
canonical settlement time. Actual twelve-page runs and a2328ms open-page write
observation passed. This command covers one subset; later cross-page and edge
scenarios are assessed separately in the accepted L08/L17 composite.
Reports live under the same run's `browser-*/` directory.

Capture a bounded, read-only canonical snapshot with:

```sh
python3 scripts/memory_local_evidence.py --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json
```

This command passed against the prepared development database before startup:
all fixture event, projection, artifact and job collections were empty. It uses
read-only transactions, statement timeouts and explicit field/row limits. The
snapshot includes source IDs, stage revisions, actual model and embedding markers,
artifact content and evidence links, without raw envelopes, credentials or provider
errors. A snapshot supports correlation; it cannot alone establish that normal
background execution produced an artifact. `--host-index 1` selects the isolated
fixture, and `--socket` overrides the local devenv socket.

## Verified focused regressions

```sh
python3 -W error::ResourceWarning -m unittest discover -s scripts/tests -p test_memory_local_dev.py
devenv shell -- sh -c 'cd apps/backplane_host_agent && mix test test/mix/tasks/agent_run_test.exs test/backplane/host_agent/worker_test.exs'
devenv shell -- mix test --no-start apps/backplane_memory/test/backplane/memory/config_test.exs apps/backplane_memory/test/backplane/memory/llm_test.exs apps/backplane_memory/test/backplane/memory/graph/graph_extract_worker_test.exs apps/backplane_memory/test/backplane/memory/memories/search_expansion_test.exs apps/backplane_memory/test/backplane/memory/expand_query_test.exs
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/live/memory_memories_live_test.exs
```

Observed early totals:11 Python safety tests (latest harness recovery18),27 startup tests,46 LLM/graph/search
tests, and 4 inventory LiveView tests passed. Decay tests separately passed 8
tests. Provider tests use `Req.Test`; LiveView tests use ExUnit, not a browser.
Run shared Mix builds serially. Formatting, broader suites, real providers,
actual Styx execution, and L01–L18 remain required.

See [the acceptance report](local-e2e-acceptance.md) for evidence boundaries and
[the checklist](local-dev-checklist.md) for ownership and resumption instructions.

### Operator browser observations

```sh
uv run scripts/memory_local_operator.py --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json
```

To inspect a different captured session, pass its exact ID. This command was
also tested against the retained completed quality session:

```sh
uv run scripts/memory_local_operator.py \
  --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json \
  --session memory-local-oct20-a-quality-1792479580117825000
```

This operates the selected session consolidation button twice, captures returned revision/artifact identities, follows rendered evidence links while retaining selection, and opens an unknown-session detail. It does not establish all L06/L08/L17 gates. Reports are private under the run evidence directory.

For an explicit summary repair, use **Memory → Overview → Repair operations**
on the trusted Admin surface. Supply the selected exact memory space, host,
client, scope, namespace and session; choose `summary` and use a stable unique
idempotency key. Host channels grant `memory.read`/`memory.write`, while
`memory::heal` requires `memory.admin`: invoking it through the local host MCP
correctly returns unauthorized. The generic `hub unreachable` wrapper does not
make that permission denial a transport outage. Do not broaden host privileges
to run an operator repair.

### Retained early processing-profile observation

The four originally enabled gates were temporarily paused to contain repeated
model calls. After the scoped stage recovery and completed L16 policy run, actual
browser controls restored `memory.pipeline.enabled`, `memory.events.enabled`,
`memory.events.dual_write`, and `memory.relation_classifier.enabled` to true.
Persisted values were verified in `oct20-a/pipeline-restored-persistence.json`;
browser report/screenshots are in `oct20-a/pipeline-restore-1792436898537150000/`.
This is restoration evidence, not a complete L09 pass. Terminal graph response
failures remain; no new graph/window jobs appeared across two normal scheduler
ticks after exhaustion. V2 trace persistence and useful recall now pass. Existing
data is inspectable.

The host launcher now executes the owning app task through
`devenv shell -- sh -c 'cd apps/backplane_host_agent && exec mix agent.run'`.
The harness captures separate descendant process groups, validates kernel birth
identity and every live group member, and refuses ambiguous ownership. A dead
legacy launcher without persisted descendant provenance cannot establish ownership
of detached survivors. Run lifecycle operations through the harness and inspect
retained state on refusal; do not kill by port alone.


## Current retained fixture and containment

The current fixture is `oct20-a`: primary host
`aab0c6fe-2f0d-459a-ad72-0e6adab53755`, space
`fd3a7e13-ce64-675f-d1fe-9cbe070bf6b6`, scope
`memory_local_oct20-a_primary`, namespace `private`. Open
http://127.0.0.1:4221/memory directly; host and repository are optional source filters, not setup. Public gateway is
http://127.0.0.1:4220 and the loopback host API is http://127.0.0.1:4222.
The separate isolated fixture on4223 is running as an independent local host, with its own lifecycle state under `.devenv/memory-local-isolated`. Inspect current ownership and
readiness with `python3 scripts/memory_local_dev.py status`; current private log
paths are recorded in `.devenv/memory-local/state.json`.

The original four pipeline/events/dual-write/graph policies are now restored to
true through the supported UI. Forward migration00002 repaired trace persistence.
The bounded12second retrieval deadline and pinned same-model filtering now pass
actual direct/MCP exact/paraphrase recall with matching UI traces. These are the original restoration/recall observations. Later outage recovery,
graph/Crystal quality and remaining local cases passed at the evidence levels in
the current acceptance report. Follow the checklist before further fault cases;
avoid setup as a repair shortcut.


## Scheduled policy qualification (L16)

`scripts/memory_local_policy.exs` is a bounded controller against an already
running stack. It starts the configured timezone prerequisite, Repo and an
independently named Styx scheduler with **no queues**. Normal Cron timers insert
the sweep/retention jobs; existing gateway queues execute them. The controller
never performs workers directly or changes Settings.

Use a fresh marker/output for a new run. Pause the master pipeline through the
existing UI first and retain its original value; the script requires quiet
memory queues and refuses eligible nonfixture Lessons or expired nonfixture
activity. Supply `--protect-fixture-lesson` only for explicitly verified synthetic
candidate/active/disputed controls in the exact partition. The script checks
identity/provenance before touching their eligibility clocks. Restore the original
policy after the bounded run. Actual source Lessons are created through host HTTP;
only synthetic eligibility clocks and activity INPUT rows are fixture setup.

The tested base invocation is:

```sh
devenv shell -- env MIX_ENV=dev mix run --no-start --no-compile scripts/memory_local_policy.exs \
  --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json --run oct20-a \
  --marker NEW-UNIQUE-MARKER --gateway-state .devenv/memory-local/state.json \
  --database backplane_dev --output NEW-EXCLUSIVE-OUTPUT.json --preflight-only \
  --protect-fixture-lesson VERIFIED-SYNTHETIC-LESSON-UUID
```

Remove `--preflight-only` only after its read-only checks pass; use another fresh
output path. Guards deliberately stop instead of changing unrelated data. A
failed pre-job run may use `--resume-from FAILED-REPORT.json` with the original
marker/controls and a new output. Resume requires the same UTC day and unchanged
service, target, control, activity and nonfixture snapshots, and no prior jobs;
it skips all API/setup writes. It is not a general retry after jobs have run.

Retained successful evidence is `oct20-a/l16-live-001-resume-astra1.json`:
Cron523/524, gateway decay525 and retention continuation526 completed, with
unchanged nonfixture hashes and service identities. The scheduler and its peer
were removed. **Do not rerun its marker**: the successful jobs/inputs are retained
for inspection. Current pipeline policy has already been restored to true.

## Pending restart and online-core subset checks

Both drivers now have passing real local subset runs after the user authorized
additional repairs. Preserve their earlier failed reports as historical evidence.
Current counters are Task29Sol4 and Task31Sol3; complete restart/governance and
repeatability scenarios remain separate. Use fresh case/output names.

```sh
python3 scripts/memory_local_pending_restart.py \
  --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json \
  --state-dir .devenv/memory-local --case-id NEW-LOWERCASE-CASE
python3 scripts/memory_local_core_parity.py \
  --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json \
  --case-id NEW-LOWERCASE-CASE --timeout 180 --cleanup-timeout 40 \
  --output .devenv/memory-local-evidence/oct20-a/NEW-OUTPUT.json
```

Replace uppercase placeholders with fresh lowercase IDs before invocation.
The restart driver intentionally changes only two dedicated YAML intervals,
stops/restarts only the owned primary host and restores the exact config bytes.
The earlier attempt stopped before mutation because independent SQLite readers
cannot inspect stores held by the running Turso owner. The corrected driver uses
bounded loopback `/memory/diagnostics` owner reads while live, and independent
reads only after verified shutdown. The actual `local-resume-l11-002` run passed:
pending command/capture and existing active mirror survived; normal sync settled
once and original configuration was restored. Positive tombstone survival and
interrupted snapshot visibility were not exercised. Keep the three primary
stores' verified0600 modes; do not bypass locks or copy live WAL state as evidence.

The online-core driver creates one uniquely marked record, checks discovery,
retry identity, canonical settlement, accepted fields, list/stats, two real-vector
recalls, and canonical forget. Its first real run failed a forget receipt assertion
without retaining the initial receipt. The corrected `core31-local-resume-002`
run passed, including actual provisional localID+known canonicalID receipts,
canonical deletion ACKrevision62, both lists absent and baseline11IDs preserved.
Tool receipts and cleanup boundaries are now retained before semantic assertions.

For both drivers, exact artifacts, successful observations and remaining gates
are in [the acceptance report](local-e2e-acceptance.md). The separate
[shared-access design](shared-host-access-design.md) defines the approved independent
read/deliver/remember/forget capabilities. Later source integration and local
two-host evidence close the L13 composite; these earlier driver runs cover only
their documented subsets. Historical product-choice blockers are superseded.

## Release boundary

Local L01–L18 acceptance is recorded; required broader CI gates remain red.
The task source/docs and release support are committed and pushed to main. See
[the acceptance report](local-e2e-acceptance.md) for evidence and limitations.
Do not dispatch a release until every required gate passes on the exact main SHA.
A pushed commit alone does not release these changes.

The [release workflow](../../.github/workflows/release.yml) accepts a strict
semantic version and refuses dispatch outside `refs/heads/main`. Memory V2
qualification resolves one immutable main SHA for all downstream artifacts and
publication. The six platform builds and installed-release migration/idempotency
smoke remain required before GitHub publication. Publication does not establish a
successful deployment or complete local acceptance.

Task30 adds optional `release_apps`, default `all`. The default preserves the
existing unified root/app versioning, all four Hex publications, and Docker
publication. An explicit comma-separated runtime app list instead versions the
root and only those app manifests, skips the entire Hex matrix, and retains
Docker publication after successful GitHub publication. A failed full-release
Hex job still blocks Docker. The explicit list must contain
`backplane_host_agent` for its integration-copy directory and cannot contain
`backplane_agent_runtime`, `backplane_ai_protocol`, `backplane_skill_protocol`, or
`backplane_mcp_protocol`; selective Hex publication is not supported.

The underlying version script accepts `VERSION [all | APP ...]`; omitting the
selection preserves the legacy full behavior. It validates every selected
manifest and applicable example before writing. MCP install examples change only
when the MCP package is selected (including full mode). Versioning tests use
temporary copied-manifest fixtures. No real root/app manifest version changed
and no release version was selected. The release support is now committed and
pushed; no publication occurred for Task30.

The following is the historical selective delivery recipe from Task30,
**not the current1.10.28 plan or executed release evidence**. Main3be889c3 later
prepared a full release, including Hex, and the current release must preserve
that authoritative plan. The selective mode remains available for future scoped
delivery after its own version and CI qualification:

```sh
memory_release_version='REPLACE_WITH_UNUSED_SEMVER'
gh workflow run release.yml --repo gsmlg-opt/backplane --ref main \
  -f version="$memory_release_version" \
  -f release_apps='backplane_admin,backplane_api,backplane_host_agent,backplane_llama,backplane_mcp,backplane_memory,backplane_memory_contract,backplane_skills,backplane_system'
gh run list --repo gsmlg-opt/backplane --workflow release.yml
gh run watch REPLACE_WITH_RUN_ID --repo gsmlg-opt/backplane --exit-status
gh release view "v$memory_release_version" --repo gsmlg-opt/backplane
```

Inspect the exact run/SHA, six archive/checksum pairs, qualification and installed
migration artifacts, and Docker tags/digest before claiming delivery. GitHub
publication can succeed before a later registry job fails. Remote version
availability and release credentials have not been verified. New local runbooks
and acceptance notes are source deliverables; the existing workflow does not
explicitly attach them to the release.

Task30 focused verification passed with these exact commands:

```sh
devenv shell -- mix run --no-start --no-compile test/release_config_test.exs
devenv shell -- mix run --no-start --no-compile test/ci_workflow_test.exs
devenv shell -- mix format --check-formatted test/release_config_test.exs
bash -n scripts/set-version.sh
git diff --check -- scripts/set-version.sh .github/workflows/release.yml test/release_config_test.exs
```

Results were 22 release-configuration tests and 8 CI-workflow tests, all passing;
formatting, Bash syntax, and scoped whitespace checks also passed. Coverage
includes byte preservation of unselected manifests/examples, invalid selections
failing before writes, the actual input-gate shell, and 64 Docker condition
combinations. The `--no-compile` checks do not establish a fresh source build.
Evidence is under `.devenv/memory-local-evidence/` in
`release30-final-release-config.log`, `release30-ci-workflow.log`, and
`release30-final-format-check.log`; the three-file implementation patch is
`release30-selective-release.patch`. Full GitHub Actions validation,
cross-platform builds, and actual publication remain unrun.


## Bounded embedding provider failure and recovery

The retained fixture's dedicated embedding route can be qualified separately
from structured LLM stage recovery:

```sh
uv run scripts/memory_local_provider_recovery.py --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json --timeout 180
```

Before invoking, confirm that no EmbedWorker jobs are runnable and prevent new
writes during the brief fault window. The selected Memory embedding model is
global: another consumer using this same route could otherwise see the fault.
The script requires the exact fixture-owned provider, model, credential reference
and partition. It uses the actual Embedding Providers edit form to append a
fixture-specific nonexistent path on the original OpenRouter origin. It changes
only `base_url`, never the secret, enabled flags, model or Memory Settings.

Two healthy baseline requests precede two fault-phase direct/MCP exact recalls.
The fault must leave online FTS results useful while vector retrieval reports an
error. A `finally` block restores the captured URL through the same UI and checks
every form field, then four exact/paraphrase recalls must use successful actual
vectors. Six matching browser trace inspections verify query, partition, model,
channel state, token budget and selected provenance. Provider screenshots mask
credential/header/metadata controls and crop out unrelated inventory.

The tested run exited 0 in 66.6 seconds:
`oct20-a/provider-recovery-1792438953211579000/report.json`. A restoration failure
is reported as `RESTORATION_NOT_PROVEN`; restore the dedicated provider before
other work. Normal errors, interrupts and SIGTERM invoke restoration; forced
process death cannot execute cleanup. The script reports embedding/recall L15
subset only. It does not prove invalid structured LLM output or asynchronous
stage recovery, and does not infer an upstream HTTP status from `provider_error`.


## Supplemental test qualification

The following exact commands passed. They use the test database and synthetic
fixtures/injected providers or manual drain/rebuild/notifications; they do not
replace actual dev API/provider/browser acceptance. Both CI profiles are
explicitly non-authoritative for performance.

```sh
devenv shell -- env MIX_ENV=test mix memory.qualify --profile ci --report .devenv/memory-local-evidence/memory-qualify-ci-22.json
devenv shell -- env MIX_ENV=test mix memory.eval --profile ci --report .devenv/memory-local-evidence/memory-eval-ci-22-repair1.json
devenv shell -- env MIX_ENV=test mix memory.replay.browser_qualify --browser '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' --report .devenv/memory-local-evidence/memory-replay-browser-22.json
```

Use new report names for a rerun to retain the original evidence. The acceptance
report explains initial failures, the fixture-policy/model corrections and the
unresolved initial partial-ingestion observation. The test qualification runner
restores exact prior policy cache entries on success or error and rejects
incomplete measured/warmup ingestion; it does not alter dev Settings or relax
thresholds. Required real-world scenario failures continue to block delivery.

## Request-scoped query failure and new partition discovery

Serialize these browser runs with Mix/build checks and development code reloads.
The retained primary fixture must have more than 25 memories matching `e`.

```sh
uv run scripts/memory_local_query_failure.py --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json
uv run scripts/memory_local_partition_appearance.py --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json
```

The query driver changes only its private browser's existing pagination link to
send a NUL-bearing bound search parameter through a normal LiveView patch. It
requires the readable query-error state and restores the exact original URL,
filter, second page and selected detail in `finally`. The tested run passed:
`oct20-a/query-failure-1792440199352130000/report.json`, error visible in168ms,
restored in121ms, no document replacement or browser errors. Sanitized gateway
correlation recorded PostgreSQL22021/invalid text bytes. This is corrective-filter
recovery, not automatic recovery from a transient outage with unchanged filters.
It never locks a shared table or cancels another request.

The partition driver registers exactly one retained synthetic host through the
Admin Add Agent form; each invocation creates a different host and empty private
space. It does not read the newly displayed token, capture that page, change
Settings or start another host process. It inspects the discovered choice in a
separate tab and preserves the original documents/filter/page/detail. The tested
run exited1: Sessions discovered the new choice in1106ms, but Memories did not
discover it within8seconds. See
`oct20-a/partition-appearance-1792440135394320000/report.json`. Do not report full
L17 success. DOM discovery includes collapsed menu links; visibility is tested
after ordinary menu expansion. Initial harness failures remain in evidence.

## Negative host-sync protocol probes

Run `bun test scripts/tests/memory_local_protocol_denial.test.ts` for the isolated
safety contracts. For real execution, inspect
`bun scripts/memory_local_protocol_denial.ts --help` and generate its exact private
offline-proof schema from current observations. Stop only the fixture's isolated
host through its owned lifecycle workflow first; never replace an existing host
connection with this probe. Verify the recorded isolated process and descendants
are gone, its local port is closed, Admin shows it Offline, and primary/gateway
process identities are unchanged. The proof expires after120seconds.

```sh
bun scripts/memory_local_protocol_denial.ts \
  --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json \
  --offline-proof .devenv/memory-local-evidence/oct20-a/protocol25-offline-proof.json
```

Do not reuse the retained proof: regenerate it after performing the checks.
The driver independently rechecks port4223, sends only two negative sync requests,
and closes its socket in `finally`. Inspect the new private report path printed
by the command. Then confirm isolated Offline/port closed and primary/gateway
identities and readiness again. A protocol-subset pass does not establish
same-space grants, revocation or facade cache suppression, and never sets full
L13 acceptance to true.

## Latest local provenance and Graph observation

The source recovery and actual browser inventory now pass:37 rendered links
retain exact selection and immutable summary IDs, including historical R1/R2.
The retained new-event Graph probe initially failed on real provider edge target
references; its report remains failed. One subsequent supported Admin retry
completed GraphExtractWorker1868 at the same R3, with already-open Graph/Pipeline
updates1532/2179ms and unchanged source/artifact/tombstone guards. This is explicitly
operator-assisted recovery. The old capture ACK is unavailable after its receipt
observation window; no new capture/transport pass is inferred from missing rows.

Executed commands, for this retained fixture only:

```sh
uv run --with playwright==1.56.0 python .devenv/memory-local-fixtures/oct20-a/link_inventory.py
uv run --with playwright==1.56.0 python .devenv/memory-local-fixtures/oct20-a/open_graph_pipeline_retry.py --case-id graph-pipeline-retry-002 --timeout 300
python3 scripts/memory_local_dev.py status
```

The private retry is a one-time observer of the recorded failed R3 state. It
refuses an existing case journal or a graph that is no longer dead-lettered; do
not rerun a successful case or fabricate its preconditions. These private probes
supplement the reusable repository harness, not a new general API.

The historical snapshot `oct20-a/final-ui-1792489077418423000/report.json` verifies all3
endpoints, host online/canonical/pending0 and isolated4223 stopped. The healthy
owned gateway/host remain running (PIDs92541/83706 at that snapshot). Inspect the
actual state file before any lifecycle action; PIDs are not durable identities.
Open the exact selected sample using this URL:

http://127.0.0.1:4221/memory/sessions/memory-local-oct20-a-quality-1792479580117825000?memory_space_id=fd3a7e13-ce64-675f-d1fe-9cbe070bf6b6&host=aab0c6fe-2f0d-459a-ad72-0e6adab53755&client=host%3Aaab0c6fe-2f0d-459a-ad72-0e6adab53755&scope=memory_local_oct20-a_primary&namespace=private

The credential-revocation subset now passes after published
[phoenix_socket_client0.8.8](https://hex.pm/packages/phoenix_socket_client/0.8.8)
closed upstream#109/#110 and routing13 integrated its public snapshot contract.
The required0.21.14 transport closure is adopted. Focused177 source regressions,
dev warnings-as-errors compilation, scoped formatting and global strict Credo
passed. See `routing13-*.log`, `socket54-*.log` and `socket-final-credo.log`.

Executed locally against the retained fixture:

```sh
python3 scripts/memory_local_dev.py service gateway restart --timeout 180
python3 scripts/memory_local_dev.py service host restart --timeout 180
uv run --with playwright==1.56.0 python .devenv/memory-local-fixtures/oct20-a/revocation_after_upstream.py
```

The private probe creates a unique protected sentinel, obtains replacement
credentials through the actual Admin form, revokes the configured credential,
checks direct/MCP recall/list/stats/remember/forget on existing/warm/cold
connections, restores a healthy credential in `finally`, proves original data
integrity and removes only its new sentinel. It creates a private healthy YAML
backup; never print it. This is a fixture-specific observer, not a general API.
The second run passed all30 cases:
`oct20-a/revocation-after-upstream-1792503054089079000/report.json`.
Its first exact-error-classifier failure remains unchanged. Public/Admin/Host are
ready after restored credentials and cleanup. The first gateway restart safely
refused a transient ownership mismatch; a supported retry succeeded after
read-only identity/ancestry checks, with no manual signals or record changes.

The new transient-only regression was also executed:

```sh
python3 .devenv/memory-local-fixtures/oct20-a/socket_transient_after_upstream.py
```

It passed in `oct20-a/socket-transient-after-upstream-1792504038181127000/report.json`:
same-host survival, exact bounded-stale direct/MCP mirror recall, duplicate
provisional identity, automatic canonical one-copy recovery, preserved187 baseline
IDs/tombstones, scoped cleanup and all endpoints ready. Two earlier driver failures
are retained. The observer requires a finite terminal inventory page (maximum2000
records), and recognizes mirror `canonical_id`; do not substitute a truncated
first-page set or arbitrary success response for those checks.

This checkpoint predates full shared-host qualification. At that time online
capability and revoke-before-outage subsets passed while offline leases,
disconnected revoke and old intents remained open. Later online/offline100,
Task71A5, reconcile100c and final127/129 evidence close the local L13/L18
composites. No cross-machine validation is required. Current commit/delivery and
exact-SHA quality gates are in the acceptance report; required red gates still
block release.

### Retained canonical inventory for shared-access validation

The content-free inventory helper reads only the two fixture spaces from the local
devenv `backplane_dev` database. It never reads a live host SQLite database. Use a
new output path each time:

```sh
python3 scripts/memory_local_canonical_inventory.py --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json --output .devenv/memory-local-evidence/unique-canonical-before.json
python3 scripts/memory_local_canonical_inventory.py --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json --baseline .devenv/memory-local-evidence/unique-canonical-before.json --output .devenv/memory-local-evidence/unique-canonical-after.json
```

The default socket is `/tmp/devenv-e733526/postgres`; pass `--socket` if the supported
dev shell uses a different `devenv-*` socket. The helper fails on missing baseline
IDs, changed source/partition/content hashes, deletion or lifecycle changes, and
resurrection of existing tombstones. New IDs are reported separately. This check
does not prove command deduplication, host mirror integrity or full L13/L18.
Its three regression tests and a real read-only203-row/15-tombstone comparison
passed before shared dev migrations; the original baseline comparison also passed
after migrations and two failed live matrix attempts. The capability-matrix browser
driver was unqualified at that checkpoint. Later shared100 and Task71A5
observations provide the accepted live composite; this earlier comparison alone
does not establish it.

### Controlled local host disconnect

The foreground relay uses fixed loopback4224→4220 and a private Unix control socket.
The parent owns its foreground process. With an existing private0700 control
directory, the supported commands are:

```sh
python3 scripts/memory_local_transport_relay.py serve --control /Users/gao/Workspace/gsmlg-opt/backplane/.devenv/memory-local-relay/control.sock
python3 scripts/memory_local_transport_relay.py status --control /Users/gao/Workspace/gsmlg-opt/backplane/.devenv/memory-local-relay/control.sock
python3 scripts/memory_local_transport_relay.py offline --control /Users/gao/Workspace/gsmlg-opt/backplane/.devenv/memory-local-relay/control.sock
python3 scripts/memory_local_transport_relay.py online --control /Users/gao/Workspace/gsmlg-opt/backplane/.devenv/memory-local-relay/control.sock
```

Serve/status were exercised on the real local topology. Offline closes existing
forwarded connections and rejects new ones; online permits fresh connections.
The offline/recovery and ownership checks have10 passing ephemeral-loopback tests
on Python3.9 and3.15. Later actual shared lease/revoke and cold-closure
qualification is recorded separately in the accepted L13 composite.
Stop only through the owned foreground process handle; do not kill by port or delete
an existing control socket. The helper never logs forwarded bytes or credentials.


### Qualified online shared-capability subset

The following command passed against both real local hosts, including supported
Admin grant changes and scoped cleanup. Use a fresh case ID for any new run:

```sh
uv run scripts/memory_local_shared_access.py --fixture .devenv/memory-local-fixtures/oct20-a/fixture.json --case-id keyed-forget-20261021 --timeout 600
```

Report: `oct20-a/shared-1792520800452242000/report.json` (passed-subset). Logical
forget retries explicitly share an idempotency key and must return the same
command ID through direct/MCP. New unkeyed deletion of a tombstoned record keeps
its existing not_found semantics. The runner does not treat that different command
as replay. Source-host/target-space SQL checks are a separate supplement in
`resumed-72/keyed-online-provenance.json`. This is not complete L13/L18.

### Earlier shared subset limits and recovery (2026-10-21; historical)

Later shared-online100/offline100 and reconcile100c evidence supersede this
subset boundary: L13 composite is accepted and the final grant is revoked at116.
The observations below retain their original version57 checkpoint.

The online matrix is qualified only for its stated subset. Independent manual
probes retain additional evidence in `oct20-a/shared-supplement83-20261021-001/`,
`shared-revoke84-20261021-002/` and `shared-forget86-20261021-001/`. These cover
read-only recall, populated-mirror read/deliver withdrawal with remember retained,
online revoke before gateway outage and cold B denial, and forget-only deletion
of a fresh A record without a prior successful B read of that record. They are
not reusable driver qualification or a complete L13/L18 workflow. Each report
retains its own topology, calls, cleanup and limits. Historical read grants for
the partition still exist. Latest shared grant is revoked at version57.

HTTP readiness alone is insufficient: `list` must report mode=online, stale=false
and canonical authority before online cleanup/acceptance. Revoke84/001 stopped
before any samples or grant changes because A returned offline/stale despite
HTTP200. A supported host restart restored online; separate002 passed. Do not
interpret offline fallback as a restored canonical connection. Cold B reports
closed/not_negotiated with cached version51, not negotiated revoke52 persistence.

Offline005 remains failed at private omitted-selector fallback, followed by an
online-readiness cleanup failure. Parent cleanup restored the original direct
B topology. The original five extra rounds are exhausted. A separately authorized
second five-round pool was subsequently consumed by four offline-driver rounds
and Task64 Astra7; consult the current checklist for final inherited counters. No relay or
deliberate outage remains active at this recorded boundary.

Private capture binding additionally passed in
`oct20-a/capture88-20261021-001/report.json`: B's SessionStart/SessionEnd supplied
A host/scope, but normal upload committed both events under B's private authority.
The two synthetic source events are retained history, not sample rows claimed
deleted by cleanup. `source_client_id=codex-cli` is source provenance; canonical
client_id remains host:B. Fresh-record forget-only qualification86 and capture88
preserve all207 original memory/712 evidence fingerprints (current235/740).

An attempted foreign-session consolidation probe stopped before mutations because
consolidate is absent from actual discovery (`isolation87-20261021-001/report.json`).
It is an extended tool enabled only by memory.tools=all. Treat current discovery
as authoritative; do not bypass it or count generic503/validation errors as
authorization proof. Cross-space derive denial remains unqualified by this case.

A normally generated completed profile is now available at
`http://127.0.0.1:4221/memory/profile?profile=8d8e7f38-41c3-40ad-aa4f-6dc3328b0d2c`.
Bare /memory/profile lists it without source-host selection. It was created
through A's advertised MCP profile_refresh and ordinary Styx2730 execution, not
direct insertion/manual worker execution. It aggregates11 sessions/170 observations.
The same request from B is rejected at the project-source partition gate; no
B profile/job is created. The original profile89 runner remains failed because
it expected an unwrapped reason; actual exact managed-tool error and passing
read-only postconditions are retained separately. Consult the acceptance report
for those evidence limits and the new browser screenshot. This is not a full
L13/L18 pass.

Rejected incoming profile requests no longer create readiness blockers as of
`2753065f`. Persisted worker ambiguity still records issues and remains gated.
For a historical false-positive, use the trusted local domain operation
`Backplane.Memory.Workers.ProfileBuildWorker.waive_rejected_request_issue/3`,
never a direct disposition edit. Read and review the exact issue first; supply
its source_table/source_id/reason/disposition/details/updated_at snapshot and
operator attestation (kind trusted_operator, ref, recovery request UUID and
reviewed evidence reference). The operation checks the deterministic source
hash, current project mismatch and absence of persisted project work, then
atomically retains the issue/details, marks approved_waiver and records an audit.
Other pending issues are unaffected. The row alone cannot prove request origin.

The exact reviewed local issue recovery used
`devenv shell -- env MIX_ENV=dev mix run --no-start --no-compile .devenv/provenance-correction/resumed-72/profile-readiness-recovery13.exs`.
That one-shot already committed; do not rerun it. Its output encoder failed on
raw audit UUID bytes, so a separate read-only reconcile14 controller verified the
single audit and unchanged issue details. Gateway restart and live14/delta14
reports then verified A/B online reads, repeated foreign-profile rejection
without new blockers, and real B write/forget mirror delivery. Diagnostic
mirror.status is complete while partition.sync_status is ready. Original failed
reports are retained; these checks do not qualify the remaining offline suite.

### Select exact dead-letter jobs

The existing Memory Overview repair form has an optional **Job IDs** field for
`dead_letter` repairs. Enter1–100 distinct positive IDs separated by commas, keep
the exact canonical partition, and use a stable idempotency key. Blank means the
legacy oldest100 eligible jobs in that partition; malformed input is an error,
not a fallback to that broad operation. The API equivalent adds `job_ids` as a
JSON integer array to `memory::heal` with `kind: "dead_letter"` and the existing
idempotency key. Omit `target_id`, whose domain-entity meaning is unchanged.

Explicit targets must all be eligible. A foreign, missing, nonterminal or governed
job causes `target_mismatch` and no partial retry. Reordering the same IDs replays
the existing outcome; changing the selected set under the same key conflicts.
Inspect the retained repair audit and normal job outcomes separately. Dispatch
alone does not prove provider success. Historical errors and attempts remain.

For controlled gateway-only maintenance on this tested devenv2.1.2 profile, use:

```sh
devenv processes list
devenv processes stop backplane
devenv processes start backplane
devenv processes wait --timeout 60
```

This leaves the `postgres` process running. The dev harness's `service gateway
stop` instead stops its whole owned `devenv up` group, including PostgreSQL; it is
appropriate for a stack outage, not an independent database-backed repair while
the gateway application is stopped. Do not remove a consumed recovery guard or
blindly rerun an action with an unknown outcome. Reconcile read-only and prepare a
new reviewed recovery plan. The local acceptance artifacts retain the initial
preflight failure, exact no-mutation proof and narrower recovery separately.

## Delivery checkpoint after local acceptance

Memory source/docs: `86ad63e5`; selective release support: `db610c33`, both pushed
to `origin/main`. The only remaining root worktree file is the deliberately excluded
`backplane-memory-provenance-codex-task.md`. Local evidence remains under
`.devenv/provenance-correction/resumed-101/`; final L18 acceptance is
`l18-final-acceptance129.json`, with independent split recovery and explicit
scheduler-delta review alongside it.

Required CI on the new pushed SHA must pass before versioning/dispatch. Prior
required gates are red; do not bypass them. Inspect actual runs with:

```sh
gh run list --repo gsmlg-opt/backplane --branch main --limit 5
gh run view RUN_ID --repo gsmlg-opt/backplane --log-failed
```

Only after required gates pass, use an unused version and the existing selective
release workflow. The affected app list is
`backplane_admin,backplane_api,backplane_host_agent,backplane_llama,backplane_mcp,backplane_memory,backplane_memory_contract,backplane_skills,backplane_system`.
Commit/review the scoped version change before dispatch so Docker and OTP artifacts
agree. Require gates on that exact immutable SHA. No release is claimed here.


The follow-up shared-delivery correction changes only EdgeSync type declarations;
actual runtime authorization and the accepted local L18 workflow are unchanged.
Task64A12 passed21 focused tests and removes all five newly observed Channel
Dialyzer warnings. Full local Dialyzer remains red on one retained MCP warning
and nine untouched Llama opaque Task warnings; do not treat it as a green root
check. Inspect the final pushed-SHA CI before any release. Latest repair pool is
5used/0remaining, Task64Sol2/Astra12; stages04 remainsSol2/Astra20.


## Included repository release dependencies

The owner expanded this task to include the MCP idempotency warning, the client
rotation audit regression and the Relayixir HTTPS-proxy cleanup regression.
Earlier exclusions above describe historical checkpoints, not the current scope.
MCP runtime changes add `backplane_mcp` to the selective release list. Admin
and Relayixir compatibility tests must follow current issued-token and Fetch
cleanup contracts; no warning suppression, secret logging or false cleanup
confirmation is authorized. Test/documentation-only changes do not require an
otherwise unaffected app version bump. Release still requires actual green gates
on the final immutable main SHA.
