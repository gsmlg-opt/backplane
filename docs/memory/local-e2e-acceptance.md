# Memory local end-to-end acceptance

Status: **local L01–L18 accepted; source CI green; Memory qualification passed; release command verified locally; final CI/publication pending**.
L13 and L18 use the explicitly documented composite evidence levels. Verification
is local development only. The broader task is not released. The current source
and repair counters are in [the checklist](local-dev-checklist.md#current-resume-boundary-2026-10-21-authorized-continuation).

Release39553644831 at44f03fca failed before builds/publication on the removed
`#replay-memory-space` selector. Task72 Astra5 reproduces that failure locally,
then corrects only the browser consumer and Replay LiveView regressions. Actual
`MIX_ENV=test mix memory.replay.browser_qualify` now passes with Chrome156,
122 seeded events, full fixture identity, controls, cursor, reconnect and PubSub.
Replay LiveView6/0, scoped format, JavaScript syntax and diff checks pass; independent
Sol review reports no findings. These are seeded test-only qualification results,
not a replacement for the retained dev L01–L18 evidence. Evidence:
`.devenv/provenance-correction/task72-astra5-browser/{before,after}.json`,
`{before,after,focused}.log`. At that checkpoint: Task72Sol2/Astra5, pool3used/2remaining.

Current delivery boundary: selective run39556407249 and full run39557514211
were cancelled. Latest full run39560571890 at4ec9bd95 passed Memory qualification
and four host-agent builds, then failed both Backplane builds at the new Admin
metadata refresh. Its command inadvertently force-compiles the umbrella;
Task30 corrected app scope in an isolated worktree. Publication has not occurred.
Release tests25/0 and workflow contracts8/0 pass. The warm production compile
changes only Admin; compiled version1.10.28/SHA4ec9bd95/prod pass with runtime
metadata overrides removed, and the root production build remains unchanged.
Evidence: `.devenv/provenance-correction/task30-release-compile-r1/`.
Downloaded qualification manifest revision4ec9bd95 and all five hashes match;
browser122/eval/qualify pass under their seeded/CI profiles. Qualification remains
non-authoritative for performance; LongMemEval output is retrieval-only and not
comparable to published results. Evidence: `resumed-101/release141-qualification/`
and `release141-failed.log`. Task30Sol repair1 passed locally; latest pool4used/1remaining.

Test-count correction: historical1413/0 and1394/0 runs loaded two files with
one shared ExUnit module name. Those counts are retained observations, not proof
of unique coverage. Task72 repairs the registration and reruns both suites; see
the final verification section for the corrected count.

Final A20 source verification passed focused39/0, exact178-file Memory1413/0
with5 unchanged exclusions, exact14-file Admin134/0, scoped format/diff/Credo
and dev warnings-as-errors compilation. Actual explicit gateway stop/start loaded
the accepted source (BEAM69601→85577), with PostgreSQL continuously ready.
Browser Memory opens directly:264 records across sources (255 primary/9 isolated),
optional host/repository filters and optional exact repair Job IDs.

Task125's24 audited normal-worker retries completed8 and failed16 with classifier
`:idempotency_conflict`. A20 now reuses matching durable classifier comparisons;
manual candidate conflicts remain strict. Task126 failed before dispatch on
operator-tool atom conversion; independent proof found no selected data/job/audit
mutation. Both failures and their consumed guards remain immutable.
Task127 then dispatched exactly the remaining16 through supported audited repair;
all16 completed through normal gateway workers. The8 prior completions and old3
sentinels retain exact full rows; both old error prefixes and all old audits remain.
Independent final proof passes strict Memory/evidence/capture/inventory and all13
other composite124 checks. Its exit3 asks for parent review of two new scheduler
jobs3632/3633: both normal StageResume/GraphExtract jobs completed attempt1/errors0,
with no changed or missing outside16 jobs. The separate parent delta review accepts
only those two new jobs. Original118/124 and the exit3 report are unchanged.

L18 is accepted from the retained repeated workflow, cold host/gateway restarts,
actual processing/browser/recovery and final preservation/owned-process checks.
This is composite acceptance, not a claim that every fault leaf ran twice or that
operator-assisted recovery was automatic first-attempt success. Historical207/214
Memory IDs and712/719 evidence survive. Eleven Memory row changes are the audited
additive `metadata.repository_sources` and `updated_at`; task121 reconstructs their
original hashes. The known insufficient-input Graph stage remains pending, with
only its captured attempt counter increasing; all other captured fields stay exact.
Both hosts' direct/MCP health is online/canonical/stalefalse/pending0; temporary
relay/B and operator processes are stopped, original local services remain running.
The preceding pool is exhausted. The newly authorized five-round pool allocates
four rounds to Task72 registration/browser compatibility, Relayixir observation and the release compile scope, with1 unallocated. Stages04Sol2/Astra20,
ceiling21; Task127 tooling consumed no product round (Sol instrumentation repair1/2).

Final evidence under `.devenv/provenance-correction/resumed-101/`:
`task127-{original-observer001,post-observer001,actual-health001}.json`,
`final-split127-result001.json`, `task127-parent-delta-review001.json`,
`task127-launch-result.json`, and `l18-final-acceptance129.json`.
Source checks: `../stages04-a20-artifacts/report.json`.
Delivery details are recorded in the final delivery section below. Earlier dated
sections retain historical failures and do not override this current assessment.

Actual online100/001 and offline100/001 now passed their independent-capability
and offline-authority subsets, with cleanup and preservation passed. Task71A5
strict identity compatibility passed52 tests and actual HTTP/MCP short-lease
reads, expiry, disconnected revoke, cold closure and fresh regrant rejecting old
intents. No full L13/L18 result is implied. At that checkpoint, historical207
memory/712 evidence fingerprints were unchanged and the inventory was274/786. Evidence:
`oct20-a/shared-{online,offline}100-20261021-001/report.json` and
`resumed-72/history-offline100-preservation.json`.
Separate read-only `resumed-72/reconcile100c-result.json` verifies durable audit
versions101–116/reasons/capabilities/leases, cleanuprevoked116, fixture default
capture and alias tuples, sourceB/targetA for3 sharedwrites, allsample tombstones,
and4 oldintents with retained localdeadletter/noACK and no canonicalsuccess.
Original report flags remain unchanged. No pre-run full alias-table digest was
retained; unrelated aliases were not inspected. Two earlier diagnostic assumption
failures are preserved and explained in the supplement, not product failures.
Task64A8 isolated committed-V1 compatibility passed red30/3 → green30/0,
strict owning compilation/Credo/format/diff. The two-file correction is committed
as `9fde5c00`, merged to main and pushed with all231 local changed-path bytes
preserved. Root test-only integration is complete. The first matrix failed213/16
against a DB missing migration06/shared-feed columns; the fresh uniquely named
DB was created/migrated and the same eight-file matrix passed213/0
(System18, Memory22, Host69, API104). Old data and all assertions are preserved.
Root evidence: `task64-astra8-root-integration/integration-result.json`.
OriginalB topology restored; actual A/B direct+MCP online/canonical/stalefalse/
pending0 passed in `resumed-101/original-topology-before.json`. The fresh L18
host-first sequence passed its subset; no full L18 pass is claimed. Thirdpool3used2remaining; Task64A9 test-only compatibility recovery passed1396/0
with5 unchanged exclusions across178 Memory files. Remaining groups run separately.

### Current retained workflow observations (2026-10-21)

The latest two-host health check is `resumed-101/resume-health002.json`: all four
direct/MCP reads are online/canonical/stalefalse/pending0. The original B service
is running and the temporary relay B service is stopped. The parked owned relay
was subsequently stopped after exact PID/UID/birth/argv validation; foreground
command exit0 and socket removal are recorded in
`resumed-101/relay-final-cleanup118.json`.

Fresh summary-gate UI/cold-restart/normal processing passed in
`oct20-a/quality-1792539529714338000/report.json`. The original gate was restored.
Normal Styx produced summary, semantic facts, Crystal and Graph; the actual
Crystal distinguishes the repaired acknowledgment failure from the unresolved
accessibility follow-up. The fresh32-event/four-session intake passed duplicate
identity checks in `oct20-a/l18-fresh-capture-101/`. Read-only correlation
`resumed-101/fresh-correlation-result001.json` found seven current-revision
procedural outputs, each with fresh inherited source evidence, and45 graph nodes
with fresh event provenance. These outputs are procedures, not newly proven
lessons. One fresh Graph stage remains `pending/insufficient_input`; that is not
an invalid-provider response. All correlation sentinel bounds were below limits.

Operator consolidation on the fresh quality session passed idempotence and
rendered source-link checks in `oct20-a/operator-1792539715594052000/report.json`.
The open-page Graph/Pipeline legacy probe failed before capture dispatch because
its eight selected states were off page1 of412 states. Its immutable failed
report remains `oct20-a/open-graph-pipeline-l18-fresh-graph-101/report.json`.
The pagination-aware107 observation and operator-assisted117 recovery are
recorded below; the pre-dispatch legacy failure is not a product defect.

Private forget/outage/cold-restart resumed postconditions passed in
`resumed-101/private-forget-resume-result.json`: six original outbox operations
settled with matching IDs and ACK revisions, three canonical tombstones remain,
and another cold host restart did not resurrect local/canonical aliases. The
initial driver failed on transient503 owner-diagnostic readiness after gateway
restart. Its failure remains retained; the read-only resume repeated no mutation.

Exact9fde CI39516035759 and Test39516035807 are red. Dialyzer idempotency,
AdminAudit regenerate_token and Relayixir cleanup_unconfirmed repeat prior
excluded failures. The additional MCP protocol SSE-header test failed with
`** (exit) no process` at `streamable_http_test.exs:866`; its package matches the
cited baseline and the preceding run passed. Its cause is unproved. Evidence:
`resumed-101/ci108-report.json`. Committed-SHA Memory/Host/API/System jobs passed;
those jobs do not validate the broad pending local diff. Release remains blocked.

Fresh governance repeat109 passed its scoped observations:
`oct20-a/governance-l18-governance-109-1792540505595687000.json` records the
selected semantic fact tombstoned with unchanged content hash/evidence, no active
same-hash candidate after unchanged-summary repair or late-event processing,
exactly-once late capture and settled new source revision. The parent then ran
the existing minimal Repo-only targeted rebuild controller successfully
(`resumed-101/governance109-rebuild.log`), with no source gaps. The separate
read-only checkpoint report `governance-l18-governance-109-1792540690391445000.json`
confirms tombstone/evidence/read absence after rebuilding. Its
`parent_rebuild_execution_verified=false` remains unchanged: execution proof is
the independent parent command log, not an inference by the observer.
Core direct/MCP parity110 passed with owned-marker-only cleanup in
`core-parity31-1792540713775421000.json`. Fresh four-case real-vector recall112
passed at `oct20-a/api-recall-1792540755200580000.json`; browser observation is
being verified separately. These remain subsets of the incomplete L18 workflow.

Browser112 passed12Memory pages, four retained recall-trace comparisons and
already-open Memories visibility without reload in1821ms:
`oct20-a/browser-1792540769991182000/report.json`. Provider113 passed actual
embedding outage, lexical degraded reads, restored real-vector exact/paraphrase
recall on both interfaces and exact original provider form restoration:
`oct20-a/provider-recovery-1792540835042667000/report.json`. Its remaining
invalid-structured-LLM gate refers to that script's narrower scope; accepted
historical real LLM failure/recovery evidence remains separately recorded.

Pagination-aware observer107 dispatched one fresh relation hook, accepted its
duplicate as the same canonical event, preserved open Graph/Pipeline documents,
and observed changed page0/page50/total values within approximately2.3seconds.
Normal Summary/Episodic/Crystal completed the new revision, but Graph's three
normal attempts rejected invalid provider edges and reached `dead_letter` with
`invalid_graph_response` (gateway classification `edge_target_reference`). The
observer therefore failed at its300second normal-processing deadline. Its
immutable result is
`oct20-a/fresh-open-pages107-freshquality107-20261021-001/report.json`.
No recapture or successful Graph result is implied. Supported operator-assisted
same-revision recovery remains required. Existing LLM recovery passes remain
historical evidence and do not close this newly observed current failure.

The bare-system Python contract command failed on missing `yaml` before loading
the policy module; with its declared dependency, the actual command
`uv run --with PyYAML==6.0.3 python -B -m unittest discover -s scripts/tests -p
 'test_memory_local_*.py'` passed283tests. Both logs are retained under
`resumed-101/python-contracts115*`. This required no source change.

Final scoped regression119 created/migrated a new test database and ran178
Memory test files:1395tests,6failures,5excluded (exit2). All six failures are
strict legacy compatibility expectations: NamespaceContract's public API list
and schema hashes plus ServiceTools' schema hashes. The authorized
`get_source_summary/3`, `tombstone_shared/3` and optional `memory_access_id`
extensions were implemented without updating these two older frozen test files.
No tool names were added or removed. The remaining seven test groups and quality
commands were not run after this failure. The original log and exact diff
classification remain in `resumed-101/task119/{report,triage}.json`.
Task64Astra9 is allocated strictly to those two compatibility test files; no
production behavior/schema change is authorized. Thirdpool3used2remaining;
Task64Sol2/Astra9. A passing rerun is pending, not inferred.

### Composite L13 acceptance and retained L18 continuation

L13 is **accepted for local development**, based on the normative live matrix in
[shared-host-access-design.md](shared-host-access-design.md#required-acceptance-and-evidence-boundaries)
and current213/0 deterministic faults. The parent assessment with artifact hashes
is `resumed-101/l13-composite-assessment.json`; an independent read-only Sol audit
checked every normative row. This is a composite assessment: individual reports
retain their original subset status, completeness flags, failures and limits.

| Required boundary | Actual evidence under `.devenv/memory-local-evidence/` unless noted |
| --- | --- |
| Isolated read/write/delete/capture/derive/delivery | online100; capture88; `resumed-72/profile-readiness-live14.json`; protocol-denial1792441499435 report |
| Read-only, independent remember/forget, combined capabilities | online100; supplement83; forget86 |
| Real mirror, default0/private fallback, capability withdrawal | offline100; supplement83 |
| Online revoke followed by outage/cold restart | revoke84/002; current deterministic overlay/cache races |
| Disconnected revoke, measured15sec lease, cold closure, newer regrant | offline100; current lease/snapshot/channel/ACK faults |
| Audit, target/source provenance, defaults, aliases, governed data | `resumed-72/reconcile100c-result.json`; history-offline100-preservation |

The current test matrix is run on a fresh migrated test DB. Fault races are
classified as deterministic tests, not live execution. Fixture aliases/defaults
were checked, but no pre-run full alias-table digest exists; unrelated aliases
are not claimed exhaustively verified. Cold `not_negotiated` closure is not a
claim that a newer negotiated revoke was persisted.

L18 continuation: `host-first-l18-host-first-101-1792539433673672000/report.json`
passed cold host-first capture/command settlement and preserved YAML/store
identities. Original B was cold-restarted afterward. Actual A/B direct+MCP replies
were online/canonical/stalefalse/pending0, recorded in
`resumed-101/after-both-restarts.json`. Replaying the original32 logical capture
inputs left all33 retained original-session event IDs/full-row fingerprints
unchanged (`capture-before.json`, `capture-after-replay.json`). This is duplicate
preservation evidence, not fresh generation or complete L18. The fresh summary-gate
UI/persistence/normal-processing, eligible procedures, governance and embedding
recovery repeats subsequently passed as recorded above. The current Graph failure
needs supported recovery, followed by final state/configuration/process
reconciliation. L18 does not require every accepted fault leaf to run twice; the
read-only requirement audit is `resumed-101/audit114.json`.

User has resumed with a third five-round repair pool. Earlier pool/cumulative
counters are preserved; the opening result and checklist record current allocation.
The offline `q` correction passed isolated24/0 tests/strict checks and actual
HTTP/MCP exact-singleton fallback; it is committed/pushed. All231 premerge local
changed-path bytes were preserved. Exact-SHA CI39492534812 and Test39492534808
are red: compile/format/Credo/workflow contract and Memory/HostAgent/System/API
suites passed; unchanged idempotency Dialyzer, ClientsLive regenerate_token and
Relayixir cleanup_unconfirmed failed. No release was published.

Offline94/003 and diagnostic offline96/001 reproduced offline shared remember400;
owner dead_letter increased3→4 with active unchanged authority. Task64 Astra7
wraps caught channel exits as transport, passing agreed red37/1 then green65/0
and strict checks. Its root shared regression verifies durable pending identity,
retry and permanent-denial controls. The final second-five repair pool is5used/
0remaining (Task64Sol2/Astra7, Task71A4, routing04A14of16, stages04A15of16).

After supported B restart, actual offline97/001 passed zero-lease private fallback,
durable remember/forget pending receipts and capability-withdrawal rejection.
It then failed `shared_recall_identity_required`; full L13/L18 remain unqualified.
Cleanup passed, own samples absent, deliberate fault ended. Preserve the original
failed reports; no assertions were weakened. Subsequent read-only diagnosis
found a definite driver contract mismatch: read() and lease_observation() inspect
only row.id, while the mirror returns canonical_id and the facade preserves it.
The report retains HTTP200/timing but not the failed recall's rows, so this is a
strong source-backed explanation, not proof of the actual response contents.
Next repair must reuse strict identity normalization in both assertions, retain
conflict/duplicate/sentinel/lease checks, and record bounded metadata before
asserting. No implementation or new probe was authorized after pool exhaustion. The channel fix remains uncommitted:
standalone extraction into main is unsafe because main's v1 retry path serializes
errors with to_string, whereas the dirty root contains tuple-safe compatibility
handling. Task98 identified this statically; clean-main compatibility was not run.
That boundary still needs its own allocation from the newly authorized third pool.

Final handoff restored original B config/state, stopped the temporary B through
its owned lifecycle, and terminated only verified owned relay67324. Relay reported
stopped/control_socket_removed. Original A/B direct and MCP lists all returned
online/canonical/stalefalse/pending0 (`resumed-72/final-original-topology98-live.json`).
All207 original memory and712 evidence fingerprints remain unchanged; current
inventory268/780 (`resumed-72/history-final98-preservation.json`). Memory fingerprints
exclude embedding and the three documented access/application counters; evidence
fingerprints cover the full row. These checks preserve baseline data, not an
assertion that every current row is byte-identical.

The profile-request readiness regression is repaired and locally requalified.
Rejected incoming requests no longer create migration blockers. One reviewed
historical false-positive issue was waived through the new exact, audited domain
operation; its identity/details remain intact. After supported gateway restart,
A/B direct and MCP lists returned online canonical results. Repeating B's foreign
profile request still failed with partition_mismatch, left issue/job/profile
inventories unchanged, and did not break either host's reads. A new B private
write and its later forget both reached the real mirror. Stages04 is now
Sol2/Astra15of16;24 focused tests and owning strict compile/format passed. This
two-file repair is committed and pushed as `2753065f`.

Its subsequent in-scope Credo correction was pushed as `03c703cf`. Exact-SHA CI39490026185 and Test39490026127 are completed red:
Compile, Format, Credo, Workflow Contract and Memory/HostAgent/System/API suites
passed; idempotency Dialyzer, ClientsLive and Relayixir remain red. These scope
exclusions still prohibit release. Current exact logs are
`resumed-72/current03-{ci,test}-{jobs.json,failed.log}`.

Artifacts in `resumed-72/`: `profile-readiness-reconcile14.json`,
`profile-readiness-live14.json`, `profile-readiness-delta14.json`, and
`history-readiness14-preservation.json`. Original profile89 and edge14 failures
remain immutable. The first recovery report encoder failed on a raw audit UUID
after the transaction committed; read-only reconciliation verified the waiver and
single audit without retrying mutation. The first edge probe expected the wrong
nested status (complete instead of ready); the subsequent real delta test passed.
All207 original memories/712 evidence fingerprints remain unchanged, current
243/755 before the fresh delta sample. No full L13/L18 pass is implied.

The second five-round repair pool is exhausted: Task71's four harness rounds
and Task64's seventh cumulative recovery consumed it. Task71 identity/readiness
coverage subsequently passed52 focused tests; Task64 root closed-channel coverage
passed65 tests.
These supplement the failed live workflow and do not qualify L13/L18. No release
gate waiver or cross-machine verification is authorized.

## Current local evidence (2026-10-21)

Memory opens directly across existing spaces, with SQL search/order/count/pagination
and optional host/repository filters. Cold local browser checks passed all16 bare
Memory routes, source details including full checkout/cwd paths, refresh and
visibility of durable Host B data while B was stopped. The two Memory type
warnings are absent in exact-SHA remote Dialyzer output. Scoped correction
`d3188a742868fa59120658b7076e5aaf5c01e406` is committed and pushed to main.
Compatibility followups `76f9772e`, `6058c75b`, and `204961e8` are now pushed
to main after isolated50/0, strict compilation and format/syntax checks. Other
shared full-goal source remains uncommitted; there is no version bump or release.

The actual online independent-capability matrix passed after correcting its
forget replay identity: read-only, remember-only, forget-only, both combined
subsets and all four grants, through direct and MCP. The same logical mutation
uses one command ID; missing permissions and omitted-target isolation are
checked separately. Report:
`oct20-a/shared-1792520800452242000/report.json`. Cleanup passed, own active
records absent and grant revoked at version26. This report is deliberately
`passed-subset`, with complete_L13/L18 false. Prior failed reports are retained.

A separate read-only canonical supplement verifies three shared writes target A's
space while source host/client remain B, and one private sentinel retains A's
source. All four have supported tombstones. Evidence under
`.devenv/provenance-correction/resumed-72/`: `keyed-online-provenance.json`,
`canonical-after-keyed-online.json`, `keyed-online-integrity.json`. All214
pre-run canonical rows compare unchanged; original207 memory/712 evidence
fingerprints are unchanged (current218/723, reflecting new synthetic history).

The latest offline runner case003 still failed before any outage, waiting for a
complete shared mirror; cleanup passed. Cold-loaded opt-in diagnostics then
isolated a default-partition admission failure. Actual diagnostic-only cases
`oct20-a/diag64-active-20261021-001/report.json` and `...-002/report.json`
used active browser grants without faults. Case002 shows default access closed
with `invalid_protocol`, shared version33 `needs_sync`, and global syncer count2 /
index0 / `next_admission: unauthorized`. Cleanup passed in both; all222 then224
pre-run canonical rows were retained unchanged (current226 including synthetic
tombstones). Diagnostics identify the blocked default entry; they do not qualify
offline behavior. The final-snapshot ACK cursor mismatch was corrected and
passed62 focused tests; after cold restarts and normal audited default-authority
version updates, both real mirrors reached active/complete with successful ACKs.
Evidence: `resumed-72/task64r5-default-recovery-002.json`.

Actual offline case004 subsequently passed positive online recall with a populated
shared mirror, missing-read rejection and no-delivery mirror hiding. It failed
waiting for zero-lease delivery after the first disconnect/reconnect; cleanup
passed and fault_active is false. Default authority became closed/unauthorized.
Source diagnosis identified transport `channel_exit` falling through to permanent
unauthorized, compounded by failed-partition starvation. At that historical checkpoint recovery
was still in progress; the later offline97 failure above supersedes it. The independent214-row baseline
comparison remains unchanged/current228 in `canonical-after-offline71-004.json`.

Final authorized Task64 repair passed66 scoped tests and strict compile/format.
After cold restart and audited newer default authority, real mirrors recovered.
Offline case005 passed the previously failing zero-lease regrant, then both
zero-lease denial calls. It failed at private omitted-selector fallback; the report
lacks the response metadata needed to establish its cause. The driver lacks a
private-mirror readiness barrier, and its cleanup connectivity barrier accepts
offline replies. Cleanup therefore also failed. No short-lease/cold-revoke/full L18
pass was claimed at that checkpoint. The first five-round pool was consumed
at Task64Sol2/Astra6; the latest cumulative counter is Astra7 as recorded above.

Parent cleanup through normal Admin/host APIs passed, revoking the exact grant and
removing both owned samples. Report: `resumed-72/offline71-005-parent-cleanup.json`.
Independent214 baseline comparison passed/current230; prior records and tombstones
are unchanged. Final historical digest comparison also passed all207 original
memories and712 evidence rows (`history-final-preservation.json`), excluding only
embedding and read/application metrics from memory digests. The original failed report remains immutable.

Gateway4220/Admin4221/A4222 and original direct B4223 are running and HTTP-ready.
B uses `.devenv/memory-local-isolated` and its original YAML. Temporary relay B was
stopped and verified owned relay terminated. No deliberate outage is active;
`resumed-72/final-local-stack.json` records actual ownership/logs. No cross-machine
checks were performed.

Compatibility checkpoint main/origin main: `204961e8a3a6013d89e8f13f2cc0223fa75cbd00`, parity0/0 at that checkpoint.
All240 local changed paths were byte-preserved across the compatibility merge;
worktree/branch cleaned. Current-SHA CI39482357111 and Test39482357063 both completed
**failure**. Compile, Format, Credo, Workflow Contract and Memory/System/Host
Agent/API tests passed. Idempotency Dialyzer, ClientsLive regenerate_token and
Relayixir cleanup_unconfirmed remain red. Exact completed job logs are retained
under `.devenv/provenance-correction/task83-current-{dialyzer,admin,relayixir}.log`;
terminal run/job states are in `resumed-72/current-sha-ci-final.json`. Scope-only
continuation is authorized; release gates are not waived. Full local L13/L18
remain release blockers independently. No release was dispatched.

Independent online supplement `oct20-a/shared-supplement83-20261021-001/report.json`
passed and cleaned normally, revoking the shared grant at version50. Through both
direct and MCP it verifies read-only recall without mirror delivery; forget-only
deletion of an A-authored record while current recall/list are denied; and removal
of read/deliver from a populated mirror while remember remains usable. Recall is
denied before and after the new shared write settles, and the mirror remains
hidden. B previously read the deleted sentinel, so this does not establish that
no historical read prerequisite exists. The separate `resumed-72/online83-provenance.json`
verifies A's target space, A/B source identities and all three tombstones. Private
source_client_id remains null; the shared write stores B's bare host UUID. The
original report's source_provenance_verified=false is preserved; this is separate
evidence. Its revision field records HEAD with dirty shared source, not a clean
runtime artifact. No offline, old-version race or full L13/L18 pass is implied.

A separate revoke-before-outage/cold-recipient subset passed:
`oct20-a/shared-revoke84-20261021-002/report.json`. The actual original direct
topology first populated B's shared mirror with an A-owned sentinel. Online
Admin revocation closed the owner and mirror; direct/MCP recall, list, stats,
remember and forget all returned exact permanent denials. After supported gateway
stop and B cold restart, owner/mirror stayed closed and the same10 calls were
again denied. Cold owner reason was not_negotiated at cached authority version51;
this proves closed access at boot, not persistence of the new revoked version52.
Gateway restart restored actual canonical online responses on A and B before
cleanup. Own active rows are absent and the grant is revoked at version54.

Case001 remains failed and immutable: A was HTTP-ready but actually offline/stale
before any sample, grant mutation or outage; cleanup likewise rejected its offline
list. A supported host restart recovered actual online responses, after which
unchanged qualification ran as separate case002. The transient A connectivity
cause is unknown; no production source was repaired. The cold-revoke subset does
not replace failed private fallback, disconnected withdrawal/revoke, short-lease
expiry, old-intent rejection or the complete retained L18 workflow.

Final history comparison `resumed-72/history-revoke84-preservation.json` passed:
all207 original memory digests and712 evidence digests unchanged (current234/739).
Memory digests exclude embedding and read/application metrics; evidence digests
cover complete rows. Supported-owned final status is retained in
`resumed-72/task84-final-stack-{primary,b}.json`: gateway/Admin/A/B running and
HTTP-ready, with actual canonical reconnect metadata in the case002 report.
No deliberate fault remains and no cross-machine validation ran.

Independent forget-only supplement86 passed (`oct20-a/shared-forget86-20261021-001/report.json`).
The Admin first grants only forget at version55, then A creates a fresh canonical
record. B's direct/MCP recall/list/stats/remember calls all return exact permanent
denials, with its mirror hidden and no target IDs. B deletes the new A-owned ID
through direct/MCP with one stable logical command, and A confirms canonical
absence. No successful B read returns this new record before deletion. B still
has historical read grants for the partition, so no stronger lifetime-grant claim
is made. Normal cleanup passes and revokes the grant at version57. No offline
or full L13/L18 qualification is implied. Final historical comparison
`resumed-72/history-forget86-preservation.json` confirms all207 original memories
and712 evidence rows unchanged; current235/740 includes synthetic tombstones.

Private capture binding supplement88 passed
(`oct20-a/capture88-20261021-001/report.json`). With A→B shared access still
revoked57, two real B Codex hooks (SessionStart/SessionEnd) deliberately supplied
A's host_id and scope. Both were durably accepted and synchronized normally.
Canonical events instead carry B's space, host, host client, bound scope and
private namespace; source_client_id remains codex-cli. The two event IDs and
source sequence1/2 are retained as clearly synthetic fixture history. This proves
private hook authority binding, not rejection of a forged authenticated channel
envelope, and does not prove cross-space derive denial or full L13/L18.

The final `resumed-72/history-capture88-preservation.json` comparison passed
all207 original memory/712 evidence fingerprints unchanged (current235/740).

Separate isolation87/001 stopped before mutations at consolidate discovery.
The actual catalog omitted memory::consolidate; a read-only source review confirms
it is an extended tool enabled only by memory.tools=all. This is compatible with
the deliberate visibility policy, not established runtime drift. Its immutable
failed report and `resumed-72/isolation87-discovery.json` are retained. No
undiscovered method was invoked; the derivation assertion remains untested.

Advertised profile generation was exercised separately in
`oct20-a/profile89-20261021-001/report.json`. A's normal MCP profile_refresh
queued Styx2730, which completed on attempt1 with the exact A partition. The
new profile reports11 sessions/170 observations. A read-only source check confirms
all93 linked memories,10 crystals and11 sessions exist in A's exact partition
(`resumed-72/profile89-source-ownership.json`). This deterministic aggregate is
not new model enrichment.

B has no source memories for that project and shared access is revoked57. Its
same advertised request returns an isError tool reply with the exact text
`hub unreachable: Managed tool memory::profile_refresh failed: :partition_mismatch`.
The original runner expected an unwrapped reason and remains **failed** at that
assertion. The existing managed-tool dispatcher explains the wrapper. No API
request was repeated or product/driver source repaired. A separate read-only
postcondition report confirms A's profile digest unchanged after B's attempt,
only A's completed job/no B job, and one B-scoped partition_mismatch diagnostic
issue (`resumed-72/profile89-readonly-postconditions.json`). These are separate
passing postconditions, not a relabeling of the failed runner.

Fresh actual browser inspection of bare /memory/profile found the new profile
without a host selection; navigation opened its completed detail,11/170 summary
and source identities with0 page errors. Screenshot/report:
`resumed-72/profile89-browser.{png,json}`. The page was opened after completion;
no live-refresh latency claim is made. A's profile and B's diagnostic issue are
retained fixture data. This covers one advertised derivation path, not foreign
session consolidation, all generators, offline grants or complete L13/L18.

## Retained earlier evidence (2026-10-20)

The entries below record their observation time; historical no-commit/old-budget
statements do not override the current delivery and repair boundary above.

### Authentication rejection: consumer source and actual local subset passed

Published phoenix_socket_client0.8.8 closed upstream#109/#110. Task54 adopted
that minimum and the required synchronized HTTP/QUIC/SSL0.21.14 closure; exactly
nine lock entries changed. Dev warnings-as-errors compilation and scoped checks
passed (`socket54-*.log`). Routing04 recovery12/13 then integrated authoritative
`connection_info/1` snapshots with latest-attempt rechecking, failed-socket cleanup,
stale connector-rejection fencing and retained-denial admission for local commands.
The obsolete duplicate-registration initializer was removed after source and
consumer regressions proved the upstream correction; temporary channel restart
policy remains. Final counters are Sol2/Astra13 of16.

`routing13-tests.log` passed177 scoped tests, including real401/403 with telemetry
disabled and sampling0, transient refusal/timeout fallback, cleanup, cancellation,
stale attempts, duplicate-registration privacy and command denial/recovery. Four
real rejection cases each completed within two seconds. Scoped formatting,
whitespace and dev warnings-as-errors compilation passed. Earlier failing tests
and the measured cleanup-race regression remain retained evidence.

Actual local Admin revocation then passed30 strict cases: recall/list/stats,
remember and forget, each through direct HTTP and MCP, on an existing connection,
a warm reconnect retaining the same host process, and a cold host restart retaining
its stores. All responses were exact permanent denials with no protected data or
success-shaped fallback. Ten existing-channel responses confirmed the structured
`code=unauthorized, retryable=false` form; the remaining cases used the accepted
atom/connector error forms. Protected owner diagnostics were unavailable before
cold negotiation and explicitly recorded as unavailable, never as empty-cache
proof. Positive owner mirror evidence before revocation and after recovery is
mandatory. Recovered direct/MCP results, local row, mirror and tombstone digest
showed no unauthorized mutation. The new sentinel alone was deleted afterward.
This closes the credential-revocation subset, not positive shared-host authorization
or full L13. The first new probe failed an overly narrow exact error allowlist;
its report `revocation-after-upstream-1792502810890882000/report.json` remains
failed and unchanged. Source tracing and an equality-only rerun established the
structured denial; generic error/substrings were never accepted.

The initial supported gateway restart safely refused a process-group mismatch.
Read-only birth/ancestry checks found no current alien member; a supported retry
succeeded without manual signals or identity-record changes. The historical
triggering member is unknown. Both gateway and host were restarted to load the
published dependency before actual qualification.

Current quality checks: `socket-final-credo.log` exited0 after checking1889 source
files, with no issues. Required upstream TODO markers were removed only after
adopting their fixes. `final-local-assets.log` retains passing public/admin asset
builds and digests. The previously proven baseline Router Dialyzer opaque warnings
remain a separate red gate, without waiver. Source/actual subset success does not
make delivery eligible while mandatory shared-authority/L18 and quality gaps remain.

### Published-socket transient outage regression

`oct20-a/socket-transient-after-upstream-1792504038181127000/report.json`
passed after the rejection repair. Before stopping the owned gateway, both
interfaces enumerated the full187-record baseline using bounded100-row offset
pages and owner diagnostics proved the new sentinel was active in the mirror.
The same host process survived the real outage. Direct/MCP recalls returned the
exact sentinel canonical UUID and content in17ms/6ms, with honest offline,
edge_mirror, bounded_stale and stale metadata. Offline direct remember and MCP
duplicate returned the same provisional local ID in3ms/2ms. Starting only the
gateway restored canonical one-copy settlement and pending0 automatically.
The187 pre-existing IDs and owner tombstone digest were preserved; only the two
new records were forgotten. All three endpoints were ready and fault_active=false.
This is a new transport-only positive regression, not complete L18.

Earlier private-driver failures remain failed: case1792503593167701000 stopped
before mutation because a single-page inventory was insufficient; case
1792503855820916000 stopped after the first recall because the driver inspected
`id` instead of the documented mirror `canonical_id`. The latter recovered the
gateway and preserved all187 baseline records. The final driver uses bounded
pagination, canonical identity with conflict rejection, exact content and unchanged
full degraded-envelope criteria. No production behavior was weakened for a pass.

### Reconciled retained evidence

A bounded read-only review closed the remaining correlation gaps for L03/L04:
`oct20-a/reconnect-local-1792477840735322000.json` sequences11–18 contain four
accepted/duplicate event pairs, sequence24 acknowledges them, and
`oct20-a/canonical-1792482001680291000.json` proves exact ordered canonical
projection. Sequences20/21 show one provisional survivor, sequence22 replaces it
with canonical `d6b8faec…` without an overlay, and the sustained follow-up retains
uniqueness for130seconds. No live lost-ACK remember-command fault is claimed.

For L11, the actual pending restart and positive tombstone lifecycle reports,
combined with the subsequently completed fault38 projection19/0 and actual-Turso
23/0 suites, close the explicitly permitted restart/snapshot evidence. The old
post-reopen-assertion-pending wording in historical sections is superseded.
For L15, `oct20-a/provider-recovery-1792438953211579000/report.json` plus
`oct20-a/graph-retry-1792480380851501000/report.json` supply real successful
provider recovery and invalid-structured-output asynchronous stage recovery.
Original failed probes remain failed historical evidence.

The read-only reconciliation initially left L09 partial. The later capture-policy
probe below closes host-local behavior, applied-value/timestamp reporting and
stale disconnected-host labeling; that actual result supersedes the earlier gap.

### Current cold-host acceptance and navigation gaps

`oct20-a/host-first-l01-host-first-002-1792487101748268000/report.json` passed:
gateway stop, host stop, cold host start, fresh provisional remember and capture
ACKs plus duplicate identities while gateway is absent, then gateway start only.
The same host automatically negotiated and supplied owner ACKs; canonical memory
`69c5906f…` and event `d023b324…` exist exactly once. Normal Styx1753 completed
the active session projection with gap0. Original YAML/store identities remain
unchanged and cleanup verified all endpoints ready. Prejoin protected owner
diagnostics are intentionally unavailable; durable ACK/retry behavior is observed
before join and exact owner/canonical state after negotiation. Earlier case001
failed because the driver incorrectly required prejoin diagnostics and passed a
scope to empty-schema stats. Its original report remains failed; separate parent
read-only evidence proved settlement/health without rewriting it. L01 is closed.

The strengthened actual rendered-link inventory
`oct20-a/link-inventory-1792488572306793000/report.json` passed37 links across
Session, Crystal, Lesson and two Memory details: all HTTP200, exact partition
preserved, correct event/session destinations, no unavailable state/page errors.
R1 and R2 Memory Summary links open their immutable linked IDs/revisions with
Historical status, including after R3 supersedes R2. The coordinator visually
inspected the R1 pane. Source58/0, scoped format/diff and dev compile passed.
Original30-link/15-loss failure and the later wrong-fixture driver-preflight
failure remain unchanged. The first actual new-event Graph probe reached dead_letter after invalid provider
edge references, while seven new-version Pipeline rows appeared1174–1545ms.
The separate supported operator retry below subsequently closes Graph mutation
coverage; the original automatic Graph attempt remains failed.

Actual L02 fresh `negative50-002` passed after the bounded routing11 fix and
supported host restart: `negative-parity50-1792487560472647000.json` records all8
paired semantic errors (six invalid arguments, unknown operation, idempotency
conflict), unchanged original content/identity, owner forget ACK and preservation
of20 pre-existing active IDs. Unknown `memory::*` MCP calls now return the same
unknown-method meaning as direct404 instead of forwarding to Hub authorization.
Router36/0, scoped format/diff and dev warnings-as-errors compile passed. Combined
with retained online core, offline pending-write/delete and labeled mirror-read
evidence, L02 is closed. The driver reports only its bounded subset; it does not
claim complete acceptance. Original failed case001 is retained. The independent
cold-authentication subset is now passed by the newer actual report above.

### R3 Graph/Pipeline observation and explicit operator recovery

`oct20-a/open-graph-pipeline-graph-pipeline-001/report.json` retains the failed
300-second automatic Graph probe. A single accepted/duplicate late capture
`33b6b51d…` advanced the exact session to R3 `e411a3c7…`, with11 canonical events.
Source projections completed first; after the configured gap grace and minute
StageResume cron, normal Summary/Episodic/Crystal completed. Seven already-open
Pipeline terminal rows updated1174–1545ms. Graph rejected invalid edge target
references and reached dead_letter; no graph success was fabricated.

`oct20-a/open-graph-pipeline-graph-pipeline-retry-002/report.json` passed the
explicitly **operator-assisted** Graph/Pipeline subset. One supported Admin
Consolidate/retry click, no new capture, caused ordinary GraphExtractWorker1868
to complete the same R3. Eight new graph nodes and18 new edges have whole-session
event provenance. Already-open Graph aggregates updated1532.308ms and Pipeline
terminal state2179.028ms after conservative canonical commit lower bounds. URLs,
partition/domain/document identities stayed fixed, with no page errors/navigation.
Source/session, existing memory/evidence/summary/Crystal/tombstone guards and both
earlier failed reports were preserved. Together with the other retained open-page
and navigation evidence, L08 is closed at these stated evidence levels.

Retry001 stopped before any click because its strict receipt check found the
old capture spool row missing. Source confirms normal ACK compaction may delete
acknowledged rows after60seconds; absence cannot prove this event's ACK or actual
compaction. Retry002 records owner ACK **unavailable**, observednull, and claims
no new L03/transport pass. Its independent UI proof uses the exact canonical
event/revision and original duplicate receipt. Earlier positive L03 owner ACK
coverage remains separate. All original failed reports remain unchanged.

### Current R2 repair, rebuild and policy acceptance

Dev migration00003 and the supported gateway restart passed; the existing host
process remained running. `oct20-a/governance-governance42-005-r2-1792486312871289000.json`
then passed current R2 repair through the trusted Admin form and ordinary Styx.
Both first/repeated repair keys returned dispatched/already_applied. A second
fresh unchanged-R2 repair completed without changing artifact IDs, source sets,
evidence or Crystal links. The stable Crystal `98878f64…` now has current R2
summary evidence while preserving immutable R1 summary history. Both earlier
fact tombstones remain deleted and their hashes have no active semantic candidate.
The actual new provider output did not repeat the exact deleted hash; that
suppression boundary is covered by focused governance regressions, not falsely
claimed as an observed live provider response.

`oct20-a/governance-crystal-ui-1792486302477083000/report.json` passed open-page
Crystal/session refresh in1629ms, preserving URLs/documents and zero page errors.
The earlier late-event report supplies duplicate-safe normal capture and actual
Summary/Episodic/Graph R2 completion; this repair supplied the missing current
Crystal result. Source fencing, stale-worker races, unchanged concurrency and
immutability are covered by the93-test focused suite and1329-test Memory suite.
This closes L06 and L14 at the stated normal-live plus focused-fault evidence level.

The supported `Backplane.Memory.Projections.Rebuild.session/2` function then ran
in a minimal `mix run --no-start --no-compile` controller with only Repo and its
required libraries. No duplicate gateway/Styx supervisor was started. Execution
proof is `oct20-a/governance42-005-r2-rebuild.log` (exit0, current revision, gaps[]),
and the separate read-only checkpoint
`oct20-a/governance-governance42-005-r2-1792486377610561000.json` passed retained
tombstone, unchanged source/evidence/current derived state and active list/recall
absence checks. This is public-function execution, not a claim that the CLI ran.
Together with actual pending-delete/offline-delete/reconnect and positive host
reopen evidence plus focused stale-write/governance tests, L12 is closed.

`oct20-a/capture-policy-l09-capture-policy-001-1792486392635865000/report.json`
passed actual L09 local policy/reporting. With gateway identity unchanged, stopping
the host marked retained reports stale. A host restart with only capture.enabled
false produced fresh applied/report/negotiation timestamps, rejected the valid
synthetic hook with503 and left canonical count0. Finally restored exact original
YAML bytes, restarted the host, observed fresh V2 reporting, accepted and deduped
one restored event, and proved owner ACK plus canonical count1. All pages retained
their documents/URLs and zero page errors. This complements the previously passed
central-stage UI disable/restart/re-enable and actual model-readiness evidence.
Local V1 runtime semantics were not toggled or claimed; the documented central V1
reconciliation gate remains distinct.

### Additional bounded evidence reconciliation

L10 closes from `oct20-a/reconnect-sustained-followup-1792478123796387000.json`
(all capture ACKs, command sequences16–20 done, pending0, unique explicit content,
unchanged host identity and all endpoints ready at130.063s) plus
`oct20-a/channel-stall-1792480416073979000.json` (direct/MCP bounded-stale fallback
5019/5033ms, both writes settled once, fault inactive, mirror ready). Scheduler
suspension supplied the connected stall; no WebSocket proxy injection is claimed.
The original broad-marker reconnect report remains failed.

L17 closes from `oct20-a/ui-edges-1792434239856230000/report.json`,
`oct20-a/partition-appearance-1792479528013856000/report.json`,
`oct20-a/query-failure-1792440199352130000/report.json` and the successful deletion
checks in `oct20-a/governance-ui-1792483620721268000/report.json`. These prove
readable errors, preserved selection/document, pagination, empty/new partitions,
browser reconnect and zero page errors. The overall governance UI report remains
failed. Unchanged-filter automatic backend recovery was not exercised; it is
additional coverage rather than a literal acceptance requirement.

`oct20-a/api-routing4-original-replay-1792435371633587000.json` also proves the
original host-first provisional/canonical identities deduplicate after restart.
A later fresh cold-host-first case closes automatic first join without an
intervening host restart; the original historical failure remains unchanged. L02 paired negative-error parity and L08 exact links/Graph observation subsequently passed; L18 cannot be a second
complete mandatory workflow while L13 remains blocked.

### Actual late revision and open-page refresh

After the stages10 Episodic fix passed70 focused tests and the full Memory
suite1324/0, the supported gateway restart loaded it successfully with all three
endpoints ready. Actual duplicate-safe late capture advanced the quality session
to `f39d2b5477aa5a074577260dc0d12b6925b92b54695e79f00bf12adde80d9468`.
Normal event-gap grace and scheduled stage reconciliation produced Summary1657,
Episodic1658 and Graph1675 at R2. The previously damaged R1 state was not manually
rewritten and no direct Worker calls supplied live outputs.

The already-open page displayed the source revision within1113ms and the new
summary within1629ms, preserving document/URL and selection with no page errors.
UI subset passed; overall governance driver failed after300s because Crystal1659
left a failed R2 stage (`stale_input_revision`) and retained the R1 Crystal.
The schema/provenance adjustment subsequently passed focused93/0, full Memory1329/0 and Admin4/0 tests, dev migration and actual current-R2 repair; see the current section above. The earlier failed report remains unchanged.

Evidence: `oct20-a/governance-governance42-004-resume-1792484688554021000.json`,
`oct20-a/governance-late-ui-1792484679160283000/report.json`, and
`oct20-a/stages11-crystal-canonical-diagnosis.json`. Both previous tombstones and
all earlier failed reports remain preserved. The UI subset result does not turn
the failed overall driver into a pass.

### Governance repair probe and current stage failure

Actual `governance42-003` used the trusted Admin exact-partition repair form.
Both requests affected one session: the first dispatched, and the repeated key
returned already_applied. Host credentials were not granted admin permissions.
The selected fact `34a0bc8a-b06b-4603-8b0c-6ff714b8ee0b` remains tombstoned;
the already-open detail became unavailable within1597ms (conservative bound),
with document/URL preserved and no page errors. The previously deleted
`0cb6fb58-451f-4da5-8bb4-d22abcac4366` also remains deleted.

The overall driver exited1 after its300s bounded wait. Summary1616 and
Crystal1618 completed, but Episodic1617 exhausted four attempts and entered
dead_letter. The source diagnosis found that completed unchanged extraction was
reopened, its existing deterministic request keys conflicted, and continuing
after nested rollback masked the original idempotency_conflict with
transaction rolling back. No late event was sent, so neither full governance nor
late-source browser refresh passed. Inherited stages04 recovery continues with
Sol2/Astra9 completed and Astra10 underway; the task's authorized ceiling is16.

Evidence: `oct20-a/governance-governance42-003-1792483634401211000.json` and
`oct20-a/governance-ui-1792483620721268000/report.json`. Earlier failed probes are
retained. The completed stage's unchanged-output contract must be reconciled
without weakening public remember idempotency or restoring deleted memories.

### Current procedural and lesson provenance review

The reusable operator command was also rerun on the completed quality session:
`operator-1792482458424610000/report.json`. Both unchanged consolidation actions
preserved the revision and artifact IDs; six rendered evidence links preserved
the exact selection, the unknown-session state was readable, and no page errors
occurred. Parent read-only canonical correlation confirms the original summary,
Crystal and seven fact IDs exactly match the page (`canonical-agreement.json`
in that report directory; snapshot `canonical-1792482503655351000.json`). This
supplements L06/navigation evidence; late-output live refresh remains separate.

A fresh bounded read-only canonical snapshot records procedural-v1 complete at
input revision `81b72f4bbbb1793968e4805b747576455a686732fd5b1e25efb15b058e39b5d5`;
ordinary Styx job1504 completed at `2026-10-20T07:01:45.311665`.
The procedures `b0b032d0-3e8c-4066-ac4b-fee18f19d318` and
`cd699466-c646-46dd-9f4c-0203b10b9491` describe enabling the acknowledgment
consumer, retrying the original key, checking one canonical ACK and pending0.
Their evidence includes the reviewed quality-session summary
`13414b4f-e4f9-420f-a449-1e6b456604c8` and five other captured-session summaries.
This is whole-session attribution, not fact-level attribution to each event.

The quality session also produced correction lesson
`ba734cce-8d4f-494b-840d-0108282113ef`, with its actual failed and successful
tool-event IDs linked as derives/supports evidence. It remains an honest
`candidate` with reinforcement0. The earlier lesson
`b9e28b36-70a0-4924-96a1-21ff2726702a` retains12 evidence rows including paired
tool events from four original sessions; it is also a candidate. These are
automatic canonical outputs, not manually inserted final rows or promoted lessons.

Evidence: `oct20-a/canonical-1792482001680291000.json` and
`oct20-a/procedural-provenance-1792482033438150000.json`. The provenance query
selects only bounded fixture procedures and linked source identities.
This review supplements the existing real-provider summary/Crystal/graph proof;
it does not qualify late-event refresh, governance or complete repeatability.

### Authorized local-dev continuation

The user added three times the prior repair allowance and limits this
continuation to verification on this development machine. Cross-machine
verification is deferred; no shared-authority proposal is silently accepted.

Task31 online core flow now passes after cold-loading the host: real direct/MCP
remember retry, canonical settlement, type/agent/facet filters, list/stats,
configured vector recall and canonical forget ACK. Known provisional identity is
retained while canonical mapping is explicit. Both recalls selected the expected
ID once within2048tokens (272used); deletion revision62 and both online lists
absent were observed. All11pre-existing fixture IDs were preserved.
Evidence: `oct20-a/core-parity31-local-resume-002.json`. This supersedes that
driver's earlier failure, not the remaining offline/governance scenarios.

Task29 actual pending-restart subset passed in16.722seconds. Owner diagnostics
proved command/capture pending with attempts0; stopped-store reads and the
restarted owner's connection preserved their identities, the active mirror
generation/revision62 and five existing mirrored targets. Duplicate retries
retained IDs. Original YAML bytes and normal host operation were restored;
normal sync yielded exactly one canonical memory and event, ACKrevision63.
Evidence: `oct20-a/pending-restart-local-resume-l11-002-1792477710142582000/report.json`.
Existing tombstone count was0: positive tombstone survival and interrupted
snapshot visibility remain unproved. This is not a complete L11/L18 pass.

Routing04 source recovery passed158focusedtests and dev warnings-as-errors
compilation. Task29/31 passed65combinedElixirtests plus30/22Pythonchecks.
The actual sustained reconnect subset now passed. A real gateway outage accepted
pending remember, delete-before-settlement, offline forget of an online-created
ID, bounded-stale mirror recall and four duplicate-safe capture events. Normal
reconnection drained all command/capture queues without a host restart. A further
130.063seconds of direct/MCP reads stayed online with pending0 and unchanged host
identity. Canonical read-only evidence confirms events1–4 exactly once, one active
explicit survivor and both forgotten canonical targets tombstoned. New gateway
logs contain no duplicate_join.

Evidence: `oct20-a/reconnect-local-1792477840735322000.json` and
`oct20-a/reconnect-sustained-followup-1792478123796387000.json`. The first probe
failed its overly broad one-marker-result assertion when normal processing
created a Crystal containing the marker. Its retained response demonstrates
that generated artifact; the follow-up checks exact explicit content and identity
while preserving derived rows. This correction is a harness assumption change,
not a production repair or an unrelated-failure waiver. Stalled-channel,
interrupted-snapshot and replay/rebuild/no-resurrection cases remain open.

The task branch is `codex/memory-local-live-acceptance`, based on
`c7044093f0aedcb97434a0c0caba03b864c99bb3`, with uncommitted implementation changes.
The supported devenv provides Elixir1.18.5/OTP28.5.0.6, PostgreSQL17.11 with pgvector,
and native Rust1.95.0. Existing unrelated Postgres.app data was preserved.

The prepared topology uses the owned gateway and standalone host at public `http://localhost:4220`,
Admin `http://localhost:4221/memory`, and host `http://127.0.0.1:4222`.
Use `python3 scripts/memory_local_dev.py status` for current readiness; a running
process alone is insufficient. PostgreSQL socket: `/tmp/devenv-e733526/postgres`.
Primary fixture: host `aab0c6fe-2f0d-459a-ad72-0e6adab53755`, space
`fd3a7e13-ce64-675f-d1fe-9cbe070bf6b6`, scope `memory_local_oct20-a_primary`,
namespace `private`, canonical client `host:aab0c6fe-2f0d-459a-ad72-0e6adab53755`.
Credentials remain only in private gitignored fixture files. A previously exposed
local host token was revoked and replaced; it must not be copied into reports.

All evidence paths below are relative to `.devenv/memory-local-evidence/`:

| Observation | Evidence | Boundary |
| --- | --- | --- |
| Host-first direct/MCP write, same durable provisional ID while gateway port closed before/after | `oct20-a/api-host-first-1792431400368375000.json` | Later settlement/restart remains required |
| Fixture setup repeated twice, then gateway and host cold restart | `setup-repeat-1.log`, `setup-repeat-2.log`, `gateway-cold-restart.log`, `host-cold-restart.log` | Sustained operational and repeatability gates remain |
| Normal resource authentication: unauthenticated chat401, authenticated structured chat200, authenticated embedding200 with2560 dimensions | `oct20-a/api-provider-1792432258125019000.json` | Actual provider subset passed |
| Actual installed Claude session, four lifecycle hooks, canonical events with matching session ID | `oct20-a/runtime-1792432303687863000/report.json`, `oct20-a/canonical-1792432323191173000.json` | Receipts plus canonical correlation; runtime-only session had no tool use |
| Four synthetic captured sessions; each duplicate hook delivery returned original event identity | `oct20-a/api-capture-1792432354096062000.json` | Adapter-level synthetic source alongside the real runtime |
| Automatic Styx processing:36 events,5 sessions,36 memories,11 summaries,1 lesson,5 crystals,32 graph nodes/33 edges | `oct20-a/canonical-1792432432910176000.json` | Bounded snapshot; content/evidence and all terminal stage checks still required |
| Twelve populated operator pages, HTTP200, connected LiveView, no pageerrors | `oct20-a/browser-1792432405117260000/report.json` and screenshots | Page loads only; five-second mutation/navigation still required |
| Two actual same-revision consolidation actions, six evidence links preserving selection, explicit unknown session | `oct20-a/operator-1792432667530621000/report.json` | Stable artifact identities; complete stage repair/idempotency and UI edge-case acceptance remain |

## Current red gates and repaired defects

- Sustained gateway-outage recovery's earlier red: routing recovery4 fixed cold
  dispatch, scoped reads, tuple error formatting, socket-timeout fallback and
  cross-BEAM command fingerprints. The original conflicting request now replays
  with its original IDs. However, a real outage still leads to repeated
  `duplicate_join` disconnects after a transient successful reconnect. Stable L10
  recovery initially remained unqualified. Routing8 and the actual sustained
  reconnect subset above now supersede that failure for the exercised scenario;
  complete stalled-transport and replay/governance qualification remains open.
  Earlier failure logs remain historical evidence.
- L07 useful V2 recall now passes for the retained fixture. Forward migration
  `20261020000002` corrected the source relation without modifying prior migration
  history. Actual direct/MCP exact and paraphrased queries, matching browser traces,
  budgets and current-model vector provenance passed. Historical Qwen vectors
  remain labeled as historical and eligible for FTS; they do not establish
  same-model vector relevance. See the L07 completion and reusable-repeat sections.
- Crystal outputs misclassify a recovered failure as unresolved and omit a real
  pending follow-up. The deterministic fallback overwrites valid empty model
  arrays, and summary input grouping loses event chronology. Additional quality
  repair is now authorized; stages04 source fixes and the fresh captured quality cycle below now pass
  for the exercised outputs. Historical immutable crystals have not been rewritten.
- Graph retry/gate recovery4 passed108 scoped tests, compilation and formatting,
  and the gateway was cold-restarted. Actual UI re-enable restored all four original policies and resumed background
  processing. Two graph revisions failed with `invalid_graph_response` after
  three attempts each. A 127.37-second sample across normal resume ticks showed
  no new graph/window jobs or attempts for exhausted revisions. Retry boundedness
  passed for that interval; graph content and operator recovery remain red/open.
  Existing graph data stays inspectable.
- Current embedding provenance correction passed42 focused tests, compilation and
  formatting. An actual isolated-host new write settled and embedded with the
  selected OpenAI model persisted (`oct20-a/canonical-1792433090329107000.json`).
  Historical vectors were preserved. The later stage recovery explicitly enables
  the master pipeline in its recall integration fixture; no full integration
  suite or full live recall pass is inferred from that change.
- L16 now passes through actual Cron scheduling and gateway Styx execution.
  The initial no-start controller failed timezone readiness before scheduling.
  Its guarded continuation started the configured timezone service and verified
  complete partition identity, daily decay, archive eligibility, strict retention
  cutoff, unchanged nonfixture hashes and scheduler cleanup. Do not rerun the
  successful marker; see the retained L16 report below.

### Actual partition discovery after cold load

The supported gateway restart passed, then installed Chrome observed a new
synthetic host created through Admin while Sessions and Memories were already
open. Sessions discovered it in1444ms; Memories in2377ms. The filtered second
page, selected detail, exact partition and document identity stayed intact with
no navigation/reload or page errors. The newly discovered partition opened with
zero memories and a readable empty state. The new empty host is retained.
Evidence: `oct20-a/partition-appearance-1792479528013856000/report.json` and
three screenshots. This supersedes UI05's earlier live discovery failure,
without asserting that every L08/L17 scenario has passed.

### Fresh captured quality and configuration cycle

The fresh9-event session `memory-local-oct20-a-quality-1792479580117825000`
was accepted through normal Codex capture hooks; duplicates preserved all IDs.
Disabling session summaries through Config prevented generation for65seconds
(the configured grace is60seconds). A supported gateway cold restart preserved
the disabled value. Restoring the original enabled value resumed normal Styx
processing and produced summary `13414b4f-e4f9-420f-a449-1e6b456604c8`, seven
semantic facts and model-enriched Crystal `98878f64-3176-4171-aa9f-e4b6406b0556`
with the same canonical source revision. Coordinator content review confirms
failure precedes verified recovery, accepted PostgreSQL canonical ownership is
retained, and only the outstanding export-screen accessibility review remains
unresolved. The initial missing acknowledgment is correctly resolved.

Graph generation failed its three bounded attempts and reached dead-letter;
the fixed rejection diagnostic is `node_type`. The probe exits1 rather than
promoting the existing artifacts into a complete processing pass. All original
settings were restored and all endpoints were healthy afterward. Evidence:
`oct20-a/quality-1792479580117825000/report.json` and
`parent-quality-review.json`; actual the subsequent strict-schema retry below passed.

### Strict-schema graph recovery and connected-stall acceptance

Stages04 Astra9 now requests strict graph JSON Schema with the existing exact
fields/type/relation enums. Local validation remains strict; provider rejection
does not silently downgrade. After loading the new gateway, the actual session
Consolidate button retried the failed quality-session graph through normal Styx
and the configured real provider. Graph completed at the original summary input
revision; original summary, seven facts and Crystal IDs were unchanged. A second
completed unchanged action preserved summary/fact/Crystal/node/edge identities.
Bounded nodes/relations and source-event provenance are retained for inspection.
Evidence: `oct20-a/graph-retry-1792480380851501000/report.json` and
`completed-session.png`. This supersedes graph failure for this fresh session;
it does not rewrite older dead-letter revisions.

The parent then paused only the birth-verified owned gateway BEAM, with a separate
20-second identity-checked resume watchdog. Direct recall returned in5019ms and
MCP recall in5033ms, both labeled offline/bounded_stale with five mirror results.
During each stall, repeated direct/MCP remember retained one provisional ID.
After resume, each command settled exactly once; queues drained and host process
identity remained unchanged. All three endpoints were ready afterward. Evidence:
`oct20-a/channel-stall-1792480416073979000.json`. This is an explicitly labeled
scheduler-pause connected-peer fault, not a WebSocket proxy test.

The supported gateway restart command returned exit1 with an ownership mismatch
after launching the replacement gateway67499. Read-only birth/group checks then
confirmed ownership and readiness. No unsafe adoption or signal bypass occurred;
this lifecycle harness failure is under separate diagnosis (lifecycle37) and
blocks full lifecycle acceptance despite the successful live probes.

### Positive edge tombstone and supported lifecycle rerun

The repaired lifecycle harness completed a gateway restart (exit0,16.302s) and
two host stop/start cycles (each exit0). A fresh explicit synthetic target was
first observed in the actual negotiated mirror, then canonically forgotten.
With the host fully stopped and4222closed, a read-only existing mirror query
proved its active-generation row is `deleted`, has no content and server
revision102. After the real host reopened and remained online, a second stopped
read retained the same positive tombstone, revision102 and active generation.
The final start retained canonical absence; original YAML bytes were unchanged
and all three endpoints were healthy. Evidence:
`oct20-a/tombstone-lifecycle-1792481067911339000/report.json`.

This closes the positive **edge mirror** tombstone restart gap for the retained
fixture. The older command-store tombstones table still had zero rows in its
separate pending-restart run; the two stores are not conflated. No incomplete
snapshot was injected into this running host; real-Turso interrupted-snapshot
coverage remains separately labeled component evidence.

### Latest scoped source validation

UI05 discovery regressions now pass12tests/0failures, with scoped formatting
and dev warnings-as-errors compilation. Stages04 quality/compatibility scope
passes144tests and50adjacent graph/stage/concurrency/repair tests. The whole
Memory app run is **1317tests,1failure** (seed813610): eviction candidate-order
assertion at `eviction_worker_test.exs:108`. Its deterministic cross-second DateTime ordering defect was subsequently
reproduced and corrected in the test only (6/0); production eviction is unchanged.
The full suite has not yet been rerun, so no full-suite pass is inferred.
Evidence: `ui05-repair3-green.log`, `stages8-tests.log`,
`stages8-adjacent-tests.log`, `stages8-memory-app-tests.log`.

Governance36 source review additionally found a new-revision derivation gap:
identical keyed retry returns the original tombstoned row, but a new summary ID
changes automatic extraction keys and can insert a same-fact replacement.
A deterministic regression and bounded captured-subject suppression are now in
implementation. Fresh explicit remember and independent source subjects must
remain possible; archive semantics remain distinct from forget. This gate is
open until regression and actual replay/rebuild checks pass.

### Historical failed actual token revocation

This retained older-dependency failure is superseded for current credential
rejection by the passed30-case report above; its original evidence stays failed.

The parent created a replacement token privately through Admin, populated the
real mirror with a synthetic protected sentinel, then revoked the configured
token through the actual assigned-token Revoke action. Both direct and local
MCP recall on the existing connection still returned the sentinel as
online/canonical. After a supported host restart with the revoked credential,
both interfaces instead returned offline/provisional_only success with zero
results, rather than the required authorization denial. The cold case does not
prove protected mirror content leaked; the original connected case does.

Evidence: `oct20-a/revocation-1792481418021470000/report.json`. This exposes a
real gap beyond the previously passing stub-denial and fresh-socket revocation
tests. The replacement credential was restored privately to the same YAML with
host/store identity preserved; both restart operations returned0, fault_active
is false and all endpoints are healthy. At that point Routing04 Astra9 continued within the inherited allowance and
credential rejection blocked L13. The later published fix and actual rerun above
close this specific gap; shared authorization remains incomplete. No cross-machine
validation is proposed.

### Combined Memory and fault-chain verification

After governance36 and fault38 source freeze, the whole owning Memory suite
passed **1324tests,0failures**, seed573321 in176.9seconds. Scoped format checks,
dev warnings-as-errors compilation and whitespace checks passed. The earlier
1317/1 run is historical; its eviction ordering test defect was repaired without
changing the production worker. Focused governance coverage passed76tests;
actual-Turso mirror coverage passed23tests and projection/fault coverage19tests.

The new fault chain uses a real unboxed test database commit, not a shared
sandbox savepoint: an independent backend observes the accepted event, durable
repair frontier and Styx job; the synthetic caller is killed before ACK delivery;
retry keeps the original event and exactly one scheduling commitment. The failed
commit control also leaves no event, frontier or job. A physically reopened
Turso store now explicitly exposes only the old generation/revision before the
final snapshot chunk. These are fault/integration tests, distinct from normal
live happy-path evidence. Logs: `fault38-focused.log`, `fault38-memory-app.log`,
`fault38-format-check.log`, `fault38-dev-compile.log`.

The combined Python harness suite passed127tests, exit0, but Python3.15 exposed
an unraisable SQLite ResourceWarning in a test fixture. The fixture now closes
the committed connection explicitly; its scoped30tests passed with warnings
promoted to errors (`fault38-python-pending-restart.log`).

## Containment history and current lifecycle limits

Earlier graph investigation found repeated new jobs after retry exhaustion for
one unchanged source revision: 55 attempts and 18 discarded jobs. The subsequent
Astra4 recovery bounds terminal retries and checks the actual graph gate before
provider calls and persistence. Scoped tests and later live boundedness sampling
passed; the later strict-schema operator retry below passed real-provider graph content and revision checks for the fresh quality session.

The coordinator temporarily disabled graph generation, dual write, events and
the master pipeline through the supported Config UI to contain provider calls.
**Containment has ended. All four original gates are restored to true**, verified
through UI and persisted Settings. The latest read-only confirmation is
`oct20-a/pipeline-persistence-1792438411705074000.json`; both services were ready
in `oct20-a/current-runtime-1792438402418611000.json`. Earlier containment artifacts
are historical evidence, not instructions to leave the pipeline disabled.

The dev harness now records ancestry-proven descendants and validates every live
process-group member before cleanup.18 synthetic tests passed, including detached
HTTP listener cleanup, unrelated process preservation and stale identity refusal.
Actual current process ancestry was captured without signaling. The actual legacy-host stop then raised an ownership-changed refusal after partial
signaling. Follow-up verified all seven original host processes gone and4222closed;
a second supported stop reconciled state. This remains a failed first-stop gate,
with bounded Astra recovery queued. The subsequent22-test Astra recovery handles confirmed member disappearance
and ESRCH while retaining live ownership checks. Gateway restart passed, and
both services are again running. A host stop probe removed all original processes
but aborted on a transient500ms peer HTTP check; final full-cycle proof remains. The separate isolated host was explicitly stopped
after verifying dedicated store ownership; its earlier leaked listener establishes
the lifecycle defect rather than a passing harness stop.

Earlier recall requests exposed `memory_recall_candidates_canonical_partition`
identity and source-relation defects. The forward migrations and subsequent
bounded model/deadline recovery were applied and live-qualified. These historical
errors no longer describe the current L07 state. The later actual sustained-outage subset above supersedes the exercised
`duplicate_join` failure; remaining stalled-channel and snapshot gates are open.

## Acceptance matrix

| ID | Current evidence / remaining gate |
| --- | --- |
| L01 | Passed: freshcase002 cold host durably accepts/duplicates remember+capture before gateway; gateway start alone produces automatic join, ownerACK, exactly one canonical memory/event and normal Styx session projection. Host identity unchanged through join; exact YAML/store identities and all endpoints healthy. |
| L02 | Passed combined local evidence: direct/MCP retry identity, accepted type/agent/facets, list/stats, real-vector recall and canonical forget ACK; actual outage pending write/delete and labeled mirror recall; fresh negative50-002 all8 paired errors passed with original identity/content and pre-existing records preserved. |
| L03 | Passed: actual duplicate hook replies retain four event IDs; owner diagnostics acknowledges all four; canonical snapshot proves each exactly once in sequence1–4, completed session/gap0 and nine completed projection states at revision942f… . Real runtime hooks supplement the synthetic workload; committed-event/lost-ACK coverage is a labeled focused fault test. |
| L04 | Passed live postcondition: direct/MCP provisional survivor remains visible once during outage, then becomes one canonical result without overlay after settlement;130seconds sustained reads retain uniqueness/pending0. An injected accepted-but-unacknowledged remember-command retry is not claimed as live-qualified. |
| L05 | Passed retained-fixture automatic processing with source order,7facts, readable summary and model Crystal; graph initially failed node_type, then strict-schema operator retry completed the same revision while preserving original artifacts. Fresh procedural-v1/normal Styx1504 evidence and reviewed concrete summary links establish eligible model procedures; actual paired tool-event links establish the correctly labeled candidate correction lesson. Graph recovery required an operator retry; L06/L14 remain separate. |
| L06 | Passed: actual trusted Admin exact-partition repair dispatch/repeated-key already_applied, normal Summary/Episodic/Crystal completion, failed-current-Crystal recovery and fresh unchanged repair preserve exact source/artifact/evidence identity. |
| L07 | Passed for retained fixture: direct/MCP exact+paraphrase all hit current-model preference in1.7–2.7s; realvector succeeds,104persisted candidates have consistent vector labels/typed sources;4matching browser traces show model, selected/excluded candidates and token budget with0pageerrors. |
| L08 | Passed combined local evidence: open Memories2328ms, Session1113–1629ms, Crystal1629ms; seven normal new-revision Pipeline rows1174–1545ms; explicit operator Graph retry observed1532ms/terminal2179ms;37 exact provenance links. Selection, filters/pagination and document identities retained. Original automatic Graph/provider failure remains failed. |
| L09 | Passed: central stage UI gate changes real behavior and persists across gateway restart; restored gate permits ordinary processing; actual model readiness observed. Policy47 proves local capture disabled behavior, fresh applied/report/V2 timestamps, stale retained disconnected-host labels, exact YAML restoration, owner ACK and canonical exact-once recovery. |
| L10 | Passed against the required local outage/stall/reconnect behavior: durable capture/commands, labeled bounded-stale fallback, automatic reconnect/queue drain,130seconds stable online identity, no new duplicate_join; connected-stall direct/MCP fallback and exact-once settlement passed. Fault mechanism limits remain below; interrupted snapshots are covered under L11. |
| L11 | Passed at permitted mixed evidence level: actual pending command/capture restart preserves identities, generation/cursor/targets and settles once; actual host close/reopen preserves positive deleted/content-absent edge tombstone revision102. Focused actual-Turso fault coverage physically reopens an incomplete snapshot and keeps the prior generation visible (23/0), supplemented by19/0 projection/lost-ACK tests. |
| L12 | Passed: online browser delete, offline forget and delete-before-settlement survive reconnect/host reopen. Actual R2 normal repair, unchanged retry and supported targeted projection rebuild retain both tombstones and active-read absence; focused governance/stale-write tests supplement exact fault boundaries. |
| L13 | Passed local-development composite: independent read/deliver/remember/forget, isolated denial, withdrawal, leases, disconnected revoke/cold closure, newer regrant rejecting old intents, provenance/audit and retained data. Exact races are current deterministic tests; full unrelated alias history is not claimed. See the current composite assessment above. |
| L14 | Passed at normal-live plus focused-fault level: duplicate-safe late capture advances sequence9→10/current frontier; normal Summary/Episodic/Graph and repaired Crystal match R2, links include new source and retain history; unchanged repair deduplicates. Focused stale-worker/concurrent-revision tests prove newer state cannot be overwritten. |
| L15 | Passed: actual provider outage preserves useful lexical recall and honest vector provider_error; exact UI configuration restoration restores real-vector success. Invalid structured graph output reaches bounded dead_letter, then browser retry through normal Styx/real provider completes the same revision with original artifact IDs preserved. |
| L16 | Passed: actual Cron roots523/524, gateway-executed decay child525 with complete five-field partition, retention continuation526; daily decay once, only archive target archived, strict cutoff boundary and unchanged nonfixture hashes. Report l16-live-001-resume-astra1.json. |
| L17 | Passed for all named edge cases: unknown/deleted details, empty/new partitions, pagination, browser reconnect and readable query failure with selection preserved; corrective-filter recovery passed. Sessions/Memories partition discovery1444/2377ms,0pageerrors. Automatic unchanged-filter transient recovery is additional unexercised coverage, not a requirement added to the objective. |
| L18 | Passed composite local-dev: repeated retained workflow and cold host/gateway restarts,117 Graph/Pipeline recovery,121 attributed provenance preservation,127 exact audited normal-worker recovery and independent final proof, parent scheduler-delta review and owned-process cleanup. Original failures remain retained; no cross-machine claim. |

## Preparatory commands and observed results

These commands do not satisfy a live scenario:

- `git status --short --branch` and `git rev-parse HEAD`: confirmed clean baseline before creating the task branch.
- `git switch -c codex/memory-local-live-acceptance`: task branch created successfully.
- `mix deps.get` with the existing devenv profile on PATH: completed with the locked dependency versions unchanged; no lockfile edit.
- Fresh `devenv shell` provisioning completed successfully. Tool locations and versions were checked inside the shell rather than inferred from PATH outside it.
- `devenv up postgres`: initialized the dedicated project cluster and both project databases; readiness probe succeeded. The long-running service remains owned by the existing process session.
- `devenv shell -- sh -c 'MIX_ENV=test mix ecto.migrate'`: passed (exit 0). Log: `.devenv/memory-local-evidence/test-migrate.log`. This proves migration setup, not live gateway acceptance.
- Initial startup regression attempts failed before ExUnit because dependency directories were stale, then because the system Cargo executable could not run (`Bad CPU type in executable (os error 86)`). Downloaded native Nix Cargo/Rust 1.95.0 passed version checks and compiled the dependency.
- Meaningful startup red: from `apps/backplane_host_agent`, `../../.devenv/profile/bin/mix test test/mix/tasks/agent_run_test.exs test/backplane/host_agent/worker_test.exs` with native Cargo/Rust on PATH reached 27 tests, one expected failure. Worker ignored the supplied config and HTTP observed absent memory policy.
- Initial startup implementation routes the real task through Worker-owned connection/runtime initialization, honors explicit config across retries, and publishes policy before HTTP starts. Its new regression passes. The same 27-test suite still fails one existing real-store startup because `ex_turso.so` cannot load: `mis-aligned LINKEDIT string pool, fileOffset=0x019E3C64`. A coherent devenv toolchain rebuild is pending; the suite is **not passed**.
- Follow-up: `devenv shell -- sh -c 'MIX_ENV=test mix deps.compile ex_turso --force'` passed. Plain Elixir loaded `Turso.Native` successfully. Re-running both startup files in the full shell passed **27 tests, 0 failures**; see `host-startup-devenv-green.log`. The earlier loader failure was resolved by using the complete supported toolchain.
- Config, LLM, graph extraction, search expansion and expand-query Service tests passed **46 tests, 0 failures**. These exercise real database writes and `Req.Test` provider responses; they do **not** prove real provider connectivity. Log: `llm-02-focused.log`.
- Lifecycle harness safety tests passed independently: `python3 -W error::ResourceWarning -m unittest discover -s scripts/tests -p test_memory_local_dev.py`, **11 tests**, exit 0. These use disposable Python processes; the real devenv lifecycle remains unverified. Log: `dev-harness-review.log`.
- New Memories LiveView tests passed **4 tests, 0 failures** after reproducing missing-detail, session-filter and stale-page defects. They check automatic bounded refresh, later inserts and canonical forget. The first deletion fixture incorrectly set only `deleted_at`; it was corrected to use the normal domain forget operation. This is ExUnit evidence, not browser acceptance. Log: `ui-inventory-green.log`.
- Formatting of the three startup-owned files and `git diff --check`: passed. These do not establish application compilation or live behavior.

Transient diagnostic logs: `.devenv/memory-local-evidence/host-startup-red.log`, `host-startup-green.log` and `postgres.log`. They are gitignored and are not a sanitized final evidence bundle.

## Evidence still required

Assign a unique run ID, register two isolated hosts/spaces, record their nonsecret identities, and retain stable command/event IDs. Capture direct/MCP response bodies, canonical stage/job revisions, real provider success, browser screenshots and observed refresh latency. Fault tests supplement the live scenarios and must be labeled separately.

Do not use direct inserts of derived memory rows, manually performed workers, forced PubSub messages or mocked providers as happy-path evidence. Restore the healthy provider/fixture policy after fault injection. Release remains blocked until the required validation and all mandatory local scenarios pass.

Resumption and ownership: [local-dev-checklist.md](local-dev-checklist.md).

## Artifact content audit

A read-only source comparison is retained at
`oct20-a/artifact-quality-review.json`. Session4's completed crystal puts the
explicit certificate-rotation-owner follow-up in `key_outcomes`, omits it from
`unresolved_items`, and retains a historical missing-acknowledgment tool failure
as unresolved despite the later successful verification. All sampled crystal
`decisions` arrays were empty. This does not pass the requested content-quality
gate; counts, `complete` states and a model label are insufficient.

The canonical session/window summaries inspected here explicitly report
`generation_mode=deterministic`. The earlier automatic-processing evidence must
not be read as a claim that these summaries were model-generated. Crystal
narratives and extraction do use the configured model where marked; exact source
support and useful output fields remain required.


## Latest routing and browser subset

The authorized routing recovery passed229host+109API tests. A new direct/MCP
remember settled canonically; matching scoped list worked. After an actual host
restart, replay returned the same provisional and canonical IDs. Evidence:
`oct20-a/api-routing3-new-command-1792434236900483000.json` and
`oct20-a/api-routing3-settled-restart-duplicate-1792434375045459000.json`.
However, exact replay of the older host-first command returned400
`idempotency_conflict` (`oct20-a/api-write-1792434213085588000.json`). A separate
fresh-BEAM reproduction shows the current atom-keyed-map JSON fingerprint is
load-order-dependent. Exact old stored-hash attribution remains unverified because
the running command store rejected bounded read-only access. Further same-task
repair requires explicitly expanded budget; no duplicate gate is waived.

The corrected browser guard passed pagination, unknown detail, and reconnect in
999ms, retaining exact URL/document marker/time origin with zero navigation
requests. One same-document history event occurred. A deliberate actual reload
was correctly rejected. Evidence:
`oct20-a/ui-edges-1792434239856230000/report.json` and `browser18-astra-*` logs.
The isolated empty-state case was explicitly skipped because it now has one record.
This is partial L17, not complete browser qualification.


Latest open-page mutation observation:
`oct20-a/browser-1792434411902966000/report.json` passed12pages with zero page
errors; a new canonical memory appeared2328ms after the host request, without
reload. This runs under the documented paused processing profile and does not
establish model-stage refresh on every page.

Actual host stop/start subsequently passed:
`oct20-a/harness-host-cycle-bounded-1792434510816315000.json`. All original host
processes exited, the gateway retained its exact identity, public/admin stayed
ready, and all three endpoints were ready after restart. The former isolated
listener4223 is closed. `oct20-a/final-runtime-1792434543166490000.json` records
owned listeners and kernel birth identities; later operations may supersede PIDs.

Latest bounded snapshot `oct20-a/canonical-1792434512927469000.json` includes37
events. The late event is canonical and the selected session sequence advanced
8→9 with a new input revision and matching completed repair frontier. Derived
summary/model stages remain paused; full L14 is not passed.


### Failed outage and explicit-memory detail probes

The actual gateway outage accepted durable duplicate direct/MCP writes but
rejected recall with `reconnect_failed/socket_timeout`; Syncer error formatting
raised Protocol.UndefinedError on a tuple and the host exited. The coordinator
restored the gateway and restarted the host; the durable command then settled
exactly once with zero pending operations. This proves persistence across this
failure, not automatic recovery or complete L10/L11. See
`oct20-a/api-real-outage-subset-1792434640686779000.json` and
`oct20-a/api-outage-crash-restored-settlement-1792434723957942000.json`.

An online-forget browser probe failed while opening an explicit memory with no
session, before invoking forget. The unconditional Session route raised during
LiveView render. No deletion was performed; L12 remains incomplete. See
`oct20-a/browser-forget-1792434773414185000/report.json`. Both defects retain
their existing task identities and repair counters.


The explicit-memory detail fix subsequently passed6scoped tests, compilation and
format checks. Actual browser recheck loaded the nil-session detail, accepted a
host forget (honestly reported pending canonical acknowledgment), then observed
committed disappearance within2307ms on the same document/URL. Active online API
inventory returned0rows and the deleted deep link rendered a readable unavailable
state. Evidence: `oct20-a/browser-forget-1792435100526651000/report.json` and
`oct20-a/api-online-forget-browser-1792435114599071000.json`. This supersedes the
initial detail crash for this path, not the remaining full L12 gates.


### Routing recovery recheck

Astra recovery4 passed204focused hosttests, compilation and formatting. After
actual host restart, the original previously-conflicting write replayed via
bothdirect/MCP with its original provisional/canonical IDs
(`oct20-a/api-routing4-original-replay-1792435371633587000.json`).

The repeated real gateway-outage probe now passed its bounded subset
(`oct20-a/api-real-outage-subset-1792435421863918000.json`): offline write
accepted once with matching direct/MCP provisional identity; offline recall
returned two actual mirror hits with `bounded_stale`/stale metadata; four local
capturehooks retained IDs on duplicate submission. Once the gateway restarted,
the host automatically reconnected and the command settled to one canonical row,
pending_operations0. Its root PID39198 and kernel birth identity were unchanged
across the outage (`routing4-post-outage-identities.json` compared with
`routing4-live-host-restart.log`). All three endpoints are ready. This supersedes
the earlier automatic-recovery crash for this subset only; processing remains
paused and stalled transport, pending host restart, complete capturedrain and
snapshot integrity are not yet qualified.


### Superseding stable-recovery failure

The immediately successful bounded outage observation was not stable. Later
requests remained in offline mirror mode despite healthy HTTP endpoints, and
an online pending remember+forget did not converge within30seconds. Gateway
logs show repeated `shutdown/duplicate_join`. The sanitized count/timestamps are
in `oct20-a/routing4-duplicate-join-followup.json`; API evidence is
`oct20-a/api-delete-before-settlement-1792435539948323000.json` and
`oct20-a/api-pending-delete-followup-1792435573794770000.json`. L10 remains
failed, L12 incomplete. No further routing repair is authorized at Sol2/Astra4
until the pending extra-budget question is answered. The four outage capture
IDs did all reach canonical events in source_sequence1–4, confirmed by
`oct20-a/canonical-1792435464534405000.json`; that does not waive recovery failure.


### L16 scheduled-policy follow-up

The reusable controller `scripts/memory_local_policy.exs` passed9 pure safety and
timezone regressions and a supported-shell read-only preflight
(`oct20-a/l16-preflight-003-repair2.json`, exit0). Actual invocation
`l16-oct20-a-live-001` exited1 with `cron_timer_timeout`
(`oct20-a/l16-live-001.json`, `l16-live-001.log`). It created two source Lessons
through the real host API and explicitly labeled eligibility clocks/activity
inputs. No final derived rows were inserted. The independent scheduler had no
queues, its timezone-dependent database leadership failed, no policy jobs were
inserted, and the scheduler was stopped. Existing gateway/host processes were
not restarted. The retained targets and inputs require a validated continuation;
do not repeat this marker or treat setup receipts as completed policy effects.
Bounded controller recovery is in progress, preserving cumulative Sol2/Astra0.


The bounded Astra1 recovery starts the existing timezone prerequisite before
controller work and adds strict continuation fencing.12 tests, compilation,
formatting and read-only resume preflight passed. Parent actual continuation
`oct20-a/l16-live-001-resume-astra1.json` exited0 with status `passed`: Cron roots
523/524 and children525/526 completed on gateway node `mbp2021`, each attempt1
with no errors. Decay child525 retained all five partition fields. Both Lessons
received exactly0.05 decay_rate increase, confidence unchanged; only the old
target became archived. Retention deleted only the cutoff-minus-one activity
rows, retained cutoff/cutoff-plus-one rows, and executed its continuation.
Nonfixture hashes and service identities were unchanged, protected fixture
controls were preserved, and the temporary scheduler/peer were removed. This
supersedes the earlier controller failure for L16, whose evidence is retained.


### Restored policy and V2 trace reproduction

Actual browser report `oct20-a/pipeline-restore-1792436898537150000/report.json`
records pipeline/events/dual-write/graph restored to true with no page errors.
`pipeline-restored-persistence.json` confirms all four stored values. Normal jobs
advanced the snapshot to54memories/15summaries/6crystals. Graph failure states
remain and require boundedness/content checks.

The first actual V2 recheck (`api-v2-recall-live-1792436936996599000.json`)
returned bounded-stale mirror data after a channel failure, without recall_run_id.
The probe correctly records failure. The applied candidate guard function uses
`memory_remember_requests`, but its owning canonical table is
`bpm_memory_remember_requests`; the minimal test fixture duplicated the bad name.
A forward migration and real-name regression are being validated. No V2 useful
recall/trace success is claimed from this probe.


The forward guard repair passed20tests/compile/format, applied successfully to
dev, and gateway cold restart exited0. Actual V2 recheck
`oct20-a/api-v2-recall-repair2-1792437215524516000.json` now saves online traces:
exact query matches the expected OTP preference (1580 of2048tokens); paraphrase
returns0hits. FTS succeeds; vector times out at~1000ms in both, graphunavailable.
Actual browser report `oct20-a/recall-trace-browser-1792437245320924000/report.json`
loads both matching trace IDs/queries with visible timeouts and zero pageerrors.
This proves trace persistence/inspection and useful exact retrieval, not complete
L07. The same task retainsSol2 and enters its first bounded Astra recovery for
the unresolved real recall deadline/relevance gate. No routing/stage extra budget
is inferred.

Terminal scheduling observation after restoration: across127.37seconds and normal
StageResume ticks583/584, graphjobs28→28 and windowjobs251→251; deadletter revisions
and attempts64/6 stayed unchanged. `stage-boundedness-comparison-1792437162543547000.json`
references all three snapshots. Existing jobs531/549 each exhausted3attempts with
`invalid_graph_response`; job565 is a different session and completed attempt1.
This passes boundedness for the observed interval while graph response quality
and full operator recovery remain red.


### L07 useful-recall completion for the retained fixture

The bounded recovery passed64focused tests, owning warnings-as-errors compilation
and six-file format/whitespace checks. The earlier64/1 run failed because an
unknown-model test fixture retained the schema's Qwen default; explicitNULL
corrected that fixture without weakening its assertion. The final task counters
areSol2/Astra2(max2); source writes stopped before parent livechecks.

The finite default retrieval deadline is now12seconds, below the30second host
tool-call budget and above the10second embedding receive timeout. The selected
Settings model is pinned once across embedding, vector filtering and trace.
Model filtering occurs before ranking/limit; old or unknown labels remain
FTS-eligible, with no historical relabeling.

After parent coldgateway restart (exit0), actual direct/MCP exact and paraphrase
queries all returned online with successful real vector retrieval, matching
preference `b939abb3-1d42-4350-a30c-f36bb9164d81`.
`oct20-a/api-v2-recall-astra-final-1792437824377055000.json` records1738–2717ms,
606tokens for exact and269for paraphrase under2048. Paraphrase FTS returned0, so
its expected result depended on the successful vector channel. Exact and
paraphrase selected identities agree across direct/MCP. No entity hints were
supplied, and graph honestly reports unavailable; this does not qualify graph
content or the separate L05 gate.

`oct20-a/recall-vector-labels-1792437849725027000.json` verifies4complete runs,
correct querymodel,104candidates, all vector-ranked candidates matching selected
OpenAI model, typed provenance and bounded tokens. Actual browser screenshots/
report `oct20-a/recall-final-browser-1792437866396299000/report.json` match all4
query/trace/model identities, selected target, excluded candidates, source refs
and token budgets, with no pageerrors. This supersedes the earlier L07 failures
for these exact/paraphrase fixture queries; it is not a broad recall benchmark.


### Reusable L07 API/browser repeat

Task `memory-recall-live-driver-20` adds a standalone `recall` phase and optional
browser `--recall-report` input. Parent reviewed the implementation and executed
both commands against the retained running fixture. Fourteen focused Python
tests, Python compilation and tracked whitespace checks passed. No production
repair budget was consumed (Sol0/Astra0).

`oct20-a/api-recall-1792438285143881000.json` records four successful online
exact/paraphrase direct/MCP cases, real vector status `ok`, expected knowledge,
1726–1966 ms elapsed, and 606/269 tokens within 2048. Preference inventory remained
stable and selected IDs matched across interfaces. The expected IDs were
resolved through supported fixture-scoped listing, without hardcoded fixture IDs
or database reads in the driver.

`oct20-a/browser-1792438295587100000/report.json` passed the twelve-page browser
subset and all four matching trace inspections with zero page errors. Each trace
showed matching query/partition, expected selection, typed provenance, excluded
candidates and the correct token budget. The script recorded the visible model
but did not automatically compare it because the API report supplies no expected
model. Parent separately checked all four canonical trace rows and browser values:
each was `memory-local-oct20-a/openai/text-embedding-3-large` and complete.
Canonical snapshot `oct20-a/canonical-1792438303187660000.json` retains 41 events,
61 memories, 15 summaries, 3 lessons, 6 crystals, 37 nodes and 40 edges.

The reusable repeat confirms L07 for these fixture queries. It does not qualify
all vector-label provenance, graph quality, full recovery or L18 second-fixture
repeatability. Overall remains INCOMPLETE; required red gates prohibit release.


### API Memory integration verification after L07 recovery

The required focused integration command completed successfully:

```sh
devenv shell -- mix test apps/backplane_api/test/backplane/api/host_agent_sync_e2e_test.exs apps/backplane_api/test/backplane/api/memory_v2_edge_qualification_test.exs
```

Result: 12 tests, 0 failures, exit 0; log `api-memory-integration-21.log`.
This covers protocol/sandbox scenarios including negotiated snapshots, durable
ACK/restart, denial without mirror fallback, canonical delta/delete convergence,
mirror eviction and provisional command settlement. It remains test evidence;
it does not replace the still-required actual live outage, pending restart,
revocation, snapshot-interruption and governance scenarios.


### Required qualification command: failed CI profile

```sh
devenv shell -- env MIX_ENV=test mix memory.qualify --profile ci --report .devenv/memory-local-evidence/memory-qualify-ci-21.json
```

Exit 1; `memory-qualify-ci-21.json` and `.log` retain the failure. The CI profile
is not an authoritative performance run. Ingest accepted/persisted 1800 of 2000
expected events, with only 18 durable projection jobs/frontiers for 20 sessions.
Its 1308 events/second exceeded the numeric rate threshold, but the complete
ingest gate correctly remained false. Consolidation coverage was 0/20. Accepted
event integrity, projection lag, simulated outage and contention/retry gates
passed. This is an additional red delivery gate; causes are under read-only
investigation. No threshold, production behavior or prior repair budget was
changed to conceal the failure.


### L15 embedding failure/recovery subset

The reusable provider-recovery command in the runbook passed actual execution,
exit 0, in 66.6 seconds. Eight focused safety tests also passed. Evidence:
`oct20-a/provider-recovery-1792438953211579000/report.json` and cropped screenshots.
It kept the original configured model and provider enabled, changing only the
fixture provider's URL path on its existing OpenRouter origin through Admin UI.
No mocked response or alternate credential destination was introduced.

Both direct/MCP fault-phase recalls stayed online with FTS status `ok` (9
candidates), expected knowledge selected and vector status `error` (0 candidates),
in 783/987 ms. Matching trace pages reported vector `provider_error` and FTS
available. The Memory API does not expose the actual upstream HTTP status; no
specific 404 or response-body claim is made.

The original URL was restored in `finally`; before/after full-form SHA-256 hashes
matched. Four restored direct/MCP exact/paraphrase calls had successful real
vectors (22 candidates), expected fixture hits, 1741–1949 ms elapsed and 269/606
tokens within 2048. All six failure/recovery browser traces matched the actual
query, partition, current embedding model, budget and selected typed provenance;
zero page errors occurred.

Independent read-only confirmation `oct20-a/provider21-restored-1792439049406841000.json`
found the original provider URL/enabled flag, no runnable EmbedWorker jobs and
all four original pipeline/event/graph gates true. Canonical snapshot
`oct20-a/canonical-1792439038019817000.json` retained the same 41 events, 61
memories and derived inventory; only the expected eight recall records increased.
This passes the embedding/lexical recovery subset, not the complete L15 stage
failure/recovery scenario. No additional production repair budget was used.

Public/admin asset deployment also passed, exit 0:
`devenv shell -- mix assets.deploy` (`memory-assets-deploy-21.log`). This proves
asset compilation/digests, not release publication or completion of other gates.


### Qualification harness correction and fresh CI result

The failed CI run exposed a qualification fixture policy omission. In a private
rollback sandbox, two eligible sessions produced zero summaries and exactly two
`skipped_disabled` states because both pipeline/session-summary gates were false.
The production worker correctly enforced policy; the unchanged qualification
runner never opted in. The runner now enables only those required test policy
keys around consolidation and restores exact prior ETS entries in `after`,
including absent entries, false/true values and raised-error paths. No production
worker, configuration consumer or ingestion implementation changed.

The report now retains requested/result/accepted/persisted counts and sanitized
status/reason/retryability distributions for both warmup and measured ingestion.
The evaluator requires complete evidence for both. Partial acceptance is not
silently retried or discarded, and all existing numeric thresholds remain intact.

TDD red: eight tests, seven expected failures (exit 2). Final focused verification:
13 tests, zero failures; owning warnings-as-errors compile and scoped formatting/
whitespace checks passed. The parent inspected the four-file change and test
scope. Exact fresh command, run once after implementation:

```sh
devenv shell -- env MIX_ENV=test mix memory.qualify --profile ci --report .devenv/memory-local-evidence/memory-qualify-ci-22.json
```

Exit 0, all six gates passed. Measured input: 2000 requested/returned/accepted/
persisted, all replies accepted, twenty durable jobs/frontiers/generations,
1317.44 events/second. Warmup: 1000 requested/returned/accepted/persisted, all
accepted, ten jobs/frontiers. Consolidation: 20/20 with complete provenance;
projection p95 524.646 ms. This remains CI/test/manual-drain evidence, not
performance-authoritative or real-provider/live acceptance.

The original 1800/2000 ingest failure remains retained and unexplained. Eight
bounded instrumented diagnostic samples across two fresh BEAM invocations did
not reproduce it; no production ingestion fix is claimed. Warmup in the fresh
report recorded 505 requested generations. Cold module detection/per-event
fallback is consistent with the source, but is not established as the original
failure's cause. The stronger fresh qualification passed; this uncertainty stays
visible rather than being rewritten as a resolved production defect.


### M15 evaluation fixture correction and replay browser qualification

The initial `memory-eval-ci-22.json` failed only `fts_outage_availability`.
Its outage fixture intentionally enables a failing reranker stub, unlike the
main latency sample. Reranker calls were therefore expected; zero embedding calls
caused the failure. Two bounded Pipeline probes in a test rollback sandbox proved
that the fixture's missing embedding model prevented invocation of its injected
failing embedder. An explicit synthetic model changed embedding calls from 0 to
1 while both samples retained one FTS result and one reranker call.

The only evaluation implementation delta adds `query_embedding_model: "eval-outage"`
to that fixture. Production Recall code and all thresholds remain unchanged.
The regression requires an absent global model, the explicit fixture model, both
failing callbacks on every sample and retained FTS. TDD red: two tests/one expected
failure (exit 2); focused green: two tests/zero failures. Owning compile with
warnings as errors, scoped formatting and whitespace checks passed. Task22
cumulative repair counters: Sol1/Astra0.

```sh
devenv shell -- env MIX_ENV=test mix memory.eval --profile ci --report .devenv/memory-local-evidence/memory-eval-ci-22-repair1.json
```

Exact fresh run exited 0, all five thresholds passed: quality 0.95, provenance
1.0, FTS 100/100, failing embedding/reranker callbacks 100 each. The initial
failure and diagnostic probe are retained. This is an injected-provider CI
benchmark, not real-provider or performance-authoritative acceptance.

The required existing browser qualification also exited 0:

```sh
devenv shell -- env MIX_ENV=test mix memory.replay.browser_qualify --browser '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' --report .devenv/memory-local-evidence/memory-replay-browser-22.json
```

The report passed all six assertions with Chrome 155.0.8059.80: more than 100
rendered events, canonical space identity, controls, cursor, disconnect/reconnect
state and live PubSub update. It seeded 122 synthetic test events and manually
rebuilt/broadcast the final update inside test qualification. It supplements the
actual retained-fixture browser evidence and cannot replace live L03–L09 or
outage/restart/governance qualification. It did not expose event content.

### L17 query error and partition appearance (2026-10-20)

Task23's reusable browser driver passed a real request-scoped PostgreSQL error
and corrective-filter recovery. A bound search containing NUL reached the server;
sanitized gateway correlation confirmed22021/invalid-byte errors. The already-open
page displayed the readable query-failure alert in168ms, hid count/empty-success
and detail states, and retained partition, offset and selected detail route.
Restoring the exact original URL recovered the original filter, rows and detail
in121ms without document replacement, navigation requests or browser errors.
Evidence: `oct20-a/query-failure-1792440199352130000/report.json`, screenshots and
`oct20-a/query23-server-correlation-final.json`. The initial driver incorrectly
required an alert title attribute in DOM inner_text; its repair asserts the
existing readable slot text and records screenshots before assertions. Nine
safety tests pass. No production UI or dependency defect was inferred from that
harness assertion. Unchanged-filter transient backend recovery remains untested.

Task24's corrected supported-workflow run remains red:
`oct20-a/partition-appearance-1792440135394320000/report.json`. Admin created host
`bfe44a83-2e64-4823-bea1-e08812989f63` and empty space
`41adc997-bedf-c1b2-7ad6-5039a8c2ac1e`. Sessions discovered its DOM choice in1039ms
and displayed it after ordinary menu expansion in1106ms; Memories' already-open
picker still had no corresponding DOM link after8seconds. Both original URLs,
documents, filters/page and selected Memory detail survived; the newly discovered
partition opened with zero memories. Zero browser errors. The source confirms
Memories refreshes rows but never rediscovers partition options. This is an
unresolved L17 product defect under existing UI05 counters, not a new repair
budget. No canonical memory, provider or global Settings was changed.

The first partition report is retained but cannot establish absent options:
its default role locator excluded hidden links in collapsed details. Task24
harness repair1 separates DOM discovery, menu expansion and visibility; seven
safety tests pass. Two newly registered synthetic hosts/spaces are retained.

Fresh quality checks passed:16 focused Admin tests,14 configuration tests, full
formatting, warnings-as-errors compilation and strict Credo (1886files). Credo's
one initial readability finding was corrected by extracting credential auth_type
before its condition, preserving behavior (config07 Solrepair1/Astra0). Logs:
`admin-inventory24-baseline.log`, `config07-quality24-tests.log`, and
`memory-{format,compile,credo}24-config07.log`. Dialyzer was stopped during cold
PLT generation to remove overlap with development reload/browser execution;
`memory-dialyzer24.log` is interrupted, not passed.

The full owning-app command
`devenv shell -- env MIX_ENV=test mix do --app backplane_memory cmd mix test`
finished in169seconds:1314tests,43failures, seed813610. The inner test command
exited2; its outer umbrella command exited1. Evidence: `memory-app24-tests.log`.
Initial read-only diagnosis identifies changed scheduling versus the replay test's
exact job-count assumption, missing explicit policy/model setup in several
Crystal fixtures, old consolidation expectations, and an already-running service
registration process conflicting with test startup. These are diagnoses, not
waived gates or proven unchanged-baseline failures. No full-suite pass is claimed.
Source/test repair ownership and existing exhausted budgets remain in force.

The independent ServiceRegistration test-isolation repair passed7 focused tests
and17 combined namespace/notifier/registration tests with the same813610 seed.
It temporarily stops only the exact app-supervised singleton during this test
module, then verifies the original cached service setting and restarted worker.
Production registration is unchanged. Scoped formatting/compilation passed;
`service-registration09-repair1-*.log` retains evidence. The full suite was not
rerun after this repair; its43-failure report remains the last full-suite result.

Fresh retained canonical snapshot `oct20-a/canonical-1792440383401270000.json`
still has41events,61memories,15summaries,3lessons,6crystals and37nodes/40edges.
The query/browser tests made no canonical memory writes. Final readiness
`oct20-a/current-runtime24-final.json` confirms public/Admin/host ready with the
same owned gateway72451 and host52783. No deliberate fault remains active.
Overall acceptance and delivery remain INCOMPLETE.

The subsequent serialized Dialyzer retry completed dependency PLT generation and
analysis but exited2 with warnings (`memory-dialyzer24-retry.log`):142total,
132skipped,40unnecessary skips. Emitted warnings concern opaque Task arguments in
LLM.Router and an unreachable graph-worker result pattern. A bounded isolated
module comparison against HEAD under the same local runtime and dependency PLT
found nine identical audio Task-opacity warnings in both versions, and zero HEAD
versus one current graph warning at graph_extract_worker.ex:451. Evidence:
`dialyzer26-module-comparison-1792440977051434000/comparison.json`. This is not a
full repository baseline or a CI-runtime result. The graph warning belongs to
the current stages04 changes; its exhausted repair budget remains unchanged.
No ignore-list changes or passing type-check claim. The root CI workflow script
passed8tests (`memory-ci-workflow24.log`). Mandatory red gates still block delivery.

### L13 real negative protocol subset

`bun scripts/memory_local_protocol_denial.ts --fixture
.devenv/memory-local-fixtures/oct20-a/fixture.json --offline-proof
.devenv/memory-local-evidence/oct20-a/protocol25-offline-proof.json` passed in
507ms. The proof is single-use operational evidence and must be regenerated from
current process identities, listener checks and live Admin status before reuse;
the driver rejects proofs older than120seconds. Ten focused safety tests passed
with182assertions.

Parent verified isolated PID4687 absent, original process group4686 empty, no
4223listener or open files beneath the dedicated isolated directory, primary
Online and isolated Offline. The driver joined only the isolated host, sent
exactly two negative memory_next requests, and received `unauthorized` for the
primary partition and `unsupported_protocol` for host_memory.v1 on its own
partition. Both replies had retryable=false and no protected result content.
No authorized batch, snapshot request or ACK was sent. Leave reply and socket
closure succeeded; cleanup_failed=false.

Evidence: `protocol-denial-1792441499435-7f970af5-4dde-4c85-ab8d-42b4e0160729/report.json`.
Parent postconditions: `oct20-a/protocol25-postconditions.json` confirms isolated
Offline/4223closed, unchanged primary52783/gateway72451 identities and all three
endpoints ready. All browser contexts closed, no deliberate fault remains.
This is protocol-boundary evidence only: same-space grants, revocation and facade
protected-cache suppression remain unproved; complete_l13 remains false.

The separate facade validation subset also passed through both primary4222
interfaces: own scoped nonempty online list, identical call with the owner's
client_id explicitly supplied, then unchanged online control. Direct denial was
HTTP400 `{ok:false,error:"invalid_arguments"}`; local MCP returned HTTP200 with
JSON-RPC error -32000/invalid_arguments. Neither denial contained a result. All
four successful controls reported mode=online and the same existing canonical
ID b939abb3-1d42-4350-a30c-f36bb9164d81. Evidence:
`oct20-a/facade-validation27.json`; the first observation lacking mode assertions
is retained as `facade-validation27-initial.json`. Gateway attribution follows
the inspected forwarding/reject_authority_claim source path, not a separately
captured channel frame. Online lists do not populate the edge mirror, so this
proves permanent validation rejection through the facade, not protected-cache
suppression, revocation, or same-space access. No outage or process restart was
injected. Overall acceptance remains INCOMPLETE.

UI05's additional round was authorized by the user's latest go-ahead, but the
assigned Sol worker refused it under an immutable worker-level two-round cap.
No UI05 edits were made; this is a handoff/policy blocker, not a technical
impasse or grounds for automatic Astra escalation. The partition discovery
defect, routing04/stages04 failures, and required red quality gates remain open.
No commit, push or release occurred.

### Combined host regression verification

The required host-focused combination passed217tests/0failures, exit0:
`host-memory-integration28.log`. It includes agent_run, router, facade, proxy,
routing consistency, Worker, capture router/runtime/outage/telemetry/uploader and
the full edge test directory. This checks the combined ownership and fault
contracts under the current checkout. It remains test evidence and does not
replace the outstanding real pending-work restart or mirror/revocation gates.

### L11 pending-restart driver: preflight failure

Task29's bounded host-only restart driver and safety tests are implemented.
The recorded focused run passed 26 tests, syntax/help and scoped whitespace
checks. This is synthetic driver coverage, not real restart acceptance.
Cumulative counters are Sol2/Astra0; both repair rounds have finished.

The first real attempt rejected runtime-created stores with mode0644 before
mutation. After checking owner, regular-file identity and nonsymlink paths, the
parent tightened only the primary fixture's three databases to0600. Those more
restrictive modes remain in place. The second attempt exited1 after5519ms with
`unexpected_operation_failure`, empty phases and no cleanup attempt because no
configuration/lifecycle mutation had begun:
`oct20-a/pending-restart-live-l11-001-1792442625180544000/report.json`.

Read-only diagnosis identifies `memory_local_recovery.store_probe` raising its
own `CheckFailed("store_probe_failed")`, which the new driver's error classifier
does not recognize. An independent bounded SQLite read of the primary mirror
returned `SQLITE_BUSY` (code5). A subsequent macOS `F_GETLK` observation found
whole-file write locks on commands, capture-spool and mirror databases, all owned
by the running primary host PID52783. It did not acquire or release those locks.
See `oct20-a/pending-restart29-{preflight-diagnosis,mirror-read-diagnosis,lock-owner-diagnosis}.json`.
This establishes an incompatible live-reader assumption; it does not establish
an upstream dependency defect or pass stopped-store durability.

Source diagnosis agrees with the observed lock: ex_turso3.1.1 opens
Turso0.8.2 through `Builder::new_local` without enabling multiprocess WAL. Its
default Unix open takes a whole-file exclusive lock until the file is dropped.
Python `mode=ro` does not bypass this lock. A future driver correction can use
supported owner-connection diagnostics for live observations and stopped-store
reads for durability; stopped-only reads cannot replace required pending-state
or live convergence observations. No dependency workaround or upstream issue
has been introduced on this evidence.

The original YAML bytes remained unchanged after both attempts. The final
read-only check found both intervals1000, all three endpoints ready and the
original host/gateway process identities unchanged. No fault is active. Further
driver repair requires an explicit additional budget under the session's routing
policy; no extra round or automatic escalation has been inferred.

### L02 online read parity and L13 sharing boundary

Actual MCP discovery and direct/MCP/direct controls passed for `stats` and a
populated fixture `list`; all six responses were online, and each operation's
three response bodies were exactly equal. Evidence:
`oct20-a/read-parity-1792443045683702000.json`. The initial `stats` call supplied
`scope` despite its empty discovered argument schema and correctly returned
HTTP400/invalid_arguments; that observation remains in
`oct20-a/read-parity-1792443028116365000.json`. This proves online read parity,
not complete core-operation, offline or L02 acceptance. No write was made.

Task25's additional read-only source audit found no supported operator workflow
for granting/revoking one cross-host exact tuple. `MemorySpaces` publicly offers
private provisioning, default-scope changes and whole-host revocation. Feed
negotiation/next/ACK can use an explicit durable grant, but canonical channel
calls and `Partition.resolve` still resolve through the joined/private alias
partition. Directly inserting a grant row would not prove supported positive
facade access. The partition ADR explicitly defers cross-host sharing pending
membership, operation, delivery, revocation, audit and rollback semantics.

L13 therefore has an independent design gap, in addition to its passed negative
subsets. A product decision is pending on read/delivery-only versus shared
write/delete authority. No grant rows, aliases, settings or host lifecycle were
modified. Current feed operations reauthorize on the server, while host offline
authority is retained from its last authenticated negotiation; immediate cache
suppression after a denied feed is not established. No exhausted routing repair
has been relabeled or restarted. Full L13 remains unproved.

### Online core workflow: passed observations, failed driver

Added `scripts/memory_local_core_parity.py` and18 focused safety tests; the parent
independently reran all18 successfully. The driver creates only one uniquely
marked fixture record, uses supported direct/MCP calls, reserves cleanup time,
and does not change services, configuration, databases or worker execution.
Task31's cumulative repair counters are Sol2/Astra0.

The actual first run, `core31-online-001`, exited1 in6.09seconds:
`oct20-a/core-parity31-online-001.json`. Discovery passed, exact direct/MCP
remember retries retained local ID01a155f7-2f63-727b-9845-913d487a7351, and normal
sync produced canonical ID52b33b83-be87-4a1e-9eb7-e0c1ad5a02d7. Both interfaces
verified procedural type, agent selection through positive/negative filters,
facets through positive/negative canonical queries, matching inventory identities
and equal stats. Direct/MCP recall each returned that ID once with real vector
status=ok,270 used tokens and matching2048 budget. Their trace IDs are
869e906d-5a20-42fb-9c69-2fd9b8765ecf and f518c295-c35b-431e-90cc-993b2aad0605.

The main workflow failed `forget_receipt_required`. Because the driver records
allowlisted observations rather than full replies, the exact failed initial
receipt predicate remains unknown; do not infer a storage or protocol defect.
Cleanup subsequently observed a repeated canonical forget acknowledged at
revision60, both online lists empty for the marker, and all11 preexisting fixture
IDs preserved. Cleanup passed, but the overall driver remains **failed**.

An independent canonical snapshot confirms the new record has the configured
real embedding model, `lifecycle_state=tombstoned` and a nonnull `deleted_at`:
`oct20-a/canonical-1792443686143763000.json`. Parent postconditions confirm the
original gateway/host identities and three ready endpoints:
`oct20-a/core-parity31-parent-postconditions.json`. No deliberate fault remains.
These observations extend online L02/L04/L12 evidence; they do not establish
offline parity, replay non-resurrection or passing complete L02/L04/L12.

The subsequent source-only diagnosis found that local forget may return the
local row ID after matching a canonical `remote_id`, whereas the driver's first
receipt check requires the canonical ID. This is a source-supported explanation,
not exact attribution of the missing original receipt. The driver remains failed
and no extra repair round or fresh reproduction has been inferred.

The independent [shared access design](shared-host-access-design.md) is a proposed
architecture for the remaining L13 gap. It separates actor permission from source
provenance, defines exact grant selection and revocation fencing, and compares
read/delivery-only with write/delete access. Product choice and implementation
remain pending; its proposed offline lease is not current accepted policy.

### Real query expansion through both host interfaces

The previously test-only query-expansion path now has actual local-dev provider
evidence. Direct `expand_query` and MCP `memory::expand_query` each processed:
"Why does the synthetic project prefer bounded OTP workers and PostgreSQL
canonical storage?" Both returned five distinct bounded strings, including the
original query, without the no-model fallback note. The coordinator reviewed all
eight alternative phrasings: they preserve the project, bounded OTP workers,
PostgreSQL canonical storage and the reason-seeking intent without adding an
explanation or invented source fact.

Evidence: `oct20-a/query-expansion-live-1792443866891913000.json` and
`oct20-a/query-expansion-live-parent-review.json`. Two successful proxy records
in the bounded observation window show the selected model resolving to
`openai/gpt-4.1-mini`, HTTP200, duration2331/1985ms, input74tokens each and
output88/91tokens. Correlation is temporal: the host replies do not expose proxy
request IDs. The separate read-only canonical count remained41events; this is
consistent with capture suppression but is not an injected recursion fault test.

This proves meaningful real model expansion for this query through both host
interfaces, not general expansion relevance or full L01–L18. No source/config,
provider, lifecycle or canonical content changes were made, no exhausted repair
budget was extended, and the previous mandatory failures remain open.

### Retained capture correlation and completion audit

A read-only audit of retained artifacts correlates all64 Codex adapter calls in
`oct20-a/api-capture-1792432354096062000.json`:32 accepted and32 duplicate
responses, with every duplicate preserving its original event ID. All32 unique
local IDs appear in `oct20-a/canonical-1792432432910176000.json`. The four
synthetic sessions each have unique source sequences1–8, gap_count0 and completed
session state. Corresponding completed projection states are present, including
the separate actual Claude session; its runtime report
`oct20-a/runtime-1792432303687863000/report.json` records
`canonical_capture_verified=true`.

This is newly correlated retained evidence, not a fresh workload run. It does
not expose the uploader's canonical ACK receipt or independently establish
atomic repair commitment/crash recovery. Later source revisions still require
L14 correlation. Full L03 remains incomplete.

The completion audit found no independent remaining implementation or live
action capable of resolving a mandatory gate without the pending repair budgets
or shared-authority product choice. Required routing recovery, stage factual
quality, full tests/Dialyzer, UI partition discovery, pending-work restart,
governance, stale generation, sharing and repeatability remain red or unproved.
Previously passing subsets cannot substitute for them. No delivery is authorized
by a partial result; no commit, push, version change or release has occurred.

### Retained final verification checkpoints (2026-10-21; superseded by current summary)

Task64A9 completed the exact178-file Memory regression:1396 tests,0 failures,
5 unchanged exclusions. Only the two frozen contract tests changed: approved API
arities, five exact optional-selector schemas/hashes, and selector authority
boundary coverage. Evidence: `task64-a9-artifacts/report.json`.

Task117 recovered Task107's exact failed Graph revision through one supported
Admin session-consolidation click and normal Styx job3429. The retained failed
automatic run remains failed; the recovery is explicitly operator-assisted.
Open Graph updated in1467.778ms and paginated Pipeline page0 in756.842ms,
without navigation, lost filters/offset50, page errors, changed source events,
or changed non-Graph artifacts/evidence. Evidence:
`oct20-a/fresh-open-pages117-retry-qualityretry117-20261021-001/report.json`.

Final read-only reconciliation118 did not pass. All original207/214 memory IDs
and712/719 evidence rows remain present; evidence fingerprints,274-memory
identity/provenance inventory,33 capture identities, shared authority/revocation,
fresh governance tombstone,17 fixture settings and primary-file checks passed.
Eleven historical memory row fingerprints differ. Provider-dimensions and current
processing assertions also failed. Task121 is diagnosing these exact discrepancies
without changing data or weakening comparisons. Evidence:
`resumed-101/final-preservation118-result001.json`. L18 remains incomplete.
Remaining app regression/quality/assets validation belongs to Task120; its actual
terminal results must be recorded before commit or completion claims.

Task64A10 subsequently passed the exact51-file Host matrix553/0 after focused
12/3 red →12/0 green. The approvedV4 migration is now explicitly checked for
nullable authority columns, old canonical/snapshot preservation, and unchanged
rows/bindings after restart and repeated migration. HistoricalV3 corruption
checks remain unchanged. Evidence: `task64-a10-artifacts/report.json`.
The original failed553/3 run remains in Task120's first report; remaining six
groups and quality/assets are running in a separate continuation report.

### Historical reconciliation supplement121

`resumed-101/task121-report.json` and fixed-value `task121-proof.sql` account
for all11 changed historical memories against BOTH207/712 and214/719 baselines.
Using retained historical metadata and exact previous timestamps reproduces
both original full-row fingerprints; the original four fingerprint exclusions
remain unchanged. The only changed fields are additive
`metadata.repository_sources` and `updated_at`, correlated with normal
`remember/reinforced` audit records. All other included fields exactly match;
content, lifecycle, authority/provenance inventory and existing evidence are
preserved. Nine historical timestamps come from delivery snapshots; two candidate
timestamps were recovered within retained embedding-completion bounds and then
verified by exact fixed-value hashes. No data was reverted or rewritten.
Original118 strict-current-hash comparison remains failed, as expected after
these recorded provenance enrichments; it is not relabelled byte-identical.

Provider failure118 was a checker domain error: it queried legacy LLM tables.
The actual Embedding registry passes enabled/origin/dimensions checks, consistent
with the exact restored provider UI form. Selected session stages are healthy
except the documented first-session insufficient-input Graph state. Queue health
is a separate outstanding gate:24 discarded relation-classifier jobs include23
with fresh selected-session evidence, and three old executing jobs require
scheduler-owner assessment. Missing args.session_id did not make these unrelated.
Classifier failures leave committed facts/evidence intact but reduce automatic
memory relations. Current operator dead-letter selection misses nested classifier
partitions; actual repair/retry has not yet run. This blocks queue/L18 closure.

### Final focused verification120/A11

After fixture-only compatibility correction A11, exact owning groups passed:
Admin133/0,API143/0,Llama3/0. System56/0,Skills26/0,Contract15/0,
Bun10/0,Elixir policy12/0,release contracts22/0,CI workflow8/0,
Python283/0,Memory1396/0 andHost553/0 have separate actual passing reports.
Formatting, version syntax, diff and rootdev warnings-as-errors compilation
passed. Production assets deployment passed and16 generated static files changed;
these outputs were inventoried and left unstaged. Baseline strictCredo remains
red only for unchanged mandatory `TODO(upstream): duskmoon-dev/duskmoon-bundler#3`
at config/config.exs:99; the comment was not removed or suppressed.
`task64-a11-artifacts/activity-preservation.json` verifies the test's sandbox-local
fixture isolation rolled back and preserved all original committed activity rows.
See `resumed-101/task120-collection-1792542679185688000/final-summary.json` and
`task64-a11-artifacts/report.json`. Earlier failing reports remain immutable.
These results precede the final stages04A16 source correction; affected checks
must pass again after that correction. They do not close L18 or release gates.

Read-only scheduler diagnosis122 corrected an initial misreading before any
mutation: public Styx cancellation preserves history; physical deletion is a
separate API. The three old executing jobs are fixture-owned. Two targets are
tombstoned and must remain terminal, without regenerated embeddings/relations.
Task123 prepares a bounded supported operator controller only; no old-job recovery
has yet run. Source recovery A16 is the last reserved original stage round,
separate from the exhausted general compatibility pool.

## Final local acceptance and delivery (2026-10-21)

Local L01–L18 are accepted at the composite evidence levels above. The final
relation-classifier regression is39/0; exact178-file Memory1413/0 (5 unchanged
exclusions), exact14-file Admin134/0, scoped quality and dev strict compilation
passed. Earlier API143/0, Host553/0, System56/0, Skills26/0, Contract15/0,
Llama3/0, Bun10/0, policy12/0, release22/0, workflow8/0 and Python283/0
precede A20 and are retained evidence, not fresh reruns after it.

Memory implementation/documentation is committed as `86ad63e5`; selective release
support is `db610c33`. Both were pushed to `origin/main`. The root is the only
worktree, so no remaining worktree merge was required. The explicit242-path task
manifest excludes `backplane-memory-provenance-codex-task.md`, private `.devenv`
evidence, generated assets and credentials. Those unrelated bytes are preserved.

Release is incomplete. Required gates on the preceding9fde SHA were red:
MCP idempotency Dialyzer, AdminAudit `regenerate_token`, Relayixir
`cleanup_unconfirmed`, and MCP protocol SSE `no process` (cause unproved).
Broad strict Credo also retains the required upstream TODO at `config/config.exs:99`.
These failures were not repaired or waived within this Memory task. New pushed-SHA
CI must be inspected before release; permission to continue Memory does not waive
required gates. No version bump, release dispatch, package publication or deployment
has occurred. The selective release must include `backplane_memory_contract` among
the eight affected apps and retain actual qualification, six platform builds,
installed smoke, checksums and Docker publication. See the runbook release section.

Open `http://localhost:4221/memory` without a host selection. The optional host
filters show the primary and isolated source data; repository remains provenance.
Public API is on4220 and the local host direct/MCP facades are4222/4223. The local
stack remains healthy and running; tested lifecycle commands and nonsecret example
configuration are in the runbook. No cross-machine verification was performed.


### Final shared-delivery type contract correction

Exact pushed-SHA9b1346c CI passed full Memory1413/0 (5 excluded), API330/0,
Compile, Format, Credo and Workflow Contract. MCP protocol passed this time.
Admin453/1 and Relayixir296/1 repeated the excluded baseline failures. Dialyzer
also revealed five in-scope Channel warnings: the shared host-auth map conflicted
with EdgeSync's old UUID-only specification, which additionally made two v2
branches appear unreachable.

Task64A12 adds a narrow UUID-or-host-auth subject type to `negotiate/2`, `next/2`
and `ack/2`; no function implementation or authorization behavior changes.
Focused EdgeSync/shared-delivery21/0, strict dev compile, scoped formatting and
Credo pass. Root dev Dialyzer confirms all five Channel warnings gone, but exits2:
one retained MCP idempotency warning plus nine opaque Task warnings in untouched
Llama router code. Those local warnings are not claimed green or suppressed;
the final pushed-SHA CI must provide the independent warning comparison.
Evidence: `.devenv/provenance-correction/task64-a12-types/` and
`resumed-101/ci130-diagnosis.json`. Task64 cumulativeSol2/Astra12; stages04 remains
Sol2/Astra20. Latest five-round pool5used/0remaining; prior evidence/counters remain
immutable. Required red release gates are not waived.


### Exact-SHA CI after shared-delivery type correction

On main `0da14a604fbab46e4ed3a0d3fc4572e247728452`, CI39532288326
passed Compile, Format Check, Credo and Workflow Contract. Dialyzer retained one
active MCP idempotency warning (`lib/backplane/transport/idempotency.ex:1`);
all five HostAgentChannel warnings are gone. The nine local Llama Task warnings
were not reproduced in CI. Test39532288310 passed16 jobs and failed the two
excluded owning jobs: Admin453/1 (`admin_audit_test.exs:77`, expected
`regenerate_token`, actual `rotate_token`) and Relayixir296/1
(`https_proxy_test.exs:226`, expected `:ok`, actual
`{:error, :cleanup_unconfirmed}`). API330/0 and MCP protocol passed.
Memory reported1394/0 with5 exclusions, subject to the duplicate-module caveat
above. No required red gate is waived; no release was dispatched.

Task133 established the test-count root cause: `memory_test.exs` declares20
tests and `memories_test.exs` declares1, both under the same ExUnit module atom.
The CI redefinition warning changes location with compile order, explaining the
19-test delta. Neither historical count establishes unique coverage. The
current Task72 correction gives the provenance test its own module without
changing assertions. Its focused pre-edit run reproduced a simultaneous-module
CompileError. Subsequent results belong below, separate from historical runs.

Task134 independently inspected provider, generated knowledge, browser and
qualification artifacts and found no additional product gap. Local L01–L18
remain accepted at the stated composite levels; publication remains incomplete.
Read-only lifecycle status checks in `resumed-101/continuation135-{primary,isolated}-status.json`
confirmed all four HTTP endpoints ready without restarting services.


### Corrected test registration verification (Task72 Astra4)

The provenance suite now uses `Backplane.Memory.MemoriesProvenanceTest`;
its entire body and assertions are unchanged. The two formerly colliding files
run together with `--seed 0 --trace`:21 tests,0 failures, both modules traced.
The exact178-file full Memory suite then exited0:1394 tests,0 failures,
5 unchanged exclusions. This is an observed count, not a predicted1414.
No test-module redefinition appeared; migration reload tests still emit their
existing migration-module warnings. One-file formatting and diff checks are
recorded with the worker handoff under
`.devenv/provenance-correction/task72-astra4-registration/`.
A parent static scan found211 distinct top-level test modules and no duplicates.
Task72 cumulative counters are Sol2/Astra4; the new pool has1 used/4 remaining.
This test-only correction changes no runtime authority, provenance or data.


### Repository-local release dependencies included by the owner

The owner explicitly expanded this task beyond Memory to resolve the three
repository-local red gates. Earlier exclusions are historical, not current
permission boundaries. Required gates remain unwaived.

Task136 fixes the MCP warning by reusing `plain_map/1` for sensitive rejection
IDs instead of branching on Plug.Conn's already-map-typed body parameters.
Sensitive-tool tests retain no-store/no-side-effect/cache assertions and now
verify the response ID. AdminAudit exercises current persisted `rotate_token`,
checks the exact `client.token_rotated` audit, confirms old-token revocation and
new-token validity, reopens the closed editor and rejects secrets/digests in audit.
The removed `regenerate_token` UI event is not restored. Final focused results:
MCP30/0 and Admin9/0; formatting/diff pass. Dev Dialyzer removes the target MCP
warning but exits2 for9 retained Llama Task opacity warnings. Test-env Dialyzer
could not run without a test PLT. Actual final-SHA CI remains required.
Evidence: `resumed-101/task136-mcp-admin-report.json`.

Task137 reconciles the HTTPS-proxy test with installed Fetch0.21.14's documented
TLS-setup cleanup boundary. A failed handshake exposing no socket stays
`cleanup_unconfirmed`; the test proves prompt rejection, no direct origin
connection, retained aborted guard/controller and both normal exits after the
original6000ms deadline. A shared250ms test-only DOWN observation allowance
covers the timer callback/termination scheduling; the production timer is
unchanged. Established TLS cleanup assertions remain strict. No dependency
workaround or upstream issue was needed. Red reproduction matched CI; focused
13/0, full Relayixir296/0, separate strict app compile, formatting and diff passed.
Evidence: `resumed-101/task137-{red,focused-repair1,full,format}.log`.

Task136MCP/136Admin initial implementations passed (Sol0/Astra0). Task137 used
Sol repair1/Astra0 for the exact-timer observation race; the current five-round
pool is2used/3remaining, with all historical Memory counters preserved.
Only MCP runtime code changed, so `backplane_mcp` joins the existing eight-app
selective release list. Relayixir test/docs changes require no version churn.
These local checks do not claim that final CI, versioning or publication passed.


### Historical source CI and scoped version preparation

Main `587af33f55d7f56af924273cf4c4702af8393c8d` passed CI39551221215:
Compile, Format Check, Credo, Workflow Contract and Dialyzer. Test39551221155
passed all18 owning-app jobs, including Admin, MCP and Relayixir. No required
red gate was waived. The local9 Llama Task warnings remain a separate local
toolchain observation; they are not present in this successful CI qualification.

The unused version1.10.28 is prepared with `scripts/set-version.sh`, updating
only root and the nine selected runtime app manifests listed in the runbook.
Relayixir runtime and unrelated package versions remain unchanged. Publication
still requires green CI on the version commit, Memory qualification, six build
artifacts, installed-release smoke, checksums and Docker publication. This section
records preparation, not release success. The integrated machine-readable report
is `resumed-101/release138-delivery.json`; later external results belong there.
