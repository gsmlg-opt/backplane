# Diagnostics acceptance record

This record covers the [design](backplane-diagnostics-design.md), the [implementation plan](../superpowers/plans/2026-11-28-backplane-diagnostics.md), and the [operating procedure](operations.md).

## Candidate and test environment

| Component | Checked-out base plus diagnostics changes |
| --- | --- |
| Backplane and Host Agent | `9334ba6a8c02c5483b001a85d076b967495ffcea`, Backplane/Host Agent 1.10.106 |
| Standalone SDK | `backplane_diagnostics_client` 0.1.0, locally built Hex tarball |
| Sigma | `3b0bb0ad07527458c88954d467cc9f25bfb5b6ea` |
| Synapsis | `a90555cf2564da400c11a993cfdc3c399f4b2bcc` |
| Samgita | `df4d76958b3eac7db600af3dcedce9898ec712e7` |

The integration fixtures used local synthetic data on Darwin arm64 with Elixir 1.20.4, OTP 28, PostgreSQL 17.12 with pgvector, and `ex_turso` 3.1.18. The focused integration suite and the browser/model trials used disposable database instances. The source versions above identify the starting commits, with the diagnostics implementation still in each working tree.

The SDK has its own process-local context and closed event schema. Existing Observability Context informed correlation, while Event and Redaction needed stricter wire rules. Buffer and RuntimeSink admission, TraceStore's asynchronous writes, and LLM LogWriter enqueue are observations rather than durable confirmations. Memory CaptureUploader supplied retry and partial-receipt patterns. Diagnostics uses its own storage, receipt identities, and acknowledgement levels. Independently generated fixture bytes and SHA-256 are in [protocol/v1](protocol/v1/README.md).

A separate BEAM opened Turso with WAL and `synchronous=FULL`. Its owner reported a 4,096-byte database and 82,432-byte WAL after committing a 65,536-byte row. Killing that BEAM during a second uncommitted insert and reopening the database recovered exactly the committed row. This tests process interruption under the stated storage settings. Power loss has a separate hardware and filesystem durability boundary.

## Reproduction commands

Use the project development database configuration and run from the Backplane root. Test paths in the matrix are relative to their owning app's `test` directory. Product checks run from the named product root with the local candidate SDK path and again with SDK integration disabled.

```sh
mix test apps/backplane_diagnostics_client/test apps/backplane_diagnostics/test
mix test apps/backplane_host_agent/test/backplane/host_agent/diagnostics \
  apps/backplane_host_agent/test/backplane/host_agent/memory_router_test.exs
BACKPLANE_DIAGNOSTICS_SIGMA_ADAPTER=/absolute/path/to/sigma/apps/sigma_agent/lib/sigma_agent/backplane/diagnostics.ex \
BACKPLANE_DIAGNOSTICS_PREVIOUS_REF=9334ba6a8c02c5483b001a85d076b967495ffcea \
  mix test apps/backplane_api/test/backplane/api/diagnostics_delivery_test.exs \
  apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs \
  apps/backplane_api/test/backplane/api/endpoints_mcp_test.exs
mix test apps/backplane_admin/test/backplane/admin/live/diagnostics_test.exs \
  apps/backplane_mcp/test/backplane/services/diagnostics_test.exs
mix test apps/backplane_agent_runtime/test/backplane/agent_runtime/codex_settled_error_test.exs \
  apps/backplane_llama/test/backplane/llm/access_event_test.exs \
  apps/backplane_llama/test/backplane/llm/router_test.exs
bash scripts/verify_diagnostics_client_package.sh
```

## Failure and recovery matrix

| Case | Evidence |
| --- | --- |
| A01 | SDK `integrations_test.exs` exercised an actual crashing OTP Task. The API suite also drove the locked Phoenix Router exception callback and checked the original exception and request ID. The Task fixture recorded its stack and run context. Application release and Git SHA are explicit deployment metadata. |
| A02 | SDK integration and Agent Runtime settled-error fixtures exercised capture before public error conversion. The original result and exception stack remained observable to the caller. |
| A03 | Central `projector_test.exs` grouped three correlated observations into one occurrence. The Phoenix and Logger inputs used controlled fixture metadata. |
| A04 | Central projector counted two distinct attempts as two occurrences under one issue. |
| A05 | The Sigma adapter sent failed and successful retry facts, explicit lineage, and a successful final run through real loopback HTTP and WebSocket. Central projector also retains the failed attempt after recovery. |
| A06 | Central `detectors_test.exs` kept legitimate waits separate from stale or missing progress. Projector and adapter fixtures preserved cancellation and successful terminal state. |
| A07 | A disposable launchd BEAM was killed with SIGKILL. The macOS runner emitted process and service exit observations with matching process and occurrence IDs and launchd exit status 9. Kickstarting the same job produced a new process instance. All three observations sealed as v1 with `quality.stack = unavailable`. |
| A08 | Real two-hop delivery test dropped a Host HTTP reply after commit. The retry emptied the Reporter queue and left exactly one Host spool record. |
| A09 | The same test dropped a real Host Channel reply after PostgreSQL commit, restarted the spool, and retried. Event, projection, and occurrence identities are checked by the integration and projector fixtures. |
| A10 | Central `events_test.exs` distinguished a changed event and a reused epoch/sequence from valid duplicates. |
| A11 | Uploader fixture applied a mixed reply, confirmed the valid item, and retained rejection details in dead-letter. Requeue preserved the event ID and digest. |
| A12 | Protocol, Reporter, and uploader tests covered missing, unknown, duplicate, wrong-digest, and contradictory receipts. |
| A13 | Events and spool tests accepted the same sequence in a fresh epoch and refused collisions in the existing epoch. |
| A14 | Projector sources preserved gaps, conflicts, and older revisions without rewinding the current run. |
| A15 | Projector rolled back a failed claim and issue update together and retried with exact counts. |
| A16 | Projector replay returned the existing claim result and preserved event, occurrence, and run counts. The trusted history import was separately checked against a sealed epoch with no outbox work. |
| A17 | Unavailable Reporter/Host and upstream transport fixtures preserved caller results or queued data. The fresh Samgita checks included an unreachable Host with persisted native outcomes. |
| A18 | Spool tests forced a write rejection using Turso owner connection read-only mode, exercised quota refusal and expiry, and accepted the same event once writes were restored. |
| A19 | Concurrent normal and priority admissions, bounded Reporter failure storm, and Host traffic limits are recorded in the [performance report](performance.md). |
| A20 | Host ingress rejected unauthenticated and forged sources. The Host Channel rejected the next batch after assignment revocation and denied a token without diagnostics scope. |
| A21 | Synthetic credential markers were excluded at canonical bytes, Host and PostgreSQL boundaries, and evidence/report reads. Retention tests cover structured redaction and absent raw attachments. MCP uses these same bounded query results. |
| A22 | Detector and projector fixtures produced a versioned contract finding from expected/actual summaries and a confirmed terminal fact. |
| A23 | Missing heartbeats and inadequate source observations produced disconnected or insufficient-evidence states. |
| A24 | Analysis tests advanced 300 repeat revisions while coalescing them into one queued job and one notification candidate. |
| A25 | Tests exercised model unavailable, exhausted budget, and execution timeout while the deterministic report remained available. |
| A26 | The model-facing evidence tests included untrusted instruction text as data. Proxy analysis advertises no tools, and the validator rejects tool calls and fabricated references. |
| A27 | The resolution state machine recorded a passing regression without a deployment signal. |
| A28 | The resolution fixture required a matching release, source, workload, and run identities. Only adequate healthy coverage qualified for resolved state. |
| A29 | A new matching-release recurrence reopened the issue and queued analysis. |
| A30 | The same occurrence from a late prior build updated history while leaving the fixed-build state unchanged. |
| A31 | Over two real WebSocket listeners, the same Host transport exercised trace and Memory messages against both the current channel and the exact previous channel source. The previous channel returned `unsupported_protocol` for the new capability and the new Host retained its pending event. The same spool subsequently confirmed that event against the current channel. Legacy delivery still worked before and after both steps. |
| A32 | An isolated Ubuntu arm64 systemd unit became active, restarted with a different boot/PID/start identity, and stopped. A macOS launchd job traversed the collector runner through start, restart, and exit. |
| A33 | Retention pruned bodies on its own timer. A tighter TTL blocked reads immediately and cleared frozen copies on prune. The report retained explicit expiry state and retransmission remained deduplicated. |
| A34 | SDK Tasks preserved separate concurrent run contexts. Projector fixtures kept explicit child, attempt, and service relationships. Synapsis and Samgita checks retained native correlation and parent/child or persisted attempt identity. |
| A35 | The detector ignored diagnostics-origin events and independent Host and analysis health remained available. The proxy identifies its own locally authenticated marker before header stripping; untrusted copies fail the boundary check. |
| A36 | Controlled model fixtures produced both a validated Analysis/RepairTask and `analysis_invalid` with no repair. The supervised Qwen2.5-7B-Instruct MLX trial projected, reported, and analyzed a synthetic exception through the real Backplane LLM proxy. It cited `event:1`, returned low confidence, recorded 397 input and 259 output tokens, and created a repair task. An earlier Qwen2.5-3B-Instruct trial fabricated a source reference. The validator rejected it, preserved its 373 input and 345 output tokens, and kept the deterministic report available. |
| A37 | An ACK-loss/restart fixture retained the original Host ingress disposition and frozen forward bytes across a policy change. |
| A38 | Uploader reconciliation processed all entries before acknowledgement and kept the conflicted member even though its first receipt said stored. |
| A39 | Spool fixtures checked competing sources and priority limits. The controlled load test measured refusal, body budget, and backlog drain. |
| A40 | A restarted spool with reclaimed bodies still recognized original identity and refused unseen events from a sealed epoch. |
| A41 | Disposable PostgreSQL tests used distinct connections to exercise simultaneous projector work and exact issue counts. An injected transaction failure rolled back and was retried. |

## Product and platform checks

- **Backplane and Host Agent.** The protocol fixture, autonomous OTP capture, and real two-hop loopback use the same candidate SDK. Chrome connected to the Admin LiveView and loaded hashed CSS and JavaScript over HTTP 200. Keyboard focus opened the issue and navigated to the run. The state form displayed its confirmation and updated the visible status. At 390 px the workspace had no horizontal document overflow in Moonlight or Sunshine. The checked views had no console errors.
- **Sigma.** Four adapter tests passed with the SDK and three passed in the default build. They exercised a handled provider failure before DTO conversion, a typed 429, a tool identity, and a committed child run. The single-source loopback pilot delivered three committed provider/turn facts, with unknown usage preserved. The broader ChildIO suite had one existing fixture failure on `context_window_unavailable`, reproduced with the checked-in Provider and ChildIO modules from the base commit.
- **Synapsis.** The SDK-enabled adapter, Runs, and lifecycle fault suite passed 21 tests. The same build passed four adapter tests after disabling the SDK and confirmed that no diagnostics child started. Two existing ProviderAdapter tests fail before reaching the adapter because they call removed `Synapsis.Tool.Skill` and `Synapsis.Tool.Registry` APIs at the checked-out commit.
- **Samgita.** Five SDK-enabled and three default-build tests covered durable native append, linked terminal Attempt results, duplicate delivery, replay, rollback, and an unreachable Host. The encrypted native payload stayed in its existing store. Healthy coverage uses the `managed_attempt` workload and explicit resolved outcomes.
- **Collectors.** macOS used the full collector runner with an actual launchd job. The Linux probe was run against actual systemd in a disposable Ubuntu 24.04 ARM64 VM using the checked-in collector module source, Elixir 1.18.4, and OTP 25. This checks platform evidence. A full Linux OTP 28 Host release was outside that probe.
- **Packaging.** The SDK tarball was extracted into a fresh stand-alone Mix consumer. Its production compilation and Reporter smoke test passed, with no Backplane, Repo, Ecto SQL, Admin, or Host Agent app started. A local Host Agent release reported the SDK and no Backplane Repo module. No package was published, and the trials made no production changes.

## Live local model trial

Run `python -m mlx_lm server --host 127.0.0.1 --port <port> --model mlx-community/Qwen2.5-7B-Instruct-4bit`. The trial used MLX 0.32.5, MLX LM 0.32.2, and a loopback OpenAI Chat Completions provider registered in a disposable Backplane database. Apply the normal Backplane configuration and start the diagnostics workers. Register a fixture source, emit one synthetic `FixtureError`, and inspect `Analyses.latest(issue_id)`, `Reports.get(issue_id)`, and `RepairTasks.get(issue_id)` after projection and report scheduling. The trial retained only the validator's status, structured result, and reported usage. Monetary cost was unavailable, and private reasoning was discarded.

## Repository checks

The integrated Backplane suite passed 252 focused tests with the Sigma adapter and archived-channel trial enabled. Repository-wide formatting, warnings-as-errors compilation, strict Credo, and all nine CI workflow checks passed. Dialyzer ran and reported one unsuppressed `guard_fail` in the unchanged [Web X Search code](../../apps/backplane_mcp/lib/backplane/services/web_x_search.ex#L231). The test compiler also emitted an existing type warning in the MCP observability test helper.
