# Backplane Skill Protocol

Host-independent parsing, discovery, resolution, eligibility, complete
`tar+gzip` bundle preparation, and a versioned Backplane read client for Agent
Skills.

The library performs no Skill execution, directory scanning, network access, or
database access at application startup. Hosts supply source roots, policies,
destinations, and budgets explicitly.

## Remote sources and cache ownership

`Backplane.SkillProtocol.Client` requires an HTTP origin, source ID, non-secret
access-context ID, and credential supplier. It requests only the frozen
`/skill-protocol/v1/catalog`, `/resolve`, and `/artifact` routes. All attempts
share one deadline, responses are byte-bounded, and redirects are refused.

`Backplane.SkillProtocol.Source.Backplane` combines the client with an explicit
`Backplane.SkillProtocol.Cache`. A cache root is private to the supplied owner
ID and the OS process that claims it. Handles in that process coordinate
mutations, while another live OS process is rejected even when it supplies the
same owner ID. A crashed process claim is recovered by the next consumer, which
must supply the same owner ID to inspect persisted verification and denial
state.

Offline reuse is disabled unless the source is configured with
`{:age_bounded, max_age_ms}`. It applies only to an exact revision previously
verified for the same source and access context. Known denial, withdrawal, or
integrity failure blocks offline reuse until an online fetch and verification
succeeds. Revocations that occur while disconnected cannot be discovered until
the next online request.

Cache cleanup removes only operation staging. Verified artifact and prepared
paths are retained without automatic eviction, so active prepared views remain
valid. Capacity exhaustion is returned explicitly rather than evicting data.
