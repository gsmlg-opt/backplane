# Backplane plugin registry

`Backplane.Plugins` owns publication and distribution; the protocol app validates
packages and the runtime executes consumer components. Import and synchronization
never start plugin MCP servers or modify the gateway's tool registry.

`import_files/2` and `import_archive/2` create candidates. Files are validated and
canonically archived; releases keep the original manifest bytes, optional upstream
version, SHA-256 artifact digest, and source commit. Published artifact content is
never replaced. `publish_release/2` marks a release published and changes a named
channel, defaulting to `stable`. Explicit old releases remain resolvable after an
upgrade. `catalog/1`, `resolve/3`, and `artifact_by_digest/1` expose published content
only. IDs are UUID strings; descriptors include `plugin_id`, `release_id`,
`artifact_digest`, `artifact_url`, `manifest`, `source_commit` and diagnostics.

`compose/4` accepts a manifest, exact `%{skill_id: ..., revision: ..., name: ...}`
selections, additional files, and import attributes. It copies every file from the
selected immutable skill archives. It never follows a moving skill revision.

Sources store a GitHub repository URL, `ref`, `path`, `kind` (`plugin` or
`marketplace`), optional vault `credential_name`, `auto_publish`, `enabled`, and
`interval_seconds`. `sync_source/2` resolves one Git commit before reading files.
Marketplace remote entries resolve their own fixed commits. Each release records
both the catalog commit and plugin origin. Failed entries retain diagnostics and
leave old published releases available. Sources preserve their last successful
sync time when attempts fail or are partial. A source deletion does not unpublish
content or uninstall consumers. Scheduled work runs every thirty seconds and
respects each source's interval; disable it with
`config :backplane_plugins, :sync_enabled, false` for tests. Manual and scheduled
syncs serialize on the source ID.

Installation records separate desired release/enabled state from actual release,
actual enabled state, component status, and report time. A failed report that omits
the actual release retains the previous actual release. Reports retain only known
component status values; raw provider errors and credential-bearing payloads are
not persisted. Client activation and authentication remain consumer responsibilities.

`Backplane.Plugins.Codex.snapshot/1` returns a Codex native marketplace file map;
`export/2` writes it to a new local directory. Every selected release file is copied
unchanged beneath `plugins/<plugin UUID>/`; IDs and artifact hashes live in
`.agents/plugins/backplane-releases.json`, outside `plugin.json`. The marketplace
uses `{source: "local", path: "./plugins/..."}` entries, checked against Codex
`rust-v0.163.0`'s `core-plugins/src/marketplace.rs`. `publish_git/2` is an explicit
side-effecting operation: clone the configured HTTPS Git repository/branch, use its vault
credential, replace the previous managed snapshot, commit and push. Export alone
never pushes. This does not prove Codex has installed or activated an update.

Publishing accepts HTTPS Git hosts such as GitHub and Gitea, without URL userinfo,
query or fragment. Source synchronization remains GitHub-only. Publishing vault
credentials use the `api_key` contract: HTTP Basic with metadata `git_username`
(default `x-access-token`) as username and the stored token as password. The target
must support this method; live Gitea authentication has not been verified. The
authorization header matches only the selected target URL, and publishing disables
HTTP redirects to prevent forwarding it to another origin. SSH and local targets
are unsupported except for explicit local test fixtures.

Source snapshots use Git with hooks disabled and never check out source content.
Regular Git files are supported; symlinks/submodules are rejected. Local repository
URLs are supported only through the explicit `allow_local: true` test option.

The admin routes are `/plugins` (complete catalog, upload and composition),
`/plugins/sources` (source CRUD, manual synchronization and scheduling policy),
`/plugins/releases` (candidate publication, channel selection and rollback), and
`/plugins/distribution` (desired/actual records and explicit Codex exports).
Release pages distinguish package validation, a client support table, and actual
consumer component reports. Shared Runtime portable skills/MCP support does not
imply proprietary extension support or completed Sigma/Synapsis product integration.
Codex interprets its own extensions; only the sample skill and stdio MCP behavior
are verified with Codex 0.163.0. Original metadata and diagnostics remain viewable as JSON.
Original executable file permissions are retained in artifacts and exports.
Native Codex entries keep the original manifest name (Codex requires equality).
An export with equal names from different publishers returns
`:duplicate_codex_plugin_name`; select a channel or pass `plugin_ids: [id, ...]`
to choose an explicit scope. All original identities remain independent in the registry.

Marketplace parsing isolates malformed entries: each gets an index-based safe
diagnostic while valid entries continue. Invalid top-level documents leave the
last successful source commit and releases intact. Local `.` and `./` paths mean
the repository root; only actual traversal segments are rejected, so names such
as `foo..bar` are supported. The current Git adapter snapshots the complete tree
before selecting plugin subdirectories: an unrelated symlink or submodule anywhere
in that tree still rejects the source snapshot.
