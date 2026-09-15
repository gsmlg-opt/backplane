# W1 Contract Review and Backend Spike

## Backend selection

| Item | Decision |
| --- | --- |
| WebSocket backend | `websock` / `websock_adapter` (via Bandit) |
| Version | `websock ~> 0.5`, `websock_adapter ~> 0.5` |
| Client transport | Same WebSocket standard; the package defines envelope semantics only |
| Phoenix Channels | Not used for the AI protocol; V1 is a custom JSON envelope over WebSocket |

The umbrella already runs Phoenix 1.8 with Bandit 1.12 and `websock_adapter` 0.6. The
`websock` behaviour provides the upgrade path without coupling to Phoenix Channels. The
protocol package itself remains dependency-free and only specifies envelope shapes and
state transitions; the runtime WS adapter is host-owned (W4).

## Isolated local probe status

The W1.5 wire contract module (`Backplane.AiProtocol.Wire`) implements the pure envelope and
state rules. Runtime probes (TLS/proxy configuration, connection ownership, bounded overflow,
cancellation) are deferred to W4.1 wire implementation and W4.2/3 real endpoint evidence.

The frozen W1.5 ordering rules are recorded in `wire_contract.md`. The initial backend choice
must be revalidated under load before production use; this selection is not a capacity claim.

## Extension and version policy

| Concern | Rule |
| --- | --- |
| Wire major mismatch | Reject with `:incompatible` |
| Wire minor mismatch | Reject with `:incompatible`; no partial backward compat |
| Unknown extensions | Carried in `extensions` list; never override core/auth fields |
| JSON key casing | Lowercase snake_case; frozen by `wire_contract.md` |
| Envelope ordering | Field order is not semantically meaningful; JSON object iteration order is unspecified |
| TestKit Protocol range | Independently declared; not tied to Backplane release version |

## Contract review findings

1. `Backplane.AiProtocol.ExecutionContext.new/1` correctly rejects all map construction; the
   only path to an ExecutionContext is host-internal construction outside the protocol package.
   This matches design section 5.1.
2. `Backplane.AiProtocol.Translation.plan/4` enforces strict defaults and named downgrades.
   The `provider_state` cross-origin check uses `source_protocol` matching; full affinity
   validation (endpoint/account/model) is deferred to codec-level W2 rules where the actual
   wire targets are known.
3. `Backplane.AiProtocol.Wire` bounded seen-ID capacity is 32. At capacity, the connection
   retires gracefully rather than evicting IDs. This matches design section 9.4.
4. The pure lifecycle gate correctly permits `:incomplete` terminal status without a
   stop-reason. This matches design section 8.2's distinction between content completion and
   protocol termination.
5. `Serialization.to_json/1` correctly normalizes atom keys to string keys for JSON output.
   It also normalizes atom values to strings, which is intentional for the portable JSON
   surface; canonical atom semantics are preserved in the struct layer.

## Unresolved choices

1. Exact WS upgrade headers (e.g. `Sec-WebSocket-Protocol` value and auth mechanism) are
   W4.1 implementation targets, not frozen here.
2. Catalog pagination defaults are W3 targets.
3. Live provider/Codex evidence remains blocked on credentials and is not claimed here.
