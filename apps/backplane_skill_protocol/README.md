# Backplane Skill Protocol

Host-independent parsing, discovery, resolution, eligibility, complete
`tar+gzip` bundle preparation, and a versioned Backplane client for Agent
Skills.

The library starts no directory or network work when its OTP application
starts. Hosts can use the one-shot APIs or explicitly supervise a shared
directory. The library supplies no Skill execution or tool authority.

## Supervised directory for Sigma

Add the directory to the application supervision tree and register each
repository using its effective working directory. Reuse the same configured
global sources across registrations.

```elixir
alias Backplane.SkillProtocol.Directory

# In Sigma's application children
children = [{Directory, name: Sigma.SkillDirectory}]
{:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

# In the host's configuration owner, also run this after a directory restart.
workdir = Path.expand("~/work/example")
scope = workdir

global =
  {"global", {:local, Path.expand("~/.agents/skills"), profile: :standard, missing: :empty}}

repository =
  {"repository:" <> workdir,
   {:local, Path.join(workdir, ".agents/skills"), profile: :standard, missing: :empty}, 0}

:ok =
  Directory.register_scope(Sigma.SkillDirectory, scope,
    sources: [global, repository],
    disabled: ["retired-skill"]
  )
```

Set `:disabled` to the effective list of disabled names and
`{source_id, skill_id}` pairs. A name disables every match in this scope. Use
qualified pairs for a policy that applies only to the global or repository
source. Omit a disabled source from the registration. The default precedence
is 100. Lower values take priority when `Resolver.resolve/2` selects by name.
Both views retain eligible source-qualified entries, so callers can still
select explicitly from either source when names overlap. Use a stable
repository-specific source ID for each repository root.

Read once per session operation and pass that snapshot to both UI and Agent.
An active view can subscribe and get the current snapshot in the same call.

```elixir
# For a one-shot session open or resume
{:ok, snapshot} = Directory.snapshot(Sigma.SkillDirectory, scope)
{snapshot.revision, snapshot.automatic, snapshot.explicit}

# In an active view process, including after reconnect
{:ok, initial} = Directory.subscribe(Sigma.SkillDirectory, scope)

# In a LiveView, handle each update in handle_info/2. This wait is for a
# process making the first Agent request while the directory is warming.
await_snapshot = fn
  await, %{status: :warming, revision: seen} ->
    receive do
      {:skill_directory_updated, _directory_pid, ^scope, revision} when revision > seen ->
        with {:ok, current} <- Directory.snapshot(Sigma.SkillDirectory, scope) do
          await.(await, current)
        end
    after
      5_000 -> {:error, :warming_timeout}
    end

  _await, current ->
    {:ok, current}
end

await_snapshot.(await_snapshot, initial)
```

`:warming` means at least one source is still starting. Keep the first Agent
request pending until a snapshot is available, or surface a source error.
`:ready` with empty views is a successful empty directory. `:degraded` exposes
source failures in `snapshot.sources`. A transient failure after success
retains that source's last view with `:stale` status. A blocking failure such
as remote authorization denial exposes `:error` and withdraws its entries.
Use the previously selected snapshot for a turn already in progress. Use a
fresh snapshot for the next turn. Treat directory revisions as opaque,
increasing integers within the running VM. Remote skill revisions remain
opaque references to individual publications.

Local sources accept `:profile` (`:legacy` by default or `:standard`),
`:supported_capabilities`, `:max_depth`, `:max_entries`, and
`:max_diagnostics`. `missing: :empty` is useful for optional skills roots.
Existing roots that cannot be read surface a source failure. Local descriptors
carry the invocation flags, argument hint, path, and `document_digest` for the
indexed `SKILL.md`. The host can compare this digest with the selected bytes
before starting a turn.

Local sources update in response to file events. The directory coalesces
events for 35 ms by default (`:debounce_ms`). An idle local source schedules
no scans or reads. On Linux, native events require `inotifywait` from
`inotify-tools`. Use `watch: false` for manual updates or call
`Directory.force_reload/2,3` to recover from a missed event. A force reload
reads the local documents again, reuses parsing for unchanged content, and
reconnects the file watches.

### Remote discovery and exact selection

To include a Backplane server, also register
`{client.source_id, Source.Backplane.new!(client)}` (alias
`Backplane.SkillProtocol.Source.Backplane` as `BackplaneSource` if preferred).
Reuse a configured client for scopes with the same endpoint and access
context. When changing visibility or credentials to a different authorization
context, register a client with a different `access_context_id`.

Register the source when saving or loading the agent configuration. Each shared
remote source opens one authenticated WebSocket at `/skill-protocol/v1/events`
and receives one bounded Always return snapshot, including catalogs larger
than the HTTP page size. It publishes the list immediately, then prefetches
the verified exact archives in the background. Session reads use the
in-memory view. Committed skill changes send skill IDs and a generation.
The client reloads the affected descriptors through the API and prefetches
only those still in Always return. A reconnect sends the last generation and
can replay recent changes without reloading the whole catalog.

Use `Directory.force_reload(Sigma.SkillDirectory, scope, client.source_id)`
to reconnect explicitly. The two-argument form reloads all sources in the
scope. Existing servers that expose only HTTP v1 can be registered under a
directory started with `remote_events: false`. That mode loads the bounded
paginated view at registration and on explicit reload.

`Source.Backplane.search/2` performs on-demand search. Skills outside
Always return are never prefetched. Apply the host's scope and invocation
policies to search results and load an exact reference upon selection.

Backplane **Skills → Config** publishes optional search category hints, such
as Android debugging or iOS debugging. Pass the current hints to the Agent
Runtime context when building the Codex tool profile:

```elixir
{:ok, snapshot} = Directory.snapshot(Sigma.SkillDirectory, scope)

categories =
  snapshot.sources
  |> Enum.sort_by(fn {source_id, _} -> source_id end)
  |> Enum.flat_map(fn {_source_id, source} -> source.search_categories end)
  |> Enum.uniq()

context = Map.put(context, :skill_search_categories, categories)
```

The hints describe categories in `skills::search`. Search access and
matching continue to use the existing protocol.

When a user selects an entry, use its exact reference. For a directory with
notifications enabled:

```elixir
{:ok, %{content: markdown, document: document, manifest: manifest}} =
  Directory.read_remote(Sigma.SkillDirectory, scope, selected.ref)

{:ok, %{content: guide}} =
  Directory.read_remote(Sigma.SkillDirectory, scope, selected.ref, "references/guide.md")
```

Prefetch and on-demand reads share any in-flight download for an exact
reference. The cache is in memory and defaults to 64 MiB per shared source.
Set `:remote_cache_bytes` on the directory for a larger Always return set.
The source field `notifications` distinguishes `:connecting`, `:online`,
`:offline`, `:denied`, and `:error`.

When notifications disconnect, the directory's eligible views include only
verified cached skills. Reading those returns `availability: :offline`.
Cache misses return a source error without making an HTTP request. An
authorized reconnect applies missed changes or resumes the same generation.
An explicit denial, credential change, or full reset invalidates the prior
cache. While offline the client learns about server-side revocations after
reconnection. Retain already-returned content to keep a turn pinned.

Use the one-shot API for an independent host-owned prepared directory:

```elixir
alias Backplane.SkillProtocol.Source.Backplane, as: BackplaneSource

source = BackplaneSource.new!(client)

{:ok, prepared} =
  BackplaneSource.prepare_ref(source, selected.ref,
    destination: Path.join(task_root, "prepared-skill")
  )
```

V1 remote descriptors carry `disable_model_invocation`, but omit the
document's `user-invocable` field. An explicit remote discovery entry is a
candidate. Check invocation eligibility against the resolved document before
using it. Host-managed offline copies and authorization policies apply at
selection time.

The public directory API is `start_link/1` (or the generated `child_spec/1`),
`register_scope/3`, `unregister_scope/2`, `snapshot/2`, `subscribe/2`,
`unsubscribe/2`, `force_reload/2,3`, and `read_remote/3,4`. Exiting consumers are automatically
unsubscribed. Removing a scope sends a final update and removes its
subscriptions. Monitor the directory process from the host that owns scope
configuration. After a restart, re-register from current configuration, then
re-subscribe active views to the new process. Until registration,
`snapshot/2` and `subscribe/2` return `{:error, :unknown_scope}`.

### Sigma acceptance

- Open, resume, and reconnect the same session. Confirm the command menu and
  Agent use one revision per open, with zero directory traversals, document
  reads and parses, and remote catalog requests on the session path after
  warmup. Time page connection, snapshot access, and Agent readiness separately.
- With two repositories open, edit, add, rename, and delete a skill. Check
  menu updates and the next Agent turn, and confirm repository overrides,
  disabled names, and manual-only entries. A turn already in progress should
  retain its selected skills.
- Restart the directory and verify configuration replay and page
  re-subscription. Exercise warming, valid empty, and transiently degraded
  states in the session flow.
- Through a normal Agent session, check remote Always return injection,
  on-demand search, and selection of a published skill and its resources at
  the exact revision and digest.

## Remote sources and one-shot preparation

`Backplane.SkillProtocol.Client` requires an HTTP origin, source ID, non-secret
access-context ID, and credential supplier. For startup discovery use `Source.Backplane.catalog(source, view: :always)`.
Search with `Source.Backplane.search(source, q: "task keywords")`; both operations
return lightweight descriptors and an optional next cursor. They require explicit
response confirmation from a compatible server. An ordinary catalog request
continues to return the full legacy inventory. Resolve and prepare only the
selected source-qualified revision. All attempts
share one deadline, responses are byte-bounded, and redirects are refused.

`Backplane.SkillProtocol.Source.Backplane` performs one verified download for
each call. The caller supplies a fresh destination whose parent directory
already exists:

```elixir
source = Backplane.SkillProtocol.Source.Backplane.new!(client)

{:ok, prepared} =
  Backplane.SkillProtocol.Source.Backplane.prepare(source, skill_id, revision,
    destination: Path.join(task_root, "prepared-skill")
  )
```

Preparation resolves once, downloads that exact artifact, verifies it, and
atomically publishes the complete files. Missing, invalid, or existing
destinations fail without a network request. A later call downloads again,
even for the same revision; remote failures never fall back to earlier files.
The returned directory remains available until the host removes it. The
library does not manage, scan, migrate, or clean caller-owned destinations.

## Creating a skill

Use a client with the `skill::write` scope to publish a single Markdown document.
Backplane supplies the frontmatter and returns a manifest with the exact skill
ID, revision and digest. The slug must be unique across the library.

```elixir
{:ok, manifest} =
  Backplane.SkillProtocol.Client.create(client, %{
    "slug" => "release-checklist",
    "name" => "Release checklist",
    "description" => "Checks before publishing a release",
    "content" => "Run the release tests and verify the artifacts."
  })
```

New skills are searchable with `skill::read`. An operator can select them for
startup in **Skills → Config**. A duplicate slug returns `:already_exists`.
The client sends a create request once. If its outcome is unknown, inspect
the library before trying again.
