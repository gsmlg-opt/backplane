# Backplane Host Agent Skill Sync Design

## Source And Scope

This spec refines `docs/host-agent-design.md` for implementation. Host Agent v1 is a machine-side daemon that reconciles Backplane Skills Hub assignments into local skill runtime directories.

The implementation depends on the archive-backed Skills Hub foundation from `docs/skill-hub-design.md` and `docs/superpowers/plans/2026-05-20-skills-hub.md`. Do not build a temporary bridge from the legacy single-string `skills.content` model. Host Agent v1 needs real archive downloads, checksums, and assignment metadata.

V1 remains skill sync only. It must not implement local MCP serving, arbitrary tool execution, remote shell execution, system configuration management, secret sync, agent task execution, LLM calls, or distributed orchestration.

## Goals

- Run an independently releasable umbrella app at `apps/backplane_host_agent` with OTP app `:backplane_host_agent` and root namespace `Backplane.HostAgent`.
- Connect Host Agent to Backplane through a Phoenix Channel over WebSocket.
- Fetch desired skill assignments from Backplane.
- Download assigned skill archives through authenticated HTTPS URLs.
- Verify archive checksums before install.
- Install valid skill bundles into configured local target directories.
- Maintain a local manifest that records Host Agent ownership.
- Report sync status back to Backplane over the channel.
- Keep Backplane as the source of truth for skills, host assignments, and observed sync state.

## Architecture

Implementation should proceed foundation first:

1. Finish archive-backed Skills Hub storage and download behavior.
2. Add server-side host, assignment, status, and channel support.
3. Add the independent Host Agent app and local sync loop.

Server-side Host Agent domain logic lives in `apps/backplane`, under the Skills domain. Phoenix socket and channel plumbing lives in `apps/backplane_web`. The Host Agent app must not depend on `:backplane`; it talks to Backplane through Phoenix Channel messages and HTTPS archive downloads.

Use processes only where runtime state requires them. The Host Agent worker and Phoenix socket client are supervised processes. Config parsing, checksum verification, manifest read/write, bundle validation, reconciliation, and install planning are plain modules with pure or mostly pure functions.

## Server Data Model

Add these tables after the archive-backed Skills Hub fields exist:

- `skill_hosts`: host identity, bcrypt `token_hash`, active flag, heartbeat metadata, configured targets, `last_seen_at`, status, and timestamps.
- `skill_host_assignments`: desired state for a host and skill, including `host_id`, `skill_id`, target names, enabled flag, metadata, and timestamps.
- `skill_host_statuses`: latest reported state per host and skill, including desired checksum, installed checksum, target names, status, error text, metadata, and timestamps.

The existing `skills.id` column is text, so assignment and status references to skills must use text-compatible foreign keys. Do not use `:binary_id` for `skill_id` unless the Skills Hub schema has already been migrated to binary IDs.

Use the skill slug or sanitized skill name for filesystem paths. Use skill id plus checksum for identity and change detection.

## WebSocket Transport

Use Phoenix Channels over WebSocket via `gsmlg-dev/phoenix_socket_client`.

Server side:

- Add `BackplaneWeb.HostAgentSocket`.
- Mount it from `BackplaneWeb.Endpoint`, for example at `/host-agent/socket`.
- Add `BackplaneWeb.HostAgentChannel`.
- Use a host-specific topic after authentication, such as `host_agent:<host_id>`.

Client side:

- Add `{:phoenix_socket_client, "~> 0.7.0"}` to `apps/backplane_host_agent`.
- Start the socket client under `Backplane.HostAgent.Application`.
- Join the host-agent channel after loading config.
- Push heartbeat and sync result messages over the channel.
- Receive desired-state replies or desired-state change notifications over the channel.

The WebSocket is the control plane. Archive bytes should continue to use authenticated HTTPS download URLs. Keep large binary archive transfer out of channel messages in v1.

## Authentication

Host tokens are created by an admin in v1. There is no open self-registration.

Store only bcrypt token hashes on the server, matching the existing client-token convention. Authenticate the WebSocket upgrade with a host token. Prefer a custom `X-Backplane-Host-Token` header because Phoenix socket `connect_info` can expose configured `x-` headers. Query-string token auth should be a fallback only if the client library or deployment environment cannot pass headers.

After successful authentication, the server assigns the socket to the host record, updates `last_seen_at`, and permits the host to join its own topic only.

## Channel Protocol

Use JSON-like payloads carried by Phoenix Channel events.

Client pushes:

- `heartbeat`: machine name, hostname, agent version, targets, and host metadata.
- `get_desired`: request the current desired skill assignments.
- `sync_started`: started timestamp and local manifest summary.
- `sync_result`: final sync status and per-skill results.
- `sync_error`: top-level failure before a normal sync result can be produced.

Server replies or broadcasts:

- `desired`: full desired-state snapshot for the authenticated host.
- `desired_changed`: signal that the host should request or receive a fresh desired-state snapshot.
- `error`: structured error with code and message.

Desired-state skill entries should include:

```json
{
  "id": "db/abc123",
  "slug": "repo-review",
  "name": "Repo Review",
  "version": "0.1.0",
  "checksum": "sha256:<archive-hash>",
  "targets": ["agents"],
  "enabled": true,
  "download_url": "/api/host-agent/skills/db%2Fabc123/download"
}
```

## Host Agent App

Create `apps/backplane_host_agent` with these modules:

- `Backplane.HostAgent`: public facade with `sync_now/0` and `status/0`.
- `Backplane.HostAgent.Application`: supervision tree for the socket client and worker.
- `Backplane.HostAgent.Config`: TOML and environment config loader.
- `Backplane.HostAgent.Channel`: wrapper around Phoenix socket client join and push behavior.
- `Backplane.HostAgent.Worker`: sync coordinator and reconnect-aware state owner.
- `Backplane.HostAgent.Reconciler`: desired-vs-manifest diff.
- `Backplane.HostAgent.Installer`: archive download, checksum verification, validation, and atomic install.
- `Backplane.HostAgent.Manifest`: local manifest read/write.
- `Backplane.HostAgent.LocalStore`: filesystem paths, work dirs, and target dirs.
- `Backplane.HostAgent.Reporter`: channel payload formatting.
- `Backplane.HostAgent.Checksum`: SHA-256 helpers.
- `Backplane.HostAgent.SkillBundle`: validates bundle shape.

Keep dependencies minimal: `phoenix_socket_client`, `req`, `jason` or Elixir `JSON` if practical, and `toml`.

## Local Runtime Flow

1. Load TOML/env config.
2. Read the local manifest, defaulting to an empty schema-versioned manifest.
3. Start and authenticate the Phoenix socket client.
4. Join the host-agent channel.
5. Send heartbeat.
6. Request desired state or respond to `desired_changed`.
7. Reconcile desired state against manifest and configured targets.
8. Download required archives over HTTPS.
9. Verify checksum.
10. Validate the skill bundle contains `SKILL.md` and safe paths.
11. Atomically install into each enabled target.
12. Update manifest only after successful target writes.
13. Push sync result over the channel.
14. Schedule the next sync or wait for the next desired-state signal.

## Reconciliation Rules

Compute these actions:

- `install`: desired skill is missing from the Host Agent manifest.
- `update`: checksum changed or target set changed.
- `remove`: a manifest-owned skill is no longer desired.
- `repair`: files are missing or corrupt for a manifest-owned skill.
- `noop`: local state already matches desired state.

Do not remove manually installed skills. Removal applies only to skills recorded as owned by Backplane Host Agent in the manifest.

## Install Semantics

Installer behavior must avoid partial writes:

1. Download archive to the configured work dir.
2. Verify checksum before extraction.
3. Unpack into a temporary work dir.
4. Validate bundle shape and safe paths.
5. Copy or move into `<target>/.backplane-tmp/<skill-slug>-<nonce>`.
6. Rename existing `<target>/<skill-slug>` to a backup path.
7. Rename temp dir to `<target>/<skill-slug>`.
8. Remove backup after success.
9. Restore backup if replacement fails after the old skill was moved.
10. Update manifest only after all target installs succeed.

Target roots must already exist in v1. If a target path is missing, report `target_missing` and do not create arbitrary parent directories.

## Error Handling

- WebSocket disconnect: keep local skills as-is, reconnect with exponential backoff, and report status after reconnect.
- Desired-state failure: do not change the filesystem.
- Download failure: do not change the filesystem, report `failed`.
- Checksum mismatch: discard archive, report `checksum_mismatch`.
- Invalid bundle: discard archive, report `failed` with validation detail.
- Missing target root: report `target_missing`.
- Partial install failure: restore backup when possible; leave manifest unchanged.
- Sync result failure: keep local manifest, retry reporting on next connected sync cycle.

## Admin UI

Do not overbuild UI before the protocol works.

V1 should add enough admin UI to operate and debug sync:

- Hosts list: host name, last seen, agent version, status, target count.
- Host detail: configured targets, desired skills, reported installed skills, status/errors.
- Skill detail or assignment view: assigned hosts and target names.
- Token creation or rotation for host records.

Use the existing DuskMoon UI system and route conventions. Avoid placing Host Agent control under the browser CSRF/session API path; the channel and archive download endpoints should use host-token auth.

## Tests

Skills Hub archive foundation:

- Archive validation accepts valid `.tar.gz` skill bundles.
- Missing `SKILL.md`, symlink entries, absolute paths, and `..` traversal are rejected.
- Metadata, checksum, and file list are extracted correctly.
- Archive download streams the stored archive.

Server channel and host state:

- Socket auth succeeds with a valid host token.
- Socket auth rejects missing or invalid tokens.
- Host can join only its own topic.
- `heartbeat` creates or updates host heartbeat state.
- `get_desired` returns enabled assignments only.
- `sync_result` updates `skill_host_statuses`.
- Disabled assignments are omitted from desired state.

Host Agent app:

- Config parses TOML.
- Manifest read/write round-trips.
- Reconciler computes install, update, noop, remove, and repair.
- Checksum verifies `sha256:<hex>`.
- Installer rejects bundles without `SKILL.md`.
- Installer installs valid bundles atomically into a temp target.
- Installer does not remove manually installed skills.
- Channel wrapper sends heartbeat and sync result payloads.
- Worker reports failure on download or checksum error.

End-to-end:

- One assigned skill installs into one temp target.
- Manifest records installed skill and ownership.
- Server status shows synced.
- Running sync a second time is idempotent.

## Implementation Phases

1. Finish archive-backed Skills Hub foundation from the existing Skills Hub plan.
2. Add `skill_hosts`, `skill_host_assignments`, and `skill_host_statuses`.
3. Add server context modules for hosts, assignments, desired state, and status reporting.
4. Add Phoenix socket and channel transport for Host Agent control messages.
5. Add authenticated archive download route for Host Agent.
6. Add minimal admin UI for hosts, assignments, token rotation, and status.
7. Add `apps/backplane_host_agent` skeleton, config, manifest, and reconciler.
8. Add installer, checksum, and bundle validation.
9. Wire the Phoenix socket client and worker sync loop.
10. Add scoped integration and end-to-end tests.

## Acceptance Criteria

- Archive-backed Skills Hub exposes checksum-addressed skill archives.
- A host can authenticate over Phoenix Channel.
- A host can heartbeat over the channel.
- A host can receive desired skill assignments.
- A host can download assigned skill archives over authenticated HTTPS.
- A host can verify and install skills into configured target directories.
- The local manifest records Host Agent ownership.
- Sync status is reported to Backplane and stored per host/skill.
- Re-running sync is idempotent.
- Core server, channel, host-agent, and end-to-end tests pass.
