# Backplane Skill Protocol

Host-independent parsing, discovery, resolution, eligibility, complete
`tar+gzip` bundle preparation, and a versioned Backplane read client for Agent
Skills.

The library performs no Skill execution, directory scanning, network access, or
database access at application startup. Hosts supply source roots, policies,
destinations, and budgets explicitly.

## Remote sources and one-shot preparation

`Backplane.SkillProtocol.Client` requires an HTTP origin, source ID, non-secret
access-context ID, and credential supplier. It requests only the frozen
`/skill-protocol/v1/catalog`, `/resolve`, and `/artifact` routes. All attempts
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
