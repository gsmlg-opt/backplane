# W1 Foundation Report

## Scope

Implemented W1.1, W1.2, W1.3, W1.4, and the W1.5 wire contract. Codecs, transport, auth, catalogs, WebSocket client/server, and full artifact installation are intentionally not implemented.

## Changed paths

- `.github/workflows/test.yml`
- `apps/backplane_ai_protocol/`
- `apps/backplane_ai_protocol_testkit/`
- `examples/protocol_lab/`
- `docs/ai-protocol/evidence/`

No release composition was changed; `releases/0` still explicitly lists only `backplane` and `host_agent`.

## Package boundaries

- `backplane_ai_protocol` has no runtime dependencies and does not start a network service, database, Backplane service, or fixed global process.
- `backplane_ai_protocol_testkit` depends on `backplane_ai_protocol`; the reverse dependency is absent.
- `examples/protocol_lab` is an independent Mix project and is not an umbrella child. It has no root umbrella build/config paths and depends only on the production package.
- TestKit protocol dependency is compiled from the umbrella child, while the lab validates the sibling production source without umbrella config.

## Verification at Backplane SHA `bd5bc83005fded6f67beefe3fa8abac31eae506a`

| Command | Result | Exit code |
| --- | --- | --- |
| `mix do --app backplane_ai_protocol cmd mix compile --warnings-as-errors` | passed | 0 |
| `mix do --app backplane_ai_protocol cmd mix test` | `14 tests, 0 failures` | 0 |
| `mix test apps/backplane_ai_protocol/test/backplane/ai_protocol_test.exs --seed 0` | `39 tests, 0 failures` | 0 |
| `mix do --app backplane_ai_protocol_testkit cmd mix compile --warnings-as-errors` | passed | 0 |
| `mix do --app backplane_ai_protocol_testkit cmd mix test` | `1 test, 0 failures` | 0 |
| `mix format --check-formatted` | passed | 0 |
| `cd examples/protocol_lab && mix deps.get && mix compile --warnings-as-errors && mix escript.build && ./protocol_lab` | build and execution passed | 0 |
| `mix compile --warnings-as-errors` | failed only on the pre-existing `backplane_memory` warning at `verification.ex:629` | 1 |

`mix.lock` SHA-256 remains `773ba7d426e45e62dfe098956f0afc41f16bf3bdf86b0a37f1b89f88a9c9416a`.

## CI scope

The test workflow matrix gained only `backplane_ai_protocol` and `backplane_ai_protocol_testkit`. No release, Docker, database, or route configuration changed.

## Unresolved decisions

1. Synapsis has no visible root license; extraction/copy decisions remain blocked pending terms.
2. Canonical contract semantics are deferred to W1.2.
3. Artifact installation into fresh consumers remains T22/T23 work for W5/W8.

## Readiness

The W1.2-W1.4 contracts and W1.5 initial wire state machine are executable. W1.5 needs fixture/schema documentation and W1.6 needs contract review/backend spike before the G0 exit gate. No production route change was made.
