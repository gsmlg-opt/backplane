# Skill Protocol v1 Consumer Handoff

Status: consumer-ready package and Backplane server; external product adoption is deferred.

## Supported Surface

Backplane exposes the frozen read-only protocol at `/skill-protocol/v1`:

- `GET /skill-protocol/v1/catalog` lists committed descriptors with bounded pagination.
- `GET /skill-protocol/v1/resolve?skill_id=...&revision=...` resolves a manifest. Omitting `revision` snapshots current once; consumers should retain the returned exact reference.
- `GET /skill-protocol/v1/artifact?skill_id=...&revision=...` returns exact `application/x-tar+gzip` bytes for an explicit revision.

The package is the OTP application `:backplane_skill_protocol`, with public modules under `Backplane.SkillProtocol`. The main consumer APIs are:

- `Parser.parse/2` and `Validator.validate/2` for Skill documents.
- `Bundle.inspect/2`, `Bundle.prepare/3`, and `Bundle.pack/3` for complete bundles.
- `Resource.read/3` for verified prepared resources.
- `Client.new/1`, `catalog/2`, `resolve/4`, and `artifact/2` for the wire API.
- `Source.Backplane.new/1`, `catalog/2`, `resolve/4`, and `prepare/4` for the normal remote-source flow.

All fallible APIs return `{:ok, value}` or `{:error, %Backplane.SkillProtocol.Error{}}`. The package reads Skill and resource bytes; it never executes scripts or grants tools.

## Dependency Options

Use one dependency mechanism appropriate to the delivery stage:

```elixir
# Published Hex release, after publication
{:backplane_skill_protocol, "~> 0.1.0"}

# Pinned Git monorepo subdirectory
{:backplane_skill_protocol,
 git: "https://github.com/gsmlg-opt/backplane.git",
 sparse: "apps/backplane_skill_protocol",
 ref: "<reviewed-commit-sha>"}

# Local development only
{:backplane_skill_protocol, path: "../backplane/apps/backplane_skill_protocol"}
```

Pin Git dependencies to a reviewed commit. Do not use a moving branch for production. The current BP-06 artifact was built but not published to Hex.

The package targets Elixir `~> 1.18` and has only `req`, `telemetry`, and `yaml_elixir` runtime dependencies. It does not depend on Ecto, Postgrex, Phoenix, Backplane sibling apps, or umbrella configuration.

## Source And Credentials

Each Backplane instance needs a stable, consumer-chosen `source_id`. A Skill reference is qualified by that source ID; two sources with the same display name or Skill ID are not interchangeable.

Each client also needs a stable, non-secret `access_context_id` representing its authorization context. Do not put a bearer token, API key, session cookie, or other secret in this ID.

Supply credentials through a zero-arity function so requests obtain current credentials instead of persisting them in the client:

```elixir
client =
  Backplane.SkillProtocol.Client.new!(
    endpoint: "https://backplane.example",
    source_id: "backplane-production",
    access_context_id: "agent-runtime-read-scope-v1",
    credential_supplier: fn -> System.fetch_env!("BACKPLANE_SKILL_TOKEN") end
  )
```

The supplier may return a bearer-token string, `nil` for an open endpoint, or `{:error, reason}`. Credentials are not forwarded across redirects because redirects are refused.

## One-Shot Preparation And Destination Ownership

Create the source from the client, then supply a fresh path under the host's task or work directory for each use. The destination parent must already exist.

```elixir
source = Backplane.SkillProtocol.Source.Backplane.new!(client)

{:ok, prepared} =
  Backplane.SkillProtocol.Source.Backplane.prepare(source, skill_id, revision,
    destination: Path.join(task_root, "prepared-skill")
  )
```

Each call resolves once and downloads the exact returned artifact, even if the same revision was used before. Remote denial, outage, cancellation, or integrity failure returns an error and never reuses earlier content. Existing destinations are rejected and left unchanged. The caller owns the lifetime and cleanup of every successful prepared root; the package does not scan or manage them.

Backplane's server-side immutable publication rows and retained artifacts remain part of the v1 service. They are distinct from the removed consumer-side durable cache.

## Frozen Compatibility Values

- Wire version: `1`.
- Bundle profile: `backplane.skill-bundle.v1`.
- Artifact format: exact deterministic `tar+gzip` bytes.
- Digest: `sha256:` followed by lowercase SHA-256 of the exact gzip artifact.
- Revision: opaque exact revision; Backplane currently publishes `r-` plus a lowercase SHA-256 value.

Do not derive authorization from a digest, display name, author version, or package SemVer. Fetches remain qualified by source instance, opaque Skill ID, and exact revision.

## Deferred Adoption

BP-06 does not modify or validate Sigma, Synapsis, Samgita, or host-agent consumers. Their adoption must separately choose source IDs, access-context IDs, credential supply, caller-owned destination lifecycle, and a pinned package dependency, then run their own end-to-end tests against Backplane.
