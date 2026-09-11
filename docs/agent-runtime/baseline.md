# Shared Agent Runtime Baseline

## Local inventory (2026-09-10)

| Item | Evidence |
| --- | --- |
| Backplane branch / SHA | `main` / `bd5bc83005fded6f67beefe3fa8abac31eae506a` |
| Backplane worktree | Untracked `docs/agent-runtime/`; no tracked-file modifications at T00 entry |
| Elixir / OTP | 1.18.4 / 28 (ERTS 16.4.0.1) |
| CI toolchain pins | Elixir 1.18.4; OTP 28.5.0.5; Rust 1.95.0 |
| Umbrella packages | 17 existing `apps/*/mix.exs` projects |
| Proposed runtime packages | `apps/backplane_agent_runtime`, `apps/backplane_agent_tools` (new) |

## Consumer repositories

Sigma and Synapsis checkouts were not present under the searched local roots
(`/home/gao/Workspace`, `/data/development`) at the current baseline time.
Their SHAs remain unknown. Historical design references from
`gsmlg-opt/sigma@a7cbf4acf63f8ad1357c492e1eee49817f302cba` and
`gsmlg-opt/Synapsis@fe4ebf7d70d58ec46c1055f22e7c13cb455d8700` remain integration
seams, not current-state evidence.

This is a baseline gap for T00 consumer-path inventory and M4 adoption gates. It
does not block T01 scaffold work. Consumer inventories must be completed in their
repositories before claiming Sigma, Synapsis QueryLoop, or Synapsis graph
migration.

## Sibling contract availability

`backplane_ai_protocol` and `backplane_skill_protocol` are not present as
Backplane umbrella applications and no published version has been verified. The
runtime therefore declares no sibling production dependency and uses scripted
provider test ports for independent core work. Adding a provider/Skill boundary
requires first resolving their standalone release and API.

## T01 scaffold contract

- Runtime namespace: `Backplane.AgentRuntime`.
- Optional-tools namespace: `Backplane.AgentTools`.
- Production runtime has zero Mix dependencies.
- The tools package depends only on the runtime package.
- Runtime application starts no agents, tools, services, databases, Phoenix
  processes, or Backplane applications.
- Public identifiers are opaque serializable strings.
- The kernel accepts injected time and normalized external inputs.

## Clean-consumer fixtures

The fixture generator and verification script document package-only consumers
under `test/agent_runtime_packages/`. They are added alongside M0/T01 and remove
umbrella-relative build/config/deps assumptions. The tools package uses
`in_umbrella: true` during umbrella development; clean consumers use the
equivalent sibling-path dependency.

## T01 package artifact gap

`backplane_agent_runtime` builds a distributable Hex artifact. The tools package
now uses environment-specific dependencies: production declares
`backplane_agent_runtime ~> 0.1.0` for Hex packaging, while non-production
umbrella development uses `in_umbrella: true`. This resolves `mix hex.build` for
the tools package (checksum
`da91081afb1c73313dcf645bfb54832f5015b3a51bdc265fe1d734cc0d88df43`) while
keeping local tests buildable.

Clean-consumer artifact-backed tests still require publication or an explicitly
approved local Hex mirror/workspace dependency contract. Do not claim independent
Hex consumption until that dependency is resolvable outside the umbrella.

T01 is not complete until the runtime and tools packages have independently
resolvable artifact-backed dependency declarations, or until a coordinated
workspace-only build contract is approved and documented as an explicit
non-Hex packaging path. Do not claim both artifacts are independently usable
until this is resolved.
