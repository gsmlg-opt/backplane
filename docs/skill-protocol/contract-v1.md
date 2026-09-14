# Backplane Skill Protocol v1 Contract

Status: frozen and verified through BP-06. Backplane server and package client implementations conform to this contract; external consumer adoption remains deferred.

## Boundary and Identity

The independently consumable OTP application is `:backplane_skill_protocol`, namespace `Backplane.SkillProtocol`. It has no Repo, Ecto, Phoenix, sibling-app, root-config, startup scan, polling process, or hidden credential dependency.

The public v1 mount is top-level `/skill-protocol/v1`. It is not under `/api` or `/skills`. A `SkillRef` is source-instance ID plus opaque stable Skill ID; an exact reference additionally has opaque revision and `artifact_digest`. Display name, package SemVer, author `version`, wire version, and revision are distinct.

`artifact_digest` is `sha256:` plus lowercase SHA-256 of the exact gzip bytes. Fetch is always qualified by Skill ID and exact revision; digest alone never authorizes access.

## Access

BP-04 extends existing auth resources with `:skill_protocol`. Every catalog, resolve, artifact, and conditional 304 decision authorizes. Read scope is `skill::read`; `skill::*` and `*` also satisfy it. Deployments may conceal denied references as 404, but may never serve their bytes. No new identity system is introduced.

## Operations

- `GET /skill-protocol/v1/catalog`: bounded `limit` (default 20, maximum 100), optional filters and opaque context-bound keyset cursor. Returns committed lightweight descriptors and `next_cursor`; ordering is deterministic and pagination over mutations is best effort.
- `GET /skill-protocol/v1/resolve?skill_id=...&revision=...`: omitted revision snapshots current once; explicit revision never falls back. Returns one immutable manifest.
- `GET /skill-protocol/v1/artifact?skill_id=...&revision=...`: returns exact `application/x-tar+gzip` bytes, content length when known, and a strong ETag derived from the digest.

Schemas live in `apps/backplane_skill_protocol/priv/schemas`. JSON objects reject unspecified protocol fields where the schema says `additionalProperties: false`; unknown document extensions remain preserved in document metadata.

## Document Profile

Parsing preserves exact original bytes, frontmatter bytes, body bytes, and string-keyed metadata. It accepts UTF-8 BOM, LF/CRLF boundaries, YAML comments, multiline values, and nested extension data. Duplicate keys, invalid UTF-8, malformed/non-map YAML, unsafe mandatory capabilities, malformed recognized invocation booleans, and configured limit violations fail explicitly. No untrusted atoms are created.

Standard validation requires lowercase kebab-case `name` and nonempty `description`. Legacy validation may accept any nonempty string name and missing description with a warning; missing metadata is never invented. `disable-model-invocation: true` makes automatic eligibility fail but permits explicit selection when host policy does. Host disablement always wins. Eligibility grants no tools.

## Bundle Profile

Profile `backplane.skill-bundle.v1` is one logical root with root `SKILL.md`. Nested files named `SKILL.md` are resources. The inventory contains every regular file's relative path, byte length, and lowercase SHA-256 plus total unpacked bytes. Only regular files/directories are accepted; links, devices, escaping/absolute/drive/backslash/encoded-dot paths, duplicates, case-folding collisions, and file/directory conflicts fail.

Default limits are those in the implementation plan: 2 MiB document, 256 KiB frontmatter, nesting 32, scan depth 16/10,000 entries, 16 MiB compressed, 64 MiB expanded, 8 MiB per file, 1,000 archive entries, and path depth 16. Gzip expansion is bounded while processing. Preparation writes to operation-owned same-filesystem staging and renames only after verification. The caller owns the immutable prepared-root lifetime. Resource reads recheck inventory and canonical containment. Script/template bytes are readable but never executed.

## Consumer Preparation

`Source.Backplane.new/1` accepts a configured client. `prepare/4` requires a fresh `:destination` whose parent exists. It resolves at most once, fetches the artifact for that exact reference, checks source/ref/digest and manifest/bundle agreement, then prepares the complete bundle. Missing, invalid, or existing destinations fail without overwriting or deleting them.

Every invocation performs a new remote fetch. There is no consumer-side persistent cache, offline fallback, ownership coordinator, quota, eviction, or background cleanup. A remote failure is returned even when another destination already contains the same revision. Successful destinations remain host-owned until host cleanup. These consumer semantics do not alter the server's retained immutable publication artifacts.

## Errors

Expected failures are tagged errors with stable code, phase, bounded message/context, and retryability. V1 codes are `invalid_request`, `invalid_document`, `invalid_bundle`, `ambiguous_skill`, `not_found`, `revision_unavailable`, `unauthorized`, `forbidden`, `unsupported_protocol`, `unsupported_capability`, `integrity_mismatch`, `limit_exceeded`, `capacity_exceeded`, `timeout`, `cancelled`, and `temporarily_unavailable`. BP-04 freezes HTTP mappings against existing disclosure policy.
