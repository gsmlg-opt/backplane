# Acceptance Matrix

## Initial ledger

| Acceptance | Status | Evidence |
| --- | --- | --- |
| T03, T08, T27 | `in_progress` | Core cases are implemented in `apps/backplane_ai_protocol` and pass under `mix test apps/backplane_ai_protocol/test/backplane/ai_protocol_test.exs --seed 0`; W2 fixtures and broader evidence remain. |
| T06, T07, T28 | `in_progress` | W1.3 pure lifecycle and gate tests pass; real transport/resource evidence remains. |
| T21 | `in_progress` | W1.4 pure preflight tests pass; static/midstream integration evidence remains. |
| T09, T10 | `in_progress` | W1.5 wire contract, duplicate detection, credit model, and connection retirement implemented and tested; real WS evidence remains. |
| T01–T05, T11–T20, T24–T26 | `not_started` | Assigned work packages have not started. |
| T22 | `in_progress` | Independent lab consumer build/start passed; actual production artifact installation remains W5/W8. See `w1_1_report.md`. |
| T23 | `in_progress` | Protocol dependency tree is empty and release composition is unchanged; release/process inspection remains W5/W8. See `w1_1_report.md`. |

R01–R14 remain active until corresponding evidence exists.

## PR #32 remediation ledger (2026-09-11)

| Acceptance | Status | Evidence |
| --- | --- | --- |
| Gate A | `partial` | Core `51 passed`, TestKit `2 passed`, Protocol Lab and clean artifacts pass, but Dialyzer reports four warnings attributable to this diff and the actual Backplane release is environment-blocked. |
| Gate B | `passed for ordinary Responses native observation` | Real `/v1/responses` socket-backed fake upstream tests submit once; shared facts reach durable `llm_logs` for non-stream, SSE trailing usage, errors, and malformed observations. |
| BP01-BP04 | `passed` | Public route/auth/model rewrite and one submission; preserved bodies; split/coalesced SSE; trailing usage and one protocol terminal. |
| BP05-BP08 | `passed for selected fixtures` | Parallel canonical tool identities and incomplete arguments; refusal/output-limit distinctions; HTTP/protocol errors; malformed/oversized observation remains incomplete without rewriting native output. |
| BP09 | `passed at shared Relayixir transport seam` | Relayixir downstream-disconnect test proves upstream stream closure/no replay; Codex regression proves host cleanup. No live provider was called. |
| BP10-BP12 | `passed for selected observer` | Unknown versus observed usage, cache/reasoning fields, bounded synchronous observation, shared implementation label and package-derived durable values. |
| BP13 | `passed for deterministic scope` | Legacy parser, ordinary proxy, Codex/compact, disconnect and workflow contract regressions pass; live Codex/provider evidence remains not run. |
| BP14 | `partial` | Normal routing and clean consumer release composition pass; actual Backplane release build is blocked by the local macOS SDK/bcrypt linker failure. |
| T01-T28 full V1 | `not complete` | Three bidirectional codecs, translated routes, OAuth/catalog migration, complete WS service, Sigma/Synapsis adoption, and live compatibility remain future work. |

Exact commands, counts, hashes, limitations, and rollback are in
`docs/ai-protocol/evidence/pr32_remediation_report.md`.
