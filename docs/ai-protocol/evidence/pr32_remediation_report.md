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

## Current-source review follow-up (2026-09-14)

This section supersedes the historical status statements above for the current review. Earlier
SHAs, findings, artifact hashes, environments, and check results remain historical evidence only.

### Source and delivery state

- Review checkout: `feature/ai-protocol` at
  `635ad1c86e341b6864e03befa38397b1740717d3`; the worktree was clean before this review.
- GitHub PR #32 head: `635ad1c86e341b6864e03befa38397b1740717d3`; base branch `main` at
  `bd5bc83005fded6f67beefe3fa8abac31eae506a`. GitHub reported the PR open, mergeable, and
  `UNSTABLE`.
- Historical reviewed SHA `9bfa152da0971e029173876134cc3761eef3f298` was not used as
  evidence for current behavior.
- Current toolchain: devenv input 2.1.2, Elixir/Mix 1.18.4, OTP 28 / ERTS 16.4.0.1, Git 2.54.0.
  Root `mix.lock` SHA-256:
  `773ba7d426e45e62dfe098956f0afc41f16bf3bdf86b0a37f1b89f88a9c9416a`.
- The reviewed PR-head diff has 71 files, 8,047 insertions, and 67 deletions. The review repairs are
  recorded in `5535d21748ade438dd36977d1b083f242d1da7a3`,
  `9e1f9db981d01821905979f948173669c0b8e2d2`, and
  `fd7435fa1fb9072a201f6f679abff823aaebcaec`. The review patch SHA-256 against the starting HEAD
  (tracked `apps/` plus `examples/protocol_lab`, excluding this evidence) is
  `26a77217dc69f22a634f20bb13c01e60a54e8f774c1314d2e225097a69bb336d`; the new real-endpoint
  test SHA-256 is `d58c8827e7a94ce4ab6db47c6159b9a312d29970f92d2a9377bebc968fd722e9`.
- No merge, deploy, live-provider call, quota use, or personal-credential import was performed.

### Current-source verification (2026-09-14 follow-up)

- `git fetch origin feature/ai-protocol` confirms the remote PR head remains
  `70b9609dab87eb5beea59d90a521ab1541d94839`; PR #32 reports the same head and base
  `bd5bc83005fded6f67beefe3fa8abac31eae506a`.
- The required chunked non-streaming and >8 MiB endpoint regressions were absent from that
  remote source. They are now implemented locally in
  `apps/backplane_api/test/backplane/api/llm_protocol_endpoint_integration_test.exs` and committed
  as `91a3d72a78150defcd53c786de9d64e42af65f07`; this commit is not on the remote PR because push
  was explicitly disallowed.
- Local endpoint verification on the working tree passed 10 tests for seeds `0`, `424242`, and
  `987654`. The chunked case reconstructs and compares the exact native response body, records one
  upstream submission and one durable log, and verifies complete usage. The overflow case verifies
  native forwarding, one submission, bounded/incomplete observation, unknown usage, byte count over
  `8_388_608`, and the stable `response_bytes_exceeded` diagnostic.
- The detached clean worktree was advanced to `91a3d72a`, but cannot execute tests because it has no
  downloaded Mix dependencies; the command fails before compilation with `mix deps.get` required.
  This is an environment limitation, not passing clean-worktree evidence.
- Current PR CI run `34795930657` tested SHA `70b9609d` (not `91a3d72a`) and still fails the
  `backplane`, `backplane_admin`, `backplane_mcp`, `backplane_memory`, `backplane_skills`,
  `backplane_system`, `backplane_telemetry`, and Dialyzer jobs. GitHub log retrieval returned a
  results-receiver connection error in this environment, so per-test stack traces and equivalent
  base reproductions remain unverified here. Passing checks include `backplane_api`, `backplane_llama`,
  both protocol jobs, Relayixir, compile, format, Credo, and workflow contract.

### Current finding dispositions

| Finding | Current disposition | Current evidence |
| --- | --- | --- |
| R01 | Fixed | Recursive validation re-enters every declared container; depth, node, byte, and collection budgets are cumulative. Current core suite: 62 tests, zero failures. |
| R02 | Fixed after review repair | Prebuilt `ContentBlock`, `Message`, `ToolDefinition`, `ToolCall`, `ProviderState`, and `Usage` values are revalidated; atom/string core-key collisions are rejected; recursive serialization isolation remains covered. The new tests failed before the constructor repairs and pass after them. |
| R03 | Fixed | Positive preservation and negative affinity checks cover protocol, profile, provider, endpoint, account, workspace, and model across all declared request/response/message/content/tool carriers. |
| R04 | Fixed for the declared pure-preflight subset | Unknown target capability remains unverified, executable host rules require revisions, and host denial wins over caller downgrade permission. No translated production route is claimed. |
| R05 | Fixed | Actual core and TestKit archives installed from a signed local registry into a fresh external consumer. Test and production compile passed; production releases contain core/Jason and exclude TestKit/ExUnit. |
| R06 | Fixed after review repair | `cancel/2` now rejects invalid certainty; `interrupt/2` provides the declared interrupted terminal; repeated and late terminal transitions are rejected; finished handles cannot be claimed. |
| R07 | Fixed | Protocol Lab source is tracked, `/protocol_lab` ignore is anchored, and an isolated warnings-as-errors build plus escript execution used the package observer and fixture. |
| R08 | Fixed at declared wire-contract scope after review repair | Admission, correlation, credit, sequencing, terminal cleanup, draining, and negotiated limits remain covered; `max_seen_ids` now rejects zero, negative, and non-integer values. A production WebSocket server is not claimed. |
| R09 | Not verified for the repaired source state | Local compile, format, Credo, scoped tests, package consumers, releases, and diff checks pass. Dialyzer still exits 2 with the exact 12 `backplane_memory` warnings and counts reproduced at base. Available completed GitHub CI is for unrepaired PR head `635ad1c...` and is red; matching CI for the repair commits has not completed. |
| R10 | Fixed for the declared ordinary non-Codex Responses native-observation path | A real listening `Backplane.Api.Endpoint` routed `/v1/responses` to a deterministic fake upstream once with model rewrite and credential replacement. Shared observer facts drive durable usage/error logs while Relayixir and native response bytes remain host-owned. |

### Confirmed current defects and repairs

1. Constructor composition trusted already-constructed structs, and `ContentBlock` allowed mixed
   atom/string core-key collisions. Regression tests first failed, then constructors were changed to
   project and revalidate their own structs. Malformed prebuilt provider state and usage are now
   rejected without rejecting valid composed values.
2. `Wire.new/1` accepted invalid `max_seen_ids` values. A failing regression established that zero,
   negative, and non-integer values must return structured validation errors; the option is now
   restricted to positive integers or the documented default.
3. The lifecycle declared `:interrupted` but exposed no transition, and cancellation accepted an
   arbitrary certainty. Failing lifecycle tests preceded the minimal `interrupt/2` transition and
   certainty validation.
4. An ordinary Responses refusal encoded directly as an output item was not observed as a refusal.
   A failing fixture preceded refusal detection for direct output items and message content.
5. Relayixir marked downstream disconnects in `conn.private`, but the LLM router derived the durable
   outcome only from HTTP status and wrote `success`. A real streaming regression failed with that
   value before the router began mapping the disconnect marker to `cancelled`. The test asserts one
   upstream submission and one durable `ProxyRequest` row.
6. The new Relayixir closed-chunk test adapter was defined outside its async test module. In a clean
   build the test could execute before the adapter module was loaded and raised
   `UndefinedFunctionError`. Nesting the adapter under the test module removed that ordering race;
   the full Relayixir suite then passed from a fresh build.
7. Ten newly-added files had blank lines at EOF and failed `git diff --check`. Only those trailing
   blank lines were removed.
8. The real Bandit endpoint exposed that a semantic non-stream Responses result can use HTTP
   chunked transfer. Relayixir forwards such a response without retaining `conn.resp_body`, so the
   prior non-stream observer path wrote a successful log with nil usage and empty observation
   metadata. The failing socket test preceded an observation-only Relayixir body callback and a
   bounded Backplane body accumulator. Collected bodies and forwarded chunks now enter the same
   shared observer without mapping native bytes; the real endpoint writes exactly one record with
   the provider ID, token/cache/reasoning facts, terminal, implementation identity, and bounded
   diagnostics.

### Gate B and BP01-BP14 on current source

The production-capable call graph remains:

`Backplane.Api.Endpoint` -> `Backplane.LLM.ProxyPlug` -> `Backplane.LLM.Router` -> host
authorization/model/credential binding -> Relayixir -> one upstream submission -> unchanged native
response. Ordinary non-Codex Responses observation enters
`Backplane.LLM.AccessEvent`/`UsageAccumulator` ->
`Backplane.AiProtocol.OpenAIResponsesObserver` -> durable observability consumers. Translation,
Codex-specialized transport, credential ownership, routing, and forwarding remain host-native.

| ID | Current result | Evidence boundary |
| --- | --- | --- |
| BP01 | Passed | A socket client reached an actual listening Backplane endpoint; fake upstream saw one request, rewritten model, and only the synthetic provider bearer. Inbound bearer/API-key values did not leak. |
| BP02 | Passed | Native non-stream body was returned unchanged while shared implementation identity, provider response ID, usage, cache, and reasoning values reached the durable record. |
| BP03 | Passed | Core split/coalesced CRLF and UTF-8 fixture tests plus socket-backed Relayixir streaming retain SSE fragmentation without body rewriting. |
| BP04 | Passed | Trailing usage after content deltas is retained and exactly one terminal is projected. |
| BP05 | Passed | Parallel call identities remain distinct; malformed partial arguments remain incomplete; the observer performs no execution. |
| BP06 | Passed after review repair | Direct and message-content refusals are distinguished from output-limit completion. Both meanings reach host durable logs without converting native HTTP success into transport failure. |
| BP07 | Passed | HTTP and protocol errors retain native forwarding; only sanitized code/type values are projected. |
| BP08 | Passed | Truncated, malformed, and oversized observations remain bounded/incomplete while native response forwarding is unchanged. |
| BP09 | Passed after review repair | A downstream disconnect closes observation, writes `cancelled`, submits once, and writes once; Relayixir performs no replay. |
| BP10 | Passed | Tests assert exact submission and durable-write counts, snapshot/trailing usage, and explicit unknown rather than fabricated token values. |
| BP11 | Passed for bounded synchronous observation | Frame, buffer, and total-byte limits are exercised. The Relayixir callback is synchronous and creates no unbounded observer mailbox. Full transport-capacity testing is not claimed. |
| BP12 | Passed | Durable consumers use shared-package observer identity and facts unavailable from the legacy Responses parser. |
| BP13 | Passed for deterministic scope | Non-target native Chat, Anthropic, Codex Responses/compact, disconnect, and routing regressions remain deterministic. Live providers were explicitly prohibited and were not called. |
| BP14 | Passed on the current Linux toolchain | Actual Backplane release and fresh external-consumer test/production releases build. Host release includes core/Jason; TestKit and ExUnit are absent. |

This is not full proxy migration. Only ordinary non-Codex OpenAI Responses native observation is
migrated. Chat Completions, Anthropic Messages, Codex-specialized paths, cross-protocol translation,
OAuth/catalog work, a production WebSocket service, and the remaining T01-T28 V1 program remain
outside this PR's declared migrated path.

### Current verification results

| Command | Current result |
| --- | --- |
| `MIX_ENV=test mix do --app backplane_ai_protocol cmd mix test` | 62 tests, zero failures. |
| `MIX_ENV=test mix do --app backplane_ai_protocol_testkit test` | 2 tests, zero failures. |
| `MIX_ENV=test mix do --app backplane_api cmd mix test test/backplane/api/llm_protocol_endpoint_integration_test.exs --seed <seed>` | 8 tests, zero failures for seeds 0, 424242, and 987654. Actual listening endpoint covers normal JSON, fragmented SSE/trailing usage, native errors, malformed JSON, refusal, output limit, truncated SSE, downstream disconnect, one deterministic fake-upstream submission per case, one durable write per case, shared facts, and bounded observation. |
| `MIX_ENV=test mix do --app backplane_api cmd mix test` | Failed: 235 tests, 6 failures. Five failures report host-memory storage unavailable or missing `bpm_host_memory_compat_receipts`; one related channel assertion receives the same storage error. None of the failing files differ between PR head and base, and the PR-head GitHub `backplane_api` job passes. This local schema/environment failure is not labeled passing or repaired. |
| `MIX_ENV=test mix do --app backplane_llama cmd mix test` | 251 tests, zero failures. Existing asynchronous credentials/log-writer sandbox diagnostics were emitted and are not represented as repaired. |
| `MIX_ENV=test mix do --app relayixir cmd mix test` | 247 tests, zero failures after the adapter-ordering and response-body observation repairs. |
| `mix compile --force --warnings-as-errors` | Passed, exit 0. |
| `mix format --check-formatted` | Passed, exit 0, after the final evidence update. |
| `mix credo --strict` | 1,415 source files / 19,520 mods and functions, no issues, exit 0, after the final source update. |
| `mix dialyzer --format raw` | Failed, exit 2: 160 total, 148 skipped, 30 unnecessary skips; all 12 emitted warnings are unchanged `backplane_memory` warnings also reproduced at base. No reviewed file is named. |
| `MIX_ENV=prod mix release backplane --path /tmp/backplane-pr32-host-release --overwrite` | Passed, exit 0. |
| Protocol Lab isolated compile/escript/run | Passed; `request_model=fixture-model`, shared observer, `terminal=completed input_tokens=11 output_tokens=7`. |
| Fresh external consumer test and production release | 1 doctest plus 1 test, zero failures; production compile passed with warnings as errors. Core tar SHA-256 `e425866a3ff887359d52e01af2376e5a29faf3fba7e1b9d22e9302639bf263a8`; TestKit tar SHA-256 `f662c1772b89a2d28157c8ef0dc3e8e4487e46ce6ee10aefc0a77e03e2783187`. |

### CI and remaining review limitation

At the pre-delivery PR head `635ad1c...`, GitHub reports Compile, Format Check, Workflow Contract, Credo, both
protocol package tests, and the listed unaffected app jobs passing. Dialyzer and nine app-test jobs
are red. Eight red app jobs match the base-branch red set; `backplane_mcp_protocol` and Relayixir are
additional at PR head, while `backplane_llama` changed from base red to PR-head green.

The Relayixir failure is repaired and passes locally. The `backplane_mcp_protocol` failure is
outside the PR diff and is independently reproducible from a clean build: its 2026-07-03 test calls
`function_exported?(ToolWithOutputSchema, :output_schema, 0)` without first loading the support
module, yielding 1 failure in 1,329 tests plus 33 doctests. It is reported as a pre-existing test
ordering defect and is intentionally not modified under this PR's scope rule.

Because no matching GitHub CI run has completed for the repaired commits, R09 is not verified
against the exact tested source state. The review therefore remains incomplete and does not approve
merge, despite both functional gates passing locally for the declared scope.

## Endpoint regression coverage update (2026-09-15)

This section supersedes the current-delivery statements above. The current remote PR head is
`70b9609dab87eb5beea59d90a521ab1541d94839`, the base is
`bd5bc83005fded6f67beefe3fa8abac31eae506a`, and GitHub's merge-test commit is
`f9eff712430f9fc5d143fa50667ca21716fadd93`. The head and merge-test commits have the same source
tree, `77410169d3159930f2d321aa9e754c37fd3413f3`. GitHub CI runs `34795930919` and
`34795930657` therefore cover the committed production repairs at the current PR head; the earlier
statement that the latest repaired source had no matching CI run is no longer current.

Two required real-endpoint cases were still absent from that committed source. They have been added
locally to `apps/backplane_api/test/backplane/api/llm_protocol_endpoint_integration_test.exs` without
changing production code:

1. A semantic non-stream Responses JSON body is split inside JSON tokens across three HTTP chunks.
   The fake upstream pauses after the second chunk; the test confirms that no completed durable log
   exists before the final fragment. After completion, it asserts byte-exact native forwarding, one
   upstream submission, one durable row, the provider response ID, input/output/cache/reasoning
   usage, a complete observation, a completed terminal, and exact semantic `bytes_seen`.
2. A transport-valid chunked JSON body larger than 8 MiB is forwarded byte-for-byte without changing
   Relayixir's transport limits. The observer records the actual bytes presented, returns an
   incomplete observation with `response_bytes_exceeded`, and does not claim usage or provider
   response identity from the discarded oversized semantic body.

The endpoint file now contains 10 tests and passes under seeds 0, 424242, and 987654. The normal
`backplane_api` application test command discovers both cases and passes with 244 tests at seed 0.
These two tests and this evidence update are local working-tree changes and are not covered by the
current remote runs until committed and pushed.

### Current PR and base-equivalent CI boundary

PR CI run `34795930919` and Test run `34795930657` are associated with head `70b9609d...` and check
the tree-identical merge-test commit `f9eff712...`; push run `34795927803` checks the exact head.
Compile, format, workflow contract, Credo, protocol, TestKit, API, Llama, and Relayixir jobs pass.
Dialyzer and seven application jobs remain red. Comparison with base runs `34214605966` and
`34214605975`, plus equivalent local head/base reproductions, established the following failures as
base-equivalent rather than introduced by this PR:

| Current failed job | PR job ID | Base job ID | Failure boundary |
| --- | ---: | ---: | --- |
| Dialyzer | `103828898194` | `102023295355` | Same 12 emitted `backplane_memory` warnings; 160 total, 148 skipped, 30 unnecessary skips. Exact-head push job `103828888672` matches. |
| `backplane_telemetry` | `103828897578` | `102023295694` | Same two `FlagsTest` default/master-switch failures. |
| `backplane_admin` | `103828897672` | `102023295686` | Same ten memory-recall canonical-partition failures. |
| `backplane_skills` | `103828897708` | `102023295587` | Same `LocalFS :bad_name` and unavailable API endpoint failures. |
| `backplane_system` | `103828897729` | `102023295749` | Same 22 Tzdata/Boruta/Oban/ETS/cache/mock-runtime failures. |
| `backplane` | `103828897792` | `102023295750` | Same two memory MCP `:incomplete_partition` failures. |
| `backplane_memory` | `103828897796` | `102023295668` | Same 40 canonical-partition failures. |
| `backplane_mcp` | `103828897822` | `102023295767` | Same four remote-IP, skill-load, and batch failures. |

These failures are not repaired by this scoped change, are not reported as passing, and keep the
repository-wide CI gate red unless repository policy separately waives or fixes them. The verified
migration boundary remains ordinary non-Codex OpenAI Responses native observation. Relayixir owns
forwarding, and Backplane retains authorization, routing, credentials, observation and persistence;
no full proxy migration or cross-protocol translation is claimed.

## Duplicate endpoint regression cleanup (2026-09-15)

This section supersedes the local-only endpoint status above. Reviewed remote head
`e858394ee0404912c08065f9cbe2596f60b205e0` accidentally contained two `chunked-json` routes,
overlapping fixtures, two regression pairs, and duplicate generic `decode_chunked_body/2` clauses.
The first synchronized route shadowed the older route and caused the older test to wait for a
release message it never sent. No production defect was reproduced.

Commit `b35037cfe5cfb7cdfa6121121649c1cd5fde7bdb` removes only the redundant test code and retains:

- one synchronized `chunked-json` regression, including the pre-completion no-log barrier;
- one `chunked-overflow` regression above the 8 MiB observation bound;
- one chunk decoder supporting chunk extensions and the zero-size terminator.

The endpoint suite contains exactly 10 tests and passes at seeds `0`, `424242`, and `987654`.
The full `backplane_api` application passes 244 tests. Protocol, TestKit, Llama, and Relayixir pass
62, 2, 251, and 247 tests respectively. `mix format --check-formatted`, `mix credo --strict`
(1,415 files / 19,527 mods and functions), and `git diff --check` pass. Local
`mix compile --warnings-as-errors` exits 1 only for existing `backplane_mcp_protocol` dynamic
`profile/0` and bitstring-size pin warnings; no changed file is reported. Production AI protocol
and Relayixir files are unchanged.

The authorized push produced exact cleanup-source SHA
`646531923b7d873026724eb7c72da7814fbf905f`. Test run `34921657683` completed with
`Test (backplane_api)` job `104230898550` passing. The same run also passed the protocol, TestKit,
Llama, Relayixir, MCP protocol, and unaffected application jobs. CI runs `34921657583` and
`34921654420` passed compile, format, Credo, and workflow contract. Both Dialyzer jobs and the seven
established base-equivalent application jobs remain red; they are not claimed fixed or waived.
