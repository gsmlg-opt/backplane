# Skill Protocol Baseline

Recorded 2026-09-11 before BP-00 implementation.

- Checkout: `bd5bc83005fded6f67beefe3fa8abac31eae506a`, branch `feature/skill-protocol`.
- Initial changes: only uncommitted `prd.md` and `implement_plan.md` additions.
- Local toolchain observed: Elixir 1.20.1 on OTP 29. Target remains Elixir >= 1.18 / OTP 28+.
- YAML dependency: `yaml_elixir 2.12.2` with `yamerl 0.10.0` (declared as `~> 2.9`).
- Public router mounts legacy Skills at top-level `/skills`; therefore v1 is frozen at top-level `/skill-protocol/v1`.
- Baseline focused Loader/Archive/Ingest/API/Export command passed 73 tests. Startup emitted existing test-database warnings for absent `skill_hosts.memory_scope` and `mcp_upstreams.protocol_version` columns.

## Existing Ownership

- `Loader` parsed frontmatter and hashed the trimmed Markdown body.
- `Archive` validated tar paths and read `SKILL.md`/`meta.json`, but did not materialize complete resources.
- `Ingest` hashed exact gzip bytes, stored blobs, upserted by slug, refreshed Registry, and removed unreferenced replaced blobs.
- `Skills` owns create/update/delete, archive ingest/access, and blob cleanup.
- `Export` owns collection import/export and delegates imported archives to `Ingest`.
- database/Git source adapters and Registry map persisted/generated content into discovery results.
- API and admin paths remain host-owned; BP-00 through BP-03 add no persistence or route changes.

## Compatibility Contract

- Loader `content_hash`: lowercase unprefixed SHA-256 of the trimmed Markdown body.
- Archive ingest `content_hash`: lowercase unprefixed SHA-256 of the exact gzip bytes.
- Generated/database content hashes remain hashes of their existing mutable content representation.
- Legacy Loader permits a nonempty string name, missing description, numeric author version, and defaults missing version to `1.0.0`; it does not fabricate description in the shared document.
- Unsafe archive paths and entry types are security invariants and do not receive compatibility exceptions.

BP-04 owns revision persistence, publication state, authorization, and v1 routes. BP-05 owns remote transport/cache. They are intentionally absent from M1.
