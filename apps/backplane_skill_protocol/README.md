# Backplane Skill Protocol

Host-independent parsing, discovery, resolution, eligibility, complete
`tar+gzip` bundle preparation, and a versioned Backplane client for Agent
Skills.

The library performs no Skill execution, directory scanning, network access, or
database access at application startup. Hosts supply source roots, policies,
destinations, and budgets explicitly.

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
