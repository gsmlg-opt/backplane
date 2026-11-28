# Backplane Diagnostics operations

Diagnostics separates an application observation, its Host Agent acknowledgement, Backplane's durable event, and the derived issue. Read [the wire protocol](protocol/v1/README.md) for receipt behavior and [the acceptance record](acceptance.md) for tested boundaries.

## Register one source

1. Apply the Backplane migrations in the target environment using the existing release migration workflow. Enable **Host diagnostics upload** in **System → Diagnostics → Analysis Settings**. The channel checks the current Host token assignment on each diagnostics batch.
2. Register the source through `Backplane.Diagnostics.Sources.register(host_id, attrs)` from a trusted Backplane release console. `host_id` is the existing Host Agent UUID. Use a stable source ID and bind the application, repository and optional service instance to the actual source.
3. Configure the same source on the Host Agent. Use a separate random enrollment token for each application, supplied through the process environment. Keep account credentials and production tokens out of fixtures.

```yaml
diagnostics:
  enabled: true
  delivery_enabled: true
  sources:
    - id: sigma-pilot
      application: sigma
      repository: gsmlg-opt/sigma
      token_env: BACKPLANE_SIGMA_DIAGNOSTICS_TOKEN
```

The Host HTTP listener defaults to loopback. A container or remote process requires an explicitly reachable protected listener. For the Sigma, Synapsis, and Samgita candidate builds, set `BACKPLANE_DIAGNOSTICS_CLIENT_PATH` to the SDK checkout or unpacked candidate package before resolving build dependencies. At runtime set `BACKPLANE_DIAGNOSTICS_HOST_URL`, `BACKPLANE_DIAGNOSTICS_SOURCE_ID`, and `BACKPLANE_DIAGNOSTICS_TOKEN`. The application-side value must match the source token on the Host. Set `BACKPLANE_DIAGNOSTICS_GIT_SHA` and `BACKPLANE_DIAGNOSTICS_RELEASE` from the deployed artifact, and `BACKPLANE_DIAGNOSTICS_SERVICE_INSTANCE` if the registration binds an instance. The [SDK README](../../apps/backplane_diagnostics_client/README.md) shows a standalone Reporter setup.

For periodic or failure-triggered Host evidence, register an explicit target under `diagnostics.targets`. Use a PID or a `service` with `manager` and `name`. For example, the Linux provider can target `systemd` and an exact unit name. On macOS select a `launchd` label. Optional `log_path`, `rotated_log_path`, `crash_path` and `disk_path` must refer to the intended local evidence source. Configure a Docker Unix socket explicitly when using the `docker` adapter. Collector availability varies by platform and privileges. Use a separate registration for Host-origin observations if the Host needs its own source identity.

## Monitor and recover delivery

- `Reporter.health/0` exposes bounded in-memory admission and local confirmation. Inspect source-scoped `GET /diagnostics/v1/status` using the source credential and `x-backplane-diagnostics-source` header. The Admin **Collection Health** page shows the last Host runtime status and pending central projection count.
- During gateway outage, the Host retains its unconfirmed entries and retries the same forward bytes. A 401/403 or unsupported capability pauses or defers sends while preserving those records. Rotate or restore the assigned credential and confirm a new capability probe before checking the queue.
- Inspect retained loss metadata with `Backplane.HostAgent.Diagnostics.Operations.dead_letters(source_id)` in a trusted Host release console. After fixing the underlying condition, use `.requeue(source_id, event_id)` to reoffer an eligible retained dead-letter body unchanged. Submit independent corrected evidence with a new event ID. Expired or purged bodies retain their disposition metadata.
- Host spool reads go through the owning process. Leave the living database and WAL together. After confirming an epoch has stopped producing, the full retry window has closed and no additional entries can arrive, call `Backplane.HostAgent.Diagnostics.Operations.seal_epoch(source_id, epoch)`. A pending spool or projection defers closure. Retry the same operation after connectivity and projection recover. Valid retained receipts still handle duplicate retries after sealing. A trusted Backplane release console can call `Backplane.Diagnostics.Events.import_history(host_id, entry, actor)` for one validated entry from a sealed epoch. The import is audited and remains outside current run and issue projections.

The default spool is `diagnostics/events.db` in the Host work directory. Logical quota and priority reservations are checked atomically, and the owner budgets the database and WAL separately. When the oldest pending record reaches its configured maximum age, its disposition becomes explicit and eligible bodies are pruned under the retired-body cap. A successful `local_durable` receipt confirms the Host's transaction under its configured storage policy. A successful `remote_durable` receipt confirms the central event and projection job transaction.

## Analysis, reports, and fix verification

Deterministic reports are generated even without a model. To enable model analysis, configure a Backplane model alias and positive budgets under **Analysis Settings**. Set `BACKPLANE_DIAGNOSTICS_PROXY_URL` to the loopback gateway base URL and `BACKPLANE_DIAGNOSTICS_ORIGIN_TOKEN` to a dedicated random marker token of at least 24 bytes. If the proxy requires authentication, set `BACKPLANE_DIAGNOSTICS_PROXY_TOKEN_ENV` to the environment variable holding the dedicated client token. The origin marker is removed before provider dispatch. Use the diagnostics Settings limits for calls, input/output tokens, cooldown, cost reservation and retention. Exact-version code lookup requires a trusted repository-to-local-checkout configuration under `:backplane_diagnostics, :source_repositories`.

The read-only MCP tools require the exact `diagnostics::read` scope on the authenticated main MCP resource. The existing trusted Admin listener owns management operations. Use evidence references from the report to inspect bounded redacted data. Expired evidence cannot be replayed as current evidence.

On a diagnostic issue, record the fix's Git SHA or configuration identity, matching releases and sources, workload, and minimum coverage. Record reproducibility and successful regression evidence separately from implementation. A projected terminal observation on the matching build establishes deployment. Qualifying run coverage may advance an issue to `resolved`. A confirmed recurrence on that build reopens it. Late old-build evidence updates history.

## Rollout and rollback

Roll out the central migration and server first, then the Host and a single application source. Confirm both acknowledgement levels and queue recovery before enabling more sources. Legacy trace and Memory traffic use their own capabilities throughout. To pause new diagnostics production, disable Host intake or remove the application's diagnostics environment at restart. Set `delivery_enabled: false` to retain and pause the Host queue. Clear the configured analysis model to pause provider dispatch. Preserve the diagnostics tables and spool while reversing an application or Host rollout.
