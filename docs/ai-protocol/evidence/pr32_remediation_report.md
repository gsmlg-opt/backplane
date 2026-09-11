# PR #32 Remediation and Backplane First-Consumer Report

## Scope and source identity

- Repository: `gsmlg-opt/backplane`, branch `feature/ai-protocol`.
- Tested base HEAD: `a5aabac364530377420c3ce6fb6339f64a3deb74`; historical reviewed commit:
  `9bfa152da0971e029173876134cc3761eef3f298`.
- Root lock SHA-256: `773ba7d426e45e62dfe098956f0afc41f16bf3bdf86b0a37f1b89f88a9c9416a`.
- Toolchain: Elixir/Mix 1.20.1, Erlang/OTP 29 (erts 17.0.2), Git 2.55.0, macOS
  Darwin 27 arm64. CI remains pinned to Elixir 1.18.4 / OTP 28.5.0.5.
- Tracked patch SHA-256 excluding this self-referential report:
  `a8fd40bc662ac92a6ac66f18fdfe652486250cae9bbc36c6a653092a0450e391`.
- New source hashes: observer `c771b54ab5bb89de74d5021022a8468cd4196cacaca570426bdea8de712902dd`,
  SSE `dd78dbd4143e0be364ee6afc2ad71474831a0bbde02e8a471a2cf2cd8dec541a`,
  remediation tests `73d15a15e0a627fb51daa7e5fe14d08f77eb5aab9f2a6ecd0bc0750554523cb8`.
- At the original remediation snapshot, the checkout was intentionally uncommitted. The supplied
  handoff and unrelated changes were preserved; the later PR delivery commits are recorded below.
  No publish, deploy, live provider call, or credential import occurred.

## Finding dispositions

| Finding | Disposition | Evidence |
| --- | --- | --- |
| R01 | Fixed | Recursive cumulative byte/node/depth/collection checks and unsupported-term tests. |
| R02 | Fixed | Struct-first recursive isolation, approved projections, collision/encoder errors, byte-exact provider-state path. |
| R03 | Fixed | All provider-state carriers and profile/protocol/endpoint/account/workspace/model affinity checked with positive preservation. |
| R04 | Fixed for declared preflight subset | Roles, tools/results, settings, output constraints, extensions and state are enumerated; unknown is not support; executable, revisioned host rules are required. No translated production route is claimed. |
| R05 | Fixed | Jason is a production dependency; final core/TestKit Hex payloads resolve outside the umbrella; test-only package is absent from production release. |
| R06 | Fixed | Finished execution handles cannot be claimed; lifecycle/ownership tests retain one terminal. |
| R07 | Fixed | The tracked lab module contains the real CLI; `/protocol_lab` ignore is anchored; clean build output runs package APIs and independent raw fixtures; accidental BEAM artifact is removed. |
| R08 | Fixed at pure contract layer | Handshake/admission, bounded IDs, negotiated limits, encoded-envelope credit, sequencing, correlation, terminal cleanup and draining are enforced. A complete WS server remains out of scope. |
| R09 | Fixed for the PR diff | Package matrix ordering/TestKit execution and Credo pass. The four earlier diff-attributable warnings were removed; final CI reports only the same `backplane_memory` Dialyzer warnings as `main`. Local Elixir 1.20 warnings-as-errors remains blocked by existing MCP protocol warnings. |
| R10 | Fixed for ordinary non-Codex Responses | The normal Backplane route uses shared JSON/SSE observation and consumes package facts in durable logs. |

## Actual integration call graph

`Backplane.Api.Endpoint` -> `Backplane.LLM.ProxyPlug` -> `Backplane.LLM.Router`
`POST /v1/responses` -> host authorization/model resolution/credential replacement -> Relayixir
`HttpPlug` -> deterministic upstream once -> unchanged native downstream bytes.

For ordinary providers only, Relayixir's existing `on_response_chunk` callback feeds
`Backplane.LLM.AccessEvent.scan_stream_chunk/2` -> `UsageAccumulator` ->
`Backplane.AiProtocol.OpenAIResponsesObserver` -> `SSE`/`Serialization`. Non-stream response bodies
enter the same observer from `AccessEvent`. Observer facts are projected by `AccessEvent` ->
Observability event -> `Backplane.LLM.LogWriter` -> `llm_logs`. Routing, authorization, credentials,
Relayixir transport, and durable persistence remain host-owned.

## BP01-BP14

| ID | Result | Evidence boundary |
| --- | --- | --- |
| BP01 | Passed | Real public plug/route, synthetic bearer replacement, model rewrite, one upstream submission. |
| BP02 | Passed | Native non-stream body preserved; usage/cache/reasoning/provider ID and observer identity persisted. Selected fixture has no executable tool request. |
| BP03 | Passed | Direct split/coalesced CRLF framing plus real socket stream; forwarded body contains native terminal. |
| BP04 | Passed | Usage after content delta retained; terminal count is one. |
| BP05 | Passed | Parallel canonical call IDs preserved; malformed partial arguments stay `complete: false`; observer never executes tools. |
| BP06 | Passed at core/native-observer layer | Refusal and incomplete lifecycle meanings remain distinct from failed/cancelled/interrupted. |
| BP07 | Passed | HTTP 400/protocol error body is forwarded and sanitized code/type reach the durable log. |
| BP08 | Passed | Malformed JSON body is unchanged; tokens remain unknown and observation is incomplete. Oversize is bounded. |
| BP09 | Passed at shared transport seam | Relayixir disconnect closes the upstream stream and emits disconnect without replay; host cleanup regression passes. |
| BP10 | Passed | Snapshot usage, unknown versus observed values, cache/reasoning inclusion, one submission and one log projection. |
| BP11 | Passed for observer ownership | Frame/buffer/total-byte limits are tested. Observation is synchronous in Relayixir's callback, so no separate unbounded tee mailbox exists. Full transport capacity testing is not claimed. |
| BP12 | Passed | Real logs contain the shared implementation identity and values unavailable from the old Responses parser. |
| BP13 | Passed for deterministic tests | Chat/Anthropic legacy parser, ordinary proxy, Codex Responses/compact/disconnect and rejection regressions pass. Live Codex is not run. |
| BP14 | Partial | Selection has no test toggle and clean consumer releases have the correct composition. The actual Backplane release build did not complete because the local macOS SDK cannot link `bcrypt_elixir`. |

## Verification results

| Command | Result |
| --- | --- |
| `mix do --app backplane_ai_protocol cmd mix test` | `51 passed`, exit 0. |
| `MIX_ENV=test mix do --app backplane_ai_protocol_testkit test` | `2 passed`, exit 0. |
| Six new host tests, each run by `file.exs:line` | Six isolated runs, each `1 passed`, exit 0. Combined execution retains an existing global writer/sandbox race and is not claimed passed. |
| `mix do --app backplane_llama cmd mix test test/backplane/llm/usage_accumulator_test.exs` | `8 passed`, exit 0. |
| `... router_codex_rejection_test.exs` / `... openai_codex_proxy_plug_test.exs` / `... proxy_plug_test.exs` | `1` / `18` / `6` passed, exit 0. |
| `mix do --app relayixir cmd mix test test/relayixir/proxy/http_plug_body_override_test.exs` | `9 passed`, exit 0. |
| `mix run --no-start test/ci_workflow_test.exs` | `4 passed`, exit 0. |
| `mix format --check-formatted` | Passed, exit 0. |
| `mix credo --strict` | `1414 source files`, `19428 mods/funs`, no issues, exit 0. |
| `mix compile --warnings-as-errors` | Failed, exit 1, on existing `backplane_mcp_protocol` warnings (`registry.ex:54`, `stream.ex:237`); not counted as passed. |
| `mix dialyzer --format raw` | Failed, exit 2: 143 total warnings, 124 ignored, 44 unnecessary ignores. Diff-attributable warnings remain at `error.ex:120`, `provider_state.ex:91`, `response.ex:112`, and `access_event.ex:214`. |
| `MIX_ENV=prod mix release backplane --path /tmp/backplane-ai-protocol-final.V1KWqW/backplane-release --overwrite` | Failed, exit 1 while linking unchanged `bcrypt_elixir`: macOS SDK `libSystem.tbd` reports unknown `arm64e.x1` architecture. No Backplane release artifact was produced. |
| Protocol Lab: `mix clean`, `mix deps.clean --all`, `mix deps.get`, `mix compile --warnings-as-errors`, `mix escript.build`, `./protocol_lab` | All exit 0; output: `request_model=fixture-model`, shared observer, `terminal=completed input_tokens=11 output_tokens=7`. |

The first host-suite attempt required `MIX_ENV=test mix ecto.migrate` because the local test database
lacked current OAuth/auth/log migrations. The migration completed locally. A combined durable-log
run can flush stale global-buffer records after sandbox rollback and hit `llm_logs_provider_id_fkey`;
the six new cases pass in isolated processes. This is an existing test-isolation issue, not a passed
repository-wide gate.

## PR #32 persistence follow-up (2026-09-11)

This section supersedes the durable-log sandbox limitation immediately above for the
`backplane_llama` test application. Verification started from local and remote branch HEAD
`a176974a0436e70988836fbcc65fb698350f526d`; the shared Responses observer integration and the
dedicated compact legacy path were retained.

The CI seed reproduced the reported result before the follow-up fix:

| Command | Result |
| --- | --- |
| `MIX_ENV=test mix do --app backplane_llama cmd mix test --seed 181124` | `242/247 passed`, five failures, exit 1 (inner app exit 2). |

There were two test-boundary causes. First, `Buffer.try_enqueue/2` reserves capacity and sends the
event asynchronously, while `LogWriter.flush/0` asks a different process to drain the buffer. The
drain could overtake the accepted enqueue. Second, the explicit test-only v2 disable flag was
unset, allowing runtime Settings to start a global writer outside an ExUnit sandbox owner. Delayed
records then crossed test transactions and could fail a later batch with a provider foreign-key
violation. Broad latest-row/model queries could consequently select another request. The legacy
`UsageCollector` test was also subject to the same runtime v2 policy and could intentionally no-op.

The follow-up disables v2 in the `backplane_llama` test bootstrap and terminates only the Llama
supervisor's globally booted writer/buffer children. Tagged observability tests then own their
supervised writer/buffer lifecycle under the active sandbox. The flush helper establishes a buffer
mailbox barrier, and persisted access records are selected by the exact request ID carried in the
test connection. The legacy collector test explicitly selects its path and preserves the
pre-existing telemetry handler and flag state.

Final local results for the follow-up changes:

| Command | Result |
| --- | --- |
| `MIX_ENV=test mix do --app backplane_llama cmd mix test --seed 181124` | `247 passed`, exit 0. |
| `MIX_ENV=test mix do --app backplane_llama cmd mix test --seed 424242` | `247 passed`, exit 0. |
| `MIX_ENV=test mix do --app backplane_llama cmd mix test --seed 987654` | `247 passed`, exit 0. |
| `MIX_ENV=test mix do --app backplane_llama cmd mix test test/backplane/llm/access_observability_test.exs test/backplane/llm/streaming_integration_test.exs` | `26 passed`, seed `660367`, exit 0. |
| `MIX_ENV=test mix do --app backplane_ai_protocol cmd mix test` | `56 passed`, seed `955158`, exit 0. |
| `MIX_ENV=test mix do --app backplane_ai_protocol_testkit test` | `2 passed`, seed `863320`, exit 0; existing unrelated compile warnings were emitted. |
| `mix format --check-formatted` | Passed, exit 0. |
| `git diff --check` | Passed, exit 0. |
| `mix compile --warnings-as-errors` | Failed, exit 1, on the existing `backplane_mcp_protocol` dynamic `profile/0` and Elixir 1.20 bitstring pin warnings; no follow-up file was reported. |
| `MIX_ENV=test mix do --app backplane_telemetry cmd mix test` | Baseline limitation: `30/32 passed`; two existing `FlagsTest` expectations conflict with enabled runtime Settings defaults. No Llama test-bootstrap code is loaded by this command. |

The complete runs still print pre-existing `Backplane.Settings.Credentials.Vault` sandbox-owner
warnings from unrelated asynchronous credential cache reloads. They do not fail the application
suite and are not represented as fixed by this follow-up.

Delivery commit `97112cea3160b9f06ed3448b65204c0b4a4e0816` and seeded-verification report commit
`c1e55867003ef02d907891d9a8a8cd65597be936` were pushed to `feature/ai-protocol`. CI on
`c1e55867003ef02d907891d9a8a8cd65597be936` passed `Test (backplane_llama)` with 247 tests and
zero failures (seed `593568`),
along with both protocol package jobs. Compile, format, Credo, and workflow-contract jobs also
passed on the same SHA. The overall workflows remain red on the same app-test job set and the same
12 `backplane_memory` Dialyzer warnings demonstrated on `main` SHA
`bd5bc83005fded6f67beefe3fa8abac31eae506a`; no final-SHA Dialyzer warning names
`backplane_ai_protocol` or `backplane_llama`.

## Artifact evidence

- Core `backplane_ai_protocol-0.1.0.tar` SHA-256:
  `6ed0e9520ffa9874c6fe783dd5d9a23f3c58f602ed09621f4b7eda38fa6b2a37`.
- TestKit `backplane_ai_protocol_testkit-0.1.0.tar` SHA-256:
  `874049090b1d10d57df167319228550822c39041ccce1431e4e587d5e9c1e21c`.
- A newly signed local Hex registry and fresh repository-external consumers under
  `/tmp/backplane-ai-protocol-final.V1KWqW` were used. The core consumer did not declare Jason;
  production compile returned `{Backplane.AiProtocol.OpenAIResponsesObserver, :completed, 2, 1}`.
- Core production release contains `backplane_ai_protocol` and `jason`, and excludes TestKit,
  ExUnit, and fake servers. The consumer with TestKit declared `only: :test` passed one fixture test;
  its production release excludes protocol, TestKit, Jason, and ExUnit.

## Remaining legacy paths and blockers

OpenAI Chat Completions, Anthropic Messages, and all Codex-specialized paths retain host parsing.
Cross-protocol request/response translation, complete codecs, OAuth/catalog migration, a real WS
service, Sigma/Synapsis adoption, and live-provider compatibility are not implemented or claimed.
Repository-wide warnings-as-errors, Dialyzer, the actual Backplane release, and the full umbrella
suite are not passing evidence in this report. The four earlier diff-attributable Dialyzer warnings
were removed before the final delivery; final-SHA CI is blocked by the demonstrated
`backplane_memory` baseline warnings instead. Existing warnings, the macOS SDK linker failure, and
the remaining cross-app sandbox races require separate ownership or a matching baseline
environment.

## Rollback

For subsequent ordinary non-Codex Responses requests, restore `AccessEvent.mark_stream/1` and
non-stream observation to `UsageAccumulator.new(:legacy)`/the prior host token extraction, then
remove the `backplane_llama` dependency only after no runtime references remain. Preserve
Relayixir, routing, authorization, credential storage, and logging. Never replay or resubmit an
in-flight generation during rollback; existing requests finish or terminate under their original
attempt identity.
