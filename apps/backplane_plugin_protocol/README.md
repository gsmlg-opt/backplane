# Backplane Plugin Protocol

Standalone Agent Plugins **1.0.0** package inspection and Backplane distribution
client. No Repo, Phoenix, application supervisor, process execution, filesystem
installation, credential storage or network adapter is required.

```elixir
{:ok, package} = Backplane.PluginProtocol.load(%{
  "plugin.json" => JSON.encode!(%{
    "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
    "name" => "example"
  })
})

{:ok, package} = Backplane.PluginProtocol.load_directory("/path/to/example")
{:ok, artifact} = Backplane.PluginProtocol.Archive.pack(package.files)
digest = Backplane.PluginProtocol.Archive.digest(artifact)
```

`load/2` returns `{:ok, package}` or `{:error, diagnostics}`. Package fields:

- `manifest`: original JSON object, including unknown fields and extensions.
  Unknown fields are reported and ignored for interpretation; original bytes stay
  in `files`. Missing `version` and arbitrary version strings are supported.
- `skills`: immediate `skills/*/SKILL.md` entries with `path`, `root`, `name`,
  `description`, raw `content`, Markdown `body`, YAML `metadata`, and resource
  `files` keyed by their full package-relative paths.
- `mcp_servers`: server-name map of validated raw string-key configurations.
  Types are `stdio`, `streamable-http`, and optional legacy `sse`.
- `diagnostics`: `%{severity: :error | :warning, code: atom, path: string,
  message: string}`. Component errors can appear in a successful package.
- `files`: the complete original relative-path-to-binary snapshot.

Manifest errors reject the package, except unknown top-level fields and non-object
`extensions`. Unimplemented extension values are not validated. Invalid individual
skills or MCP servers are skipped. Invalid `mcp.json` disables only MCP. Schemas
are bundled as references; loading selects locally implemented rules and never
downloads a schema. `transports: ["stdio", "streamable-http"]` restricts discovery
to supported transports, with diagnostics for skipped transports.

MCP values remain unexpanded. Runtime hosts must expand only `${PLUGIN_ROOT}` and
`${PLUGIN_DATA}`, once, in args/env values/cwd; provide both reserved variables;
recheck resolved command/cwd containment; enforce HTTP origin and header rules;
and handle connection failures per server. The loader validates reserved env
names, token commands, cwd containment, HTTPS/loopback URLs and HTTP headers.
Arguments and environment values remain opaque, including unknown placeholders.

## Snapshots and safety

`Archive.pack/2`, `unpack/2`, `digest/1`, and `read_directory/2` are shared by
publishers and installers. Archives use sorted deterministic USTAR in gzip,
fixed uid/gid/mtime, and regular files with **0644** default permissions.
`pack(files, modes: %{relative_path => 0o755})` preserves executable resources.
`unpack_with_metadata/2` and `read_directory_with_metadata/2` return
`{:ok, %{files: files, modes: modes}}`, preserving low permission bits only;
privileged setuid/setgid/sticky bits are never retained. File maps alone carry
bytes, so publishers and installers should use the metadata APIs. Paths that cannot fit
USTAR name/prefix fields fail packing. Unpacking accepts USTAR regular files and
directories, ignores empty directories, and rejects links, special files, PAX/GNU
extensions, duplicates, invalid checksums, absolute paths, traversal, Windows
separators/drive prefixes, file/directory conflicts and trailing nonzero data.
Decoding happens in memory and never extracts filesystem paths.

Defaults: 32 MiB compressed, 80 MB decompressed tar, 64 MiB total file bytes,
16 MiB per file, 10,000 files, 20,000 entries and 64 filesystem levels. Override
with `max_archive_bytes`, `max_uncompressed_bytes`, `max_total_bytes`,
`max_file_bytes`, `max_files`, `max_entries`, `max_depth`. Strict `Archive` directory
readers reject all links and special files. `PluginProtocol.load_directory/2`
instead resolves safe links within the filesystem-resolved plugin root, retaining
their target bytes under the original package-relative alias paths. An escaping
manifest rejects the plugin; an escaping fixed component location disables that
component, an escaping skill document skips that skill, and other escaping
resources are omitted with diagnostics. Link and directory cycles are denied.
The file-map and archive snapshot APIs remain unchanged. Callers must keep the
directory stable during reads; these APIs are not an OS sandbox against concurrent
hostile filesystem mutation.

## Distribution client

```elixir
client = Backplane.PluginProtocol.Client.new(
  base_url: "https://backplane.example",
  auth: access_token,
  transport: fn request -> MyHTTP.request(request) end
)
{:ok, catalog} = Backplane.PluginProtocol.Client.catalog(client)
{:ok, release} = Backplane.PluginProtocol.Client.resolve(client,
  plugin_id: plugin_id, channel: "stable")
{:ok, download} = Backplane.PluginProtocol.Client.download(client,
  release["artifact_digest"])
```

Transport accepts `%{method: method, url: string, headers: pairs, body: nil | binary}` and
returns `{:ok, %{status: integer, body: binary | map}} | {:error, reason}`. It must
enforce TLS, timeouts, response limits, cancellation and safe redirect policy.
`auth` also accepts a zero-arity header provider; `headers` supplies extra pairs.
Catalog and resolve return the decoded API object. Download checks the exact
SHA-256 before unpacking/loading, then returns `%{artifact, artifact_digest,
files, modes, package}`. HTTP failures return `{:error, {:http_status, status}}` without
exposing raw provider bodies. Endpoints are `/plugin-protocol/v1/catalog`,
`/resolve` (GET query: plugin_id/release_id/channel), and `/artifacts/:digest`.
This is Backplane's API, not an official Agent Plugins registry protocol.
`Client.request(client, method, path, body \\ nil)` makes a JSON request under
the same prefix for installation listing/reporting. `path` starts with `/` and
cannot contain traversal, a query or an alternate origin. A supplied body is
JSON-encoded with `content-type: application/json`; responses are decoded objects.

Specification references, checked 2026-10-23:

- https://agent-plugins.org/specification
- https://agent-plugins.org/plugin-authors/manifest
- https://agent-plugins.org/client-implementers/loading-and-discovery
- https://agent-plugins.org/client-implementers/mcp-runtime
- https://agentskills.io/specification
