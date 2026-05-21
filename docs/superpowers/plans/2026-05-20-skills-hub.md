# Backplane Skills Hub Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the v1 Skills Hub from `docs/skill-hub-design.md`: upload, store, index, search, load, download, import, and export portable `.tar.gz` skill archives without executing or rewriting uploaded skills.

**Architecture:** Keep all domain logic in `apps/backplane` behind a new public `Backplane.Skills` context. Store archive bytes in content-addressed local blob storage, store searchable metadata in the existing `skills` table, and expose the same context through HTTP, MCP tools, and the admin LiveView.

**Tech Stack:** Elixir 1.18, Ecto/PostgreSQL, Plug.Router, Phoenix LiveView, phoenix_duskmoon, ETS registry, Erlang `:erl_tar`, local filesystem blob storage.

---

## Source And Scope

Source PRD: `docs/skill-hub-design.md`

Implementation scope is PRD v1 only:

- Current archive per slug, last-write-wins.
- Store uploaded archives as uploaded.
- No immutable versions, no `skill_revisions`, no dependency resolution, no install tool.
- Keep existing single-string DB skill behavior working.
- Replace stale tests that assert removed/non-v1 behavior such as dependency resolution and version history.

Current preparation findings:

- `docs/skill-hub-design.md` is currently untracked; do not stage or rewrite it unless explicitly asked.
- Existing working tree has unrelated dirty files: `AGENTS.md`, `CLAUDE.md`, `.claude/`.
- `mix` is not on the ambient PATH. Use `devenv shell -- <command>`.
- Baseline scoped test attempt through `devenv shell -- mix test ...` failed before tests ran because PostgreSQL was shutting down while Mix tried to create `Backplane.Repo`.

## File Map

Create:

- `apps/backplane/priv/repo/migrations/20260520000001_extend_skills_for_archives.exs`
- `apps/backplane/lib/backplane/skills.ex`
- `apps/backplane/lib/backplane/skills/archive.ex`
- `apps/backplane/lib/backplane/skills/blob.ex`
- `apps/backplane/lib/backplane/skills/blob/local_fs.ex`
- `apps/backplane/lib/backplane/skills/ingest.ex`
- `apps/backplane/lib/backplane/skills/export.ex`
- `apps/backplane/lib/backplane/skills/api_router.ex`
- `apps/backplane/test/support/skill_archive_case.ex`
- `apps/backplane/test/backplane/skills/archive_test.exs`
- `apps/backplane/test/backplane/skills/blob/local_fs_test.exs`
- `apps/backplane/test/backplane/skills/ingest_test.exs`
- `apps/backplane/test/backplane/skills/api_router_test.exs`
- `apps/backplane/test/backplane/skills/export_test.exs`

Modify:

- `apps/backplane/lib/backplane/skills/skill.ex`
- `apps/backplane/lib/backplane/skills/loader.ex`
- `apps/backplane/lib/backplane/skills/registry.ex`
- `apps/backplane/lib/backplane/skills/search.ex`
- `apps/backplane/lib/backplane/skills/sources/database.ex`
- `apps/backplane/lib/backplane/skills/source.ex`
- `apps/backplane/lib/backplane/settings.ex`
- `apps/backplane/lib/backplane/tools/skill.ex`
- `apps/backplane/lib/backplane/transport/mcp_handler.ex`
- `apps/backplane/test/support/fixtures.ex`
- `apps/backplane/test/backplane/skills/skill_test.exs`
- `apps/backplane/test/backplane/skills/loader_test.exs`
- `apps/backplane/test/backplane/skills/registry_test.exs`
- `apps/backplane/test/backplane/skills/search_test.exs`
- `apps/backplane/test/backplane/skills/sources/database_test.exs`
- `apps/backplane/test/backplane/tools/skill_test.exs`
- `apps/backplane/test/backplane/transport/mcp_handler_test.exs`
- `apps/backplane_web/lib/backplane_web/router.ex`
- `apps/backplane_web/lib/backplane_web/components/layouts.ex`
- `apps/backplane_web/lib/backplane_web/live/skill_live.ex`
- `apps/backplane_web/test/backplane_web/live/skill_live_test.exs`

## Shared Decisions

- `Backplane.Skills` is the public context. Callers should not reach into `Ingest`, `Blob.LocalFS`, or `Search` directly except existing tests scoped to those modules.
- Keep `id` as the primary key for backward compatibility. Add `slug` as the public handle and unique lookup key.
- For legacy DB skills, backfill `slug` from a sanitized name plus an `id` hash suffix to avoid migration-time collisions.
- `content` remains the extracted `SKILL.md` body for archive-backed skills and the whole markdown body for legacy DB skills.
- `content_hash` is the SHA-256 of the uploaded archive for archive-backed skills. For legacy DB skills it remains the current content hash.
- `archive_ref` format is `sha256/<hex>.tar.gz`.
- Do not store every file path in the database for v1. `skill::load` and `GET /api/skills/:slug` should read the file list by scanning the stored archive.
- Keep full-text search on `name`, `description`, and `content`. Tags are handled through the existing array index and explicit `tags` filter.
- `skill::publish` should accept archive bytes, not a server-local directory path. A remote MCP caller cannot assume Backplane shares the caller filesystem.
- Add `/admin/skills` as the canonical LiveView route and keep `/admin/skill` as a compatibility alias during v1.

## Task 1: Schema And Public Context

**Files:**

- Create: `apps/backplane/priv/repo/migrations/20260520000001_extend_skills_for_archives.exs`
- Create: `apps/backplane/lib/backplane/skills.ex`
- Modify: `apps/backplane/lib/backplane/skills/skill.ex`
- Modify: `apps/backplane/lib/backplane/skills/sources/database.ex`
- Modify: `apps/backplane/lib/backplane/skills/source.ex`
- Test: `apps/backplane/test/backplane/skills/skill_test.exs`
- Test: `apps/backplane/test/backplane/skills/sources/database_test.exs`

- [ ] Run impact checks before editing symbols:

```bash
npx gitnexus analyze
```

Then run `gitnexus impact` through the MCP tool for `Backplane.Skills.Skill`, `Backplane.Skills.Sources.Database`, and `Backplane.Skills.Registry`. If GitNexus cannot resolve Elixir module symbols, record that in the task notes and proceed with source-level `rg` references.

- [ ] Write failing schema tests for the new fields:

Expected behavior:

- `Skill.changeset/2` accepts `slug`, `meta`, `archive_ref`, `size_bytes`, `file_count`, `version`, `license`, `homepage`, `author`, and source fields.
- `slug` is required for new rows.
- legacy `Database.create/1` derives a slug from the skill name and still works without archive fields.

- [ ] Add the archive metadata migration.

Migration shape:

```elixir
defmodule Backplane.Repo.Migrations.ExtendSkillsForArchives do
  use Ecto.Migration

  def change do
    alter table(:skills) do
      add :slug, :text
      add :version, :text
      add :license, :text
      add :homepage, :text
      add :author, :text
      add :meta, :map, null: false, default: %{}
      add :archive_ref, :text
      add :size_bytes, :bigint
      add :file_count, :integer
      add :source_kind, :text
      add :source_uri, :text
      add :source_rev, :text
    end

    execute("""
    UPDATE skills
    SET slug =
      trim(both '-' from regexp_replace(lower(coalesce(nullif(name, ''), id)), '[^a-z0-9]+', '-', 'g'))
      || '-' || substr(md5(id), 1, 8)
    WHERE slug IS NULL
    """)

    create unique_index(:skills, [:slug])

    execute("ALTER TABLE skills ALTER COLUMN slug SET NOT NULL")
  end
end
```

- [ ] Add `Backplane.Skills` context functions:

Required functions:

- `list/1`
- `search/2`
- `get/1`
- `get_by_slug/1`
- `delete/1`
- `ingest_archive/2`
- `archive_stream/1`
- `export/1`
- `import/2`

- [ ] Update DB source behavior and fixtures to return archive metadata when present.

- [ ] Run scoped tests:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills/skill_test.exs apps/backplane/test/backplane/skills/sources/database_test.exs
```

Expected: schema/source tests pass. If the DB service is unavailable, stop and report the environment blocker.

## Task 2: Archive Reader And Validation

**Files:**

- Create: `apps/backplane/lib/backplane/skills/archive.ex`
- Create: `apps/backplane/test/support/skill_archive_case.ex`
- Test: `apps/backplane/test/backplane/skills/archive_test.exs`
- Modify: `apps/backplane/lib/backplane/skills/loader.ex`
- Test: `apps/backplane/test/backplane/skills/loader_test.exs`

- [ ] Write failing archive tests for:

- accepts a `.tar.gz` directory containing `SKILL.md`
- reads optional `meta.json`
- returns the file list relative to the skill root
- rejects missing `SKILL.md`
- rejects absolute paths
- rejects `..` path traversal
- rejects symlink entries
- rejects archives above configured max file count

- [ ] Implement `Backplane.Skills.Archive.inspect/2`.

Return shape:

```elixir
{:ok,
 %{
   skill_md: binary(),
   skill_entry: map(),
   meta: map(),
   files: [String.t()],
   file_count: non_neg_integer(),
   size_bytes: non_neg_integer()
 }}
```

Use `:erl_tar` for tar handling. Validate tar entry names before extracting content. Do not write extracted files into the final blob store.

- [ ] Extend `Loader.parse/1` only as needed for current frontmatter behavior. Do not add dependency-resolution semantics.

- [ ] Run scoped tests:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills/archive_test.exs apps/backplane/test/backplane/skills/loader_test.exs
```

Expected: archive and loader tests pass.

## Task 3: Local Blob Storage

**Files:**

- Create: `apps/backplane/lib/backplane/skills/blob.ex`
- Create: `apps/backplane/lib/backplane/skills/blob/local_fs.ex`
- Modify: `apps/backplane/lib/backplane/settings.ex`
- Test: `apps/backplane/test/backplane/skills/blob/local_fs_test.exs`

- [ ] Write failing blob tests using `@tag :tmp_dir`:

- `put/2` stores bytes under `<root>/sha256/<hash>.tar.gz`
- `get/1` returns a stream for existing archives
- `exists?/1` returns true only for present blobs
- `delete/1` removes an archive without failing when the file is already absent

- [ ] Add settings defaults:

- `skills.archive.max_bytes`, default `20_000_000`
- `skills.archive.max_files`, default `500`
- `skills.blob.local_root`, default `nil`

- [ ] Implement `Backplane.Skills.Blob.LocalFS`.

Use `Settings.get("skills.blob.local_root") || Path.join(:code.priv_dir(:backplane), "skills_blobs")` as the root. Write to a temporary path and rename into place after a successful write.

- [ ] Run scoped tests:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills/blob/local_fs_test.exs
```

Expected: blob tests pass.

## Task 4: Ingest Pipeline

**Files:**

- Create: `apps/backplane/lib/backplane/skills/ingest.ex`
- Modify: `apps/backplane/lib/backplane/skills.ex`
- Modify: `apps/backplane/lib/backplane/skills/registry.ex`
- Test: `apps/backplane/test/backplane/skills/ingest_test.exs`
- Test: `apps/backplane/test/backplane/skills/registry_test.exs`

- [ ] Write failing ingest tests for:

- slug resolution order: `meta.json.slug`, then `SKILL.md` name, then archive filename
- same slug and same hash is a no-op
- same slug and different hash replaces archive metadata
- invalid archive does not write a blob
- successful ingest refreshes `Registry` and broadcasts `notifications/prompts/list_changed`

- [ ] Implement `Backplane.Skills.Ingest.ingest/2`.

Required pipeline:

```text
stage upload -> compute sha256 -> validate archive -> parse metadata -> write blob -> upsert row -> cleanup on failure -> refresh registry
```

Use `Repo.transact/1` for the DB write and only call `Registry.refresh/0` after the transaction succeeds.
Blob and database writes cannot be atomic together, so explicitly delete the newly written blob if the DB write fails.

- [ ] Update `Registry.refresh/0` entries to include slug, version label, license, homepage, archive_ref, size_bytes, file_count, and source metadata.

- [ ] Run scoped tests:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills/ingest_test.exs apps/backplane/test/backplane/skills/registry_test.exs
```

Expected: ingest and registry tests pass.

## Task 5: Search And Metadata Results

**Files:**

- Modify: `apps/backplane/lib/backplane/skills/search.ex`
- Modify: `apps/backplane/lib/backplane/skills/registry.ex`
- Test: `apps/backplane/test/backplane/skills/search_test.exs`
- Test: `apps/backplane/test/backplane/skills/search_reranking_test.exs`

- [ ] Replace stale tests for `source` and `tools` filters with v1 filters:

- full-text query
- tag AND filter
- enabled-only filter
- limit
- metadata fields included in results
- content omitted from search/list results

- [ ] Update `Search.query/2` result serialization to include:

```elixir
%{
  id: s.id,
  slug: s.slug,
  name: s.name,
  description: s.description,
  tags: s.tags,
  version: s.version,
  license: s.license,
  homepage: s.homepage,
  content_hash: s.content_hash,
  archive_ref: s.archive_ref,
  size_bytes: s.size_bytes,
  file_count: s.file_count
}
```

- [ ] Run scoped tests:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills/search_test.exs apps/backplane/test/backplane/skills/search_reranking_test.exs
```

Expected: search tests pass.

## Task 6: HTTP API

**Files:**

- Create: `apps/backplane/lib/backplane/skills/api_router.ex`
- Modify: `apps/backplane_web/lib/backplane_web/router.ex`
- Test: `apps/backplane/test/backplane/skills/api_router_test.exs`

- [ ] Write failing API tests for:

- `GET /api/skills?q=&tags=&limit=`
- `GET /api/skills/:slug`
- `GET /api/skills/:slug/archive`
- `POST /api/skills` with `application/x-tar+gzip`
- `POST /api/skills` with multipart `archive`
- `DELETE /api/skills/:slug`
- `GET /api/skills/missing` returns 404
- invalid upload returns 422 and does not commit a blob

- [ ] Add an API pipeline that does not use `:browser`, CSRF, or admin auth.

Router shape:

```elixir
pipeline :api do
  plug :accepts, ["json"]
end

scope "/api" do
  pipe_through :api
  forward "/skills", Backplane.Skills.ApiRouter
end
```

Leave the existing `/api/llm` route untouched unless tests prove the pipeline ordering breaks it.

- [ ] Implement `Backplane.Skills.ApiRouter`.

Use JSON responses for metadata and chunked/file streaming for archives. For raw tar uploads, read the request body to a temporary file using repeated `Plug.Conn.read_body/2` calls rather than buffering the full archive in memory.
Endpoint-level parsers already handle multipart and JSON before the router, so tests must cover both multipart temp-file uploads and raw `application/x-tar+gzip` bodies.

- [ ] Run scoped tests:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills/api_router_test.exs
```

Expected: API tests pass.

## Task 7: MCP Tools

**Files:**

- Modify: `apps/backplane/lib/backplane/tools/skill.ex`
- Modify: `apps/backplane/lib/backplane/transport/mcp_handler.ex`
- Test: `apps/backplane/test/backplane/tools/skill_test.exs`
- Test: `apps/backplane/test/backplane/transport/mcp_handler_test.exs`

- [ ] Replace stale MCP tests for dependency resolution, `skill::versions`, and non-v1 source filters.

- [ ] Add failing tests for v1 tools:

- `skill::list` returns metadata without content
- `skill::search` supports query, tags, and limit
- `skill::load` accepts `slug` and returns `skill_md`, `meta_json`, `files`, and archive metadata
- `skill::download` returns archive URL, hash, size, and metadata
- `skill::publish` accepts a base64 `.tar.gz` archive and ingests it

- [ ] Update tool registration.

Remove public exposure of `skill::create` and `skill::update` unless backward compatibility is explicitly needed by existing clients. If kept, mark them as legacy in descriptions and keep tests separate from v1 archive behavior.

- [ ] Wire `Backplane.Audit.log_skill_load/1` when `skill::load` succeeds.

The current MCP handler has client metadata on `conn`, while native tools receive only argument maps. Implement either handler-level logging for `skill::load` or thread client metadata into native tool calls before logging.

- [ ] Run scoped tests:

```bash
devenv shell -- mix test apps/backplane/test/backplane/tools/skill_test.exs apps/backplane/test/backplane/transport/mcp_handler_test.exs
```

Expected: MCP tool and transport tests pass.

## Task 8: Import And Export

**Files:**

- Create: `apps/backplane/lib/backplane/skills/export.ex`
- Modify: `apps/backplane/lib/backplane/skills/api_router.ex`
- Modify: `apps/backplane/lib/backplane/skills.ex`
- Test: `apps/backplane/test/backplane/skills/export_test.exs`
- Test: `apps/backplane/test/backplane/skills/api_router_test.exs`

- [ ] Write failing export/import tests:

- `GET /api/skills/export` streams a collection archive
- export contains `manifest.json`
- export contains stored archives unchanged under `archives/<slug>.tar.gz`
- `POST /api/skills/import` ingests every archive in an exported collection
- importing a collection is idempotent for unchanged hashes

- [ ] Implement collection format:

```text
manifest.json
archives/<slug>.tar.gz
archives/<slug-2>.tar.gz
```

`manifest.json` is for import bookkeeping only. Do not rewrite each skill archive.

- [ ] Run scoped tests:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills/export_test.exs apps/backplane/test/backplane/skills/api_router_test.exs
```

Expected: import/export tests pass.

## Task 9: Admin LiveView

**Files:**

- Modify: `apps/backplane_web/lib/backplane_web/router.ex`
- Modify: `apps/backplane_web/lib/backplane_web/components/layouts.ex`
- Modify: `apps/backplane_web/lib/backplane_web/live/skill_live.ex`
- Test: `apps/backplane_web/test/backplane_web/live/skill_live_test.exs`

- [ ] Write failing LiveView tests for:

- `/admin/skills` renders inside the admin shell
- list shows uploaded skill name, slug, tags, hash, and size
- search filters the list
- upload accepts `.tar.gz` and calls the skills context
- invalid upload displays validation error
- delete removes a skill and updates the list
- `/admin/skill` still resolves during v1 compatibility

- [ ] Update navigation to use `/admin/skills`.

- [ ] Implement `SkillLive` using DuskMoon components.

Use `handle_params/3` for database-backed list/search loading. Keep `mount/3` to setup assigns and upload config only.

- [ ] Run scoped tests:

```bash
devenv shell -- mix test apps/backplane_web/test/backplane_web/live/skill_live_test.exs
```

Expected: LiveView tests pass.

## Task 10: Final Verification

- [ ] Run all in-scope skill tests:

```bash
devenv shell -- mix test \
  apps/backplane/test/backplane/skills \
  apps/backplane/test/backplane/tools/skill_test.exs \
  apps/backplane/test/backplane/transport/mcp_handler_test.exs \
  apps/backplane_web/test/backplane_web/live/skill_live_test.exs
```

- [ ] Run formatting:

```bash
devenv shell -- mix format
```

- [ ] Run GitNexus changed-scope check before commit:

Use `gitnexus_detect_changes` through the MCP tool, or `mcp__gitnexus__.detect_changes` if implementing in Codex.

- [ ] Review PRD checklist manually against `docs/skill-hub-design.md`.

Expected v1 acceptance:

- archive upload stores bytes unchanged
- archive download returns the original bytes
- invalid archives do not create rows or blobs
- search/list omit skill content
- load returns `SKILL.md`, `meta.json`, file list, and archive metadata
- import/export round trip works between two empty databases in tests
- admin UI supports list/search/upload/download/delete

If tests outside this scope fail, list them and stop.

## Recommended Parallel Execution

Sequential foundation:

1. Task 1
2. Task 2
3. Task 3
4. Task 4

Parallel after `Backplane.Skills` context is stable:

- Worker A: Task 5 search/registry metadata.
- Worker B: Task 6 HTTP API.
- Worker C: Task 7 MCP tools.
- Worker D: Task 9 admin LiveView.

Final serial integration:

1. Task 8 import/export.
2. Task 10 verification.

Keep worker write sets disjoint. Workers are not alone in the codebase and must not revert edits made by others.
