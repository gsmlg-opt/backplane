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

## Current-source review ledger (2026-09-14)

This ledger supersedes the 2026-09-11 remediation ledger for current status. Historical results
above remain useful only for their tested source states.

| Acceptance | Current status | Evidence |
| --- | --- | --- |
| Gate A functional scope | `passed locally` | Current recursive budgets/serialization, constructor composition, carrier affinity, strict preflight/host policy, lifecycle, wire contract, packaged-consumer installation, host release, and tracked Protocol Lab tests pass after regression-first repairs. |
| Gate A R09 delivery evidence | `not verified on repaired source` | Local strict compile/format/Credo and scoped suites pass. Dialyzer emits only the exact base-branch `backplane_memory` warning set. The available completed GitHub checks are for unrepaired PR head `635ad1c...`; matching CI for the repair commits has not completed. |
| Gate B | `passed locally for ordinary non-Codex Responses native observation` | A real listening `Backplane.Api.Endpoint` submits once to a deterministic fake upstream; host auth/model/credential binding and Relayixir remain intact; shared observation drives durable usage/error/log consumers. |
| BP01-BP05 | `passed` | Real endpoint/auth/model rewrite/one submission; native non-stream response; fragmented SSE and trailing usage; correlation and incomplete parallel tool observations. |
| BP06-BP10 | `passed after regression repairs` | Refusal/output-limit/error/truncation semantics, downstream-disconnect cancellation, bounded incomplete observations, one submission, one durable write, and explicit unknown usage. |
| BP11-BP14 | `passed for declared deterministic scope` | Bounded synchronous observation, durable shared identity, preserved non-target native behavior, actual Backplane release, and fresh external consumer release composition. Live providers were not called. |
| T01-T28 full V1 | `not complete and not claimed` | Chat/Anthropic/Codex migration, translation, OAuth/catalog, production WebSocket, other-host adoption, and live compatibility remain outside the declared path. |
| Merge review | `incomplete` | Current repaired source has no completed matching remote CI result, and the pre-delivery PR-head checks are red. Do not approve merge from this ledger. |

Exact current commands, counts, artifact hashes, defect dispositions, and limitations are in the
`Current-source review follow-up (2026-09-14)` section of
`docs/ai-protocol/evidence/pr32_remediation_report.md`.

## Endpoint regression coverage ledger (2026-09-15)

This section supersedes the delivery status immediately above. It is bound to remote head
`70b9609dab87eb5beea59d90a521ab1541d94839`, base
`bd5bc83005fded6f67beefe3fa8abac31eae506a`, and the local uncommitted regression/evidence changes.

| Acceptance | Current status | Evidence |
| --- | --- | --- |
| Current committed production repairs | `covered by remote CI` | Runs `34795930919` and `34795930657` test the tree-identical merge commit `f9eff712...`; push run `34795927803` tests exact head `70b9609d...`. The earlier no-matching-CI statement is superseded. |
| Fragmented chunked semantic JSON | `passed locally; not yet remote` | The real endpoint test pauses after two incomplete JSON chunks, observes no premature durable facts, then verifies byte-exact forwarding, exact `bytes_seen`, one submission, one row, and complete usage/terminal facts after the final chunk. |
| Chunked observation above 8 MiB | `passed locally; not yet remote` | The real endpoint forwards the entire native body while bounded observation becomes incomplete, usage/response identity remain unknown, and `response_bytes_exceeded` is recorded. |
| Endpoint suite | `passed locally` | 10 tests, zero failures at seeds 0, 424242, and 987654. |
| Normal `backplane_api` test command | `passed locally` | 244 tests, zero failures at seed 0; both new cases are discovered by the normal application command. |
| PR-scope functional checks | `passed locally` | Protocol 62/62, TestKit 2/2, Llama 251/251, Relayixir 247/247, workflow contract 4/4, strict compile, format, Credo, Protocol Lab, external consumer and host release. |
| Repository-wide CI | `red; base-equivalent failures` | Dialyzer and seven application jobs remain red with matching base failures. They are outside this PR's scoped implementation and are not represented as green or waived. |
| Migration boundary | `ordinary non-Codex Responses native observation only` | Native forwarding and host routing/credential ownership remain unchanged; full translation/proxy migration is not claimed. |
| Merge review | `incomplete` | The two new endpoint regressions and evidence are still local-only, and repository-wide required CI remains red. |

Exact run/job IDs and failure boundaries are recorded in the `Endpoint regression coverage update
(2026-09-15)` section of `docs/ai-protocol/evidence/pr32_remediation_report.md`.

## Duplicate endpoint cleanup ledger (2026-09-15)

This section supersedes the endpoint regression delivery status above. Source commit
`b35037cfe5cfb7cdfa6121121649c1cd5fde7bdb` removes the accidentally merged duplicate routes,
fixtures, tests, and decoder clauses without changing production code.

| Acceptance | Current status | Evidence |
| --- | --- | --- |
| Fragmented chunked semantic JSON | `committed and passed locally` | One synchronized `chunked-json` route/test verifies no premature durable facts, byte-exact forwarding, one submission, one row, exact usage/identity/bytes, and complete terminal observation. |
| Chunked observation above 8 MiB | `committed and passed locally` | One `chunked-overflow` route/test verifies byte-exact forwarding, one submission, one row, nil usage/identity, incomplete observation, exact bytes, and `response_bytes_exceeded`. |
| Endpoint suite | `passed locally` | Exactly 10 tests; zero failures at seeds 0, 424242, and 987654. |
| Normal `backplane_api` command | `passed locally` | 244 tests, zero failures. |
| Production behavior | `unchanged` | Only the endpoint regression test and evidence changed; Relayixir and AI protocol production modules were not modified. |
| Repository-wide checks | `partial` | Protocol 62/62, TestKit 2/2, Llama 251/251, Relayixir 247/247, format, Credo, and diff check pass. Strict compile remains blocked by existing `backplane_mcp_protocol` warnings. |
| Cleanup-source CI | `target job passed` | At SHA `646531923b7d873026724eb7c72da7814fbf905f`, Test run `34921657683` job `104230898550` passed `Test (backplane_api)`. Protocol, TestKit, Llama, Relayixir, compile, format, Credo, and workflow contract also passed. Dialyzer and the seven established base-equivalent application jobs remain red. |

## Current checker repair delivery (2026-09-15)

This section supersedes the preceding current-source status. `origin/main` was merged into the PR
branch and five conflicts were resolved while preserving the shared ordinary Responses path and
existing Relayixir/host ownership boundaries. Repair commit `cb742426`, merge commit `07e20f50`,
test isolation commit `bb1f86ef`, and MCP fixture-load commit `1a84d9cc` are included in tested
remote source `1a84d9cc70071785e7a2953140eef3b20e4c4678`; base is
`1d3901183848d94fd2c731e97fb66069bb93d1a0`.

| Acceptance | Current status | Evidence |
| --- | --- | --- |
| PR checker repair | `passed` | Test run `34936404796` passed all 18 jobs at tested source `1a84d9cc`, including `backplane_api` and the repaired `backplane_mcp_protocol` job. PR CI `34936404664` and push CI `34936401283` passed Compile, Format, Credo, Workflow Contract, and Dialyzer. PR Skill Protocol run `34936404706` passed. |
| Application suites | `passed locally` | Backplane 22, admin 275, MCP 663, memory 1,143 plus 5 excluded, skills 191, system 408, telemetry 33, AI protocol 62, TestKit 2, API 255, Llama 251, and Relayixir 247 tests passed. |
| Endpoint regressions | `passed locally` | The endpoint suite has 10 tests and passed at seeds 0, 424242, and 987654, including fragmented semantic JSON and the >8 MiB observation overflow case. |
| Repository checks | `passed locally` | Format check, Credo strict, workflow contract, and `git diff --check` passed. Local Dialyzer under Elixir 1.20/OTP 29 exits 2 on three known guard warnings in `web_live_search.ex:511`, `web_search.ex:320`, and `web_x_search.ex:227`; target CI Elixir 1.18/OTP 28 Dialyzer passed. |
| Production scope | `preserved` | No AI protocol or Relayixir production behavior changed by the checker repair; the main merge retained the existing ordinary Responses integration. |
