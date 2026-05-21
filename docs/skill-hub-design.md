# PRD — Backplane Skills Hub

**Status:** Draft (v1 scope)
**Owner:** gsmlg-opt
**Target repo:** [`gsmlg-opt/backplane`](https://github.com/gsmlg-opt/backplane)
**Last updated:** 2026-05-20

---

## 1. Mental model

> Backplane Skills Hub is a lightweight internal library for portable agent-skill archives. A skill archive is stored **as uploaded**, keyed by SHA-256, and indexed by metadata extracted from `SKILL.md` and optional `meta.json`. Backplane does not execute skills, does not rewrite `SKILL.md`, and does not act as a package manager in v1. It exposes search, upload, download, import, and export over HTTP and MCP so trusted machines can share skills easily.

This keeps the implementation aligned with the actual goal — simple sharing of agent skills between machines — without committing to full package-registry semantics too early.

## 2. Background

Backplane is a self-hosted gateway with an MCP Hub and an LLM Proxy, sitting under the Samgita (project/agent orchestration) and Synapsis (agent runtime) stack. Skills are reusable, agent-facing instruction bundles authored as `SKILL.md` directories. The hub lets trusted machines publish and pull those bundles.

The existing skills implementation in `apps/backplane/lib/backplane/skills/` already provides a `skills` table with `tsvector` + GIN indexes, an ETS `Registry`, a Postgres `Search`, a `Source` behaviour, a `Loader` (YAML frontmatter + markdown), and MCP tools (`skill::search/load/list/create/update`). It works for single-string skills but cannot store directory bundles or share archives between machines.

## 3. Goals (v1)

Store skill archives **as-is**, index minimal metadata, and allow:

- **Upload** a `.tar.gz` skill bundle.
- **Download** the stored archive, unchanged.
- **Search / list** skills by full-text and tags.
- **Load** a skill's `SKILL.md` + `meta.json` + file list for agent context.
- **Import / export** archives for machine-to-machine sharing.

## 4. Non-goals (v1)

- No skill execution — Backplane stores and serves; Synapsis runs.
- No mutation of uploaded archives or `SKILL.md`.
- No semver registry, immutable versions, yank semantics, or dependency resolution.
- No installing skills to an agent filesystem (Backplane may run on a different machine).
- No authentication, scopes, or quotas — internal, trusted-network deployment.

## 5. Bundle format

A skill publishes as a **`.tar.gz`** of a directory:

```text
skill-folder/
├── SKILL.md        # unchanged, authored by skill-creator
├── meta.json       # optional Backplane metadata
├── scripts/        # optional
├── references/     # optional
└── assets/         # optional
```

Rules:

- `SKILL.md` is **required** and **never mutated**. It keeps its existing YAML frontmatter (`name`, `description`, `tags`) and markdown body. The `Loader` is unchanged.
- `meta.json` is **optional, additive** hub metadata. Backplane reads it but does not require it.
- Backplane stores the archive **as uploaded**. It may synthesize metadata into the database when `meta.json` is missing, but does not rewrite the archive by default.

### 5.1 `meta.json` schema

```json
{
  "schema": "backplane.skill.meta/v1",
  "slug": "pdf-fill",
  "version": "1.2.0",
  "license": "MIT",
  "homepage": "https://example.com/pdf-fill",
  "source": {
    "kind": "git",
    "uri": "https://github.com/org/repo",
    "rev": "abc123"
  }
}
```

- `slug` is the stable public handle. `version` is a free-form **label**, not registry semantics.
- `name`, `description`, `tags` are **not** duplicated here — they remain the source of truth in `SKILL.md` frontmatter.

### 5.2 Slug resolution

```text
1. Use meta.json.slug if present.
2. Else derive slug from SKILL.md frontmatter name.
3. Else derive slug from the folder/archive name.
```

### 5.3 Upload behavior (last-write-wins)

```text
same slug + same content_hash      -> no-op
same slug + different content_hash -> replace current archive_ref / content_hash
```

This matches an internal trusted-network deployment and avoids overbuilding. If history becomes useful later, a simple `skill_revisions` table can be added in v2.

## 6. Architecture

### 6.1 Layer boundary

All logic in `apps/backplane`; surfaces (HTTP/LiveView) in `apps/backplane_web`. The public boundary is a single context module `Backplane.Skills`.

### 6.2 Data model

Extend the existing `skills` table. No `skill_versions`, `skill_artifacts`, or `skill_sources` in v1.

```text
skills
├── id : text primary key
├── slug : text unique
├── name : text
├── description : text
├── tags : text[]
├── version : text nullable
├── license : text nullable
├── homepage : text nullable
├── author : text nullable
├── meta : jsonb
├── content_hash : text
├── archive_ref : text         -- "sha256/<hex>.tar.gz"
├── size_bytes : bigint
├── file_count : integer
├── source_kind : text nullable
├── source_uri : text nullable
├── source_rev : text nullable
├── enabled : boolean
└── timestamps
```

The generated `search_vector` (tsvector over name/description/content) and GIN indexes carry over. The single-string `content` column from the current schema stays for backward compatibility; for archive-backed skills, `content` holds the extracted `SKILL.md` body for FTS.

### 6.3 Blob storage

Behaviour `Backplane.Skills.Blob`, one impl in v1:

```elixir
@callback put(hash :: String.t(), Enumerable.t()) :: :ok | {:error, term()}
@callback get(hash :: String.t()) :: {:ok, Enumerable.t()} | {:error, term()}
@callback exists?(hash :: String.t()) :: boolean()
@callback delete(hash :: String.t()) :: :ok | {:error, term()}
```

- `Blob.LocalFS` — root configurable via `system_settings`, default `priv/skills_blobs/`. Archive keyed by SHA-256, stored as uploaded. Streaming both directions so large skills never sit in memory.
- `Blob.S3` — deferred to v2.

### 6.4 Ingest

A single `Backplane.Skills.Ingest` pipeline:

```text
upload → validate safe paths → require SKILL.md → read optional meta.json
       → extract name/description/tags from SKILL.md → write blob → upsert skill row
       → refresh registry
```

Validation runs **before** blob commit. Reject symlinks, `..`, absolute paths; enforce size and file-count caps from `system_settings`. Side effects isolated to the final commit step.

### 6.5 Read paths

Keep the current split: `Registry` (ETS hot cache) for `skill::list`, `Search` (Postgres FTS + tag filter) for `skill::search`. Broadcast `prompts/list_changed` on every commit.

## 7. HTTP API

Mount under `/api/skills` on the existing Bandit endpoint. Unauthenticated, internal only; `AuthPlug` can be layered later without changing routes.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/skills` | Search/list with `q`, `tags`, `limit`, `cursor` |
| `GET` | `/api/skills/:slug` | Skill metadata + file list |
| `GET` | `/api/skills/:slug/archive` | Stream stored `.tar.gz` (as uploaded) |
| `POST` | `/api/skills` | Upload `.tar.gz` (multipart or `application/x-tar+gzip`); last-write-wins by slug |
| `DELETE` | `/api/skills/:slug` | Remove a skill |
| `GET` | `/api/skills/export` | Stream a collection of archives for machine-to-machine sharing |
| `POST` | `/api/skills/import` | Ingest archives exported from another instance |

Export may optionally produce normalized archives with a generated `meta.json`, but the normal `/archive` download returns the stored archive untouched.

## 8. MCP tools

- `skill::list` — list skills with metadata (no content).
- `skill::search` — full-text + tag search via `Search.query`.
- `skill::load` — returns `SKILL.md`, `meta.json`, file list, and archive metadata (hash, size). Default = the current archive for the slug.
- `skill::download` — returns archive URL, hash, size, and metadata. The caller (Synapsis / local agent runtime) handles installation.
- `skill::publish` — bundles a skill directory into `.tar.gz` (npm/hex.pm style) and uploads it.

`skill::install` is intentionally **not** provided — Backplane may not share a filesystem with the agent.

## 9. Admin UI

Minimal LiveView under `/admin/skills`, using DuskMoon components per `CLAUDE.md`:

- list / search
- upload (drag-and-drop `.tar.gz`, validate before commit)
- download
- delete

## 10. Phasing (v1)

```text
Phase 0 — Metadata columns
  Extend skills table with slug, meta, archive_ref, content_hash, size_bytes,
  file_count, source fields, license, homepage, author.
  Keep current single-file skill behavior working.

Phase 1 — Archive ingest
  Accept .tar.gz upload.
  Validate safe paths.
  Require SKILL.md.
  Read optional meta.json.
  Extract name, description, tags from SKILL.md.

Phase 2 — Blob storage
  Store uploaded archive by sha256 under LocalFS.

Phase 3 — HTTP API
  GET    /api/skills
  GET    /api/skills/:slug
  GET    /api/skills/:slug/archive
  POST   /api/skills
  DELETE /api/skills/:slug

Phase 4 — MCP tools
  skill::list
  skill::search
  skill::load
  skill::download
  skill::publish

Phase 5 — Import/export
  GET  /api/skills/export
  POST /api/skills/import

Phase 6 — Minimal admin UI
  list/search/upload/download/delete
```

## 11. Deferred to v2

```text
immutable versions
yank semantics
dependency resolution
requires_tools enforcement
Git source sync
Hub federation
canonical tarball hashing
per-file artifact browsing
S3 blob storage
skill_revisions history table
```

## 12. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Orphan blobs from failed uploads. | Validate bundle **before** blob commit; two-phase ingest (stage then finalise). |
| ETS `Registry` divergence from Postgres. | Single-writer refresh; broadcast on every commit; add a manual rebuild path. |
| Malicious archives (symlinks, path traversal, oversized). | Strict path validation, reject `..`/absolute/symlink, size + file-count caps. |
| Slug collision under last-write-wins. | Acceptable internally for v1; documented. Per-owner namespaces deferred to v2. |
| Audit gap (`skill_load_log` unwritten). | Wire the producer when `skill::load` is updated in Phase 4. |

## 13. Success metrics

- Time from `POST /api/skills` to availability in `skill::search` < 2s p95.
- Archive download p95 < 500ms for skills under 1 MB on local-FS storage.
- Zero orphan blobs older than 7 days.
- 100% of `skill::load` calls produce a `skill_load_log` row.

