# Antigravity subscription native API implementation

Status: implemented and locally verified. User objective: complete native API access
based on `/Users/gao/Workspace/Github/antigravity-claude-proxy`, with reusable
protocol support in `backplane_ai_protocol`. OpenAI/Anthropic conversion is a
separate future scope. Live subscription calls were later verified through the
standard Gemini compatibility surface; component checks remain required.

## Evidence and supported contract

Reference: `antigravity-claude-proxy` v2.7.7, commit
`daa39d6c6239ac078a4e69de85094dde35558ef6`, MIT. Its Cloud Code integration is
implementation evidence, not an official public Google API specification.

| Operation | Upstream request | Reference |
| --- | --- | --- |
| load_code_assist | POST `/v1internal:loadCodeAssist`, metadata + mode | `src/account-manager/credentials.js:219`, `src/cloudcode/model-api.js:201` |
| onboard_user | POST `/v1internal:onboardUser`, tierId + metadata | `src/account-manager/onboarding.js:37` |
| fetch_available_models | POST `/v1internal:fetchAvailableModels`, optional project | `src/cloudcode/model-api.js:53` |
| generate_content | POST `/v1internal:generateContent`, native envelope | `src/cloudcode/request-builder.js:67`, `message-handler.js:139` |
| stream_generate_content | POST `/v1internal:streamGenerateContent?alt=sse` | `src/cloudcode/streaming-handler.js:152` |

The original reference exposes five RPC operations. Onboarding polls by
resubmitting its request and reading
`done/response.cloudaicompanionProject.id`, not a getOperation endpoint. It
contains no Files, embeddings, Interactions, Batch or cancel RPC; unsupported
operations must fail explicitly, not use guessed URLs. A later authenticated
wire probe verified `POST /v1internal:countTokens`, which is used only behind the
standard Gemini compatibility surface and is not added to the native public API.

Generation envelope: `project`, `model`, opaque `request`, `userAgent`,
`requestType`, `requestId`; sessionId is inside request and mirrored in
X-Machine-Session-Id. Responses/SSE may wrap GenerateContent fields in `response`.
Keep native parts, tools, images, thought signatures, multiple candidates and
unknown fields. Do not copy prompt injection/scrubbing, canonical conversion,
signature caches, synthetic model catalogs or fallback project IDs.

## Frozen architecture and interfaces

`Backplane.AiProtocol.Antigravity` is a pure native protocol facade, with no Req,
Phoenix, Ecto, vault, local credential lookup, HTTP process or account pool.
Expose:

- `operations/0`; `operation/1` maps the exact RPC string to an operation atom.
- `build_request(operation, native_body, opts \\ [])` returns
  `{:ok, %{method: :post, path: binary, query: binary, headers: list, body: map}}`
  or `{:error, Backplane.AiProtocol.Error.t()}`. Generation requires an explicit
  trusted `:project`; `:model`, `:session_id`, `:request_id` bind routing metadata
  when supplied, rejecting conflicting caller values. Inner request is not
  translated. Model identifiers are safe single segments. Session/request IDs
  are bounded strings, never copied into headers without CR/LF validation.
  Headers contain protocol metadata, never credentials. `:user_agent` and
  `:client_version` are optional host-provided client headers; no copied Node
  fingerprint. Bootstrap defaults to metadata ideType=9/pluginType=2/platform=0
  and mode=1, while preserving explicit native metadata. Onboarding requires
  tierId; configured project binds metadata.duetProject, never a fabricated
  top-level project. Model fetch uses the configured project if present.
- `decode_response(operation, status, headers, binary, opts \\ [])` returns a
  native response map retaining the original document (including envelope), or
  a sanitized structured Error. Helpers `project/1`, `models/1`,
  `onboarding_status/1` expose actual fields without inventing defaults.
- `stream_new/1`, `stream_feed/2`, `stream_finish/2` expose bounded SSE native
  documents and keep transport completion separate from finishReason; no DONE
  synthesis, no early close on STOP, errors/cancellation remain incomplete.
- `Antigravity.Observer.new/feed/finish/facts/observe_response` follows the
  existing Google observer interface, unwrapping only for observation. It has
  bounded buffering/parse budgets, preserves raw usage counters and cannot
  disrupt native forwarding. Observation source/protocol identifies Antigravity.

Backplane host integration uses a distinct `:antigravity` API surface and
`:google_antigravity` native protocol, preset `google-antigravity`, OAuth
`google_oauth` only. Existing OAuth login/refresh and monitoring remain intact.
ProviderApi adds `backend_config` map with explicit `project_id` and optional
`user_agent`/`client_version`; no secrets stored there. Project is configured by
the operator from bootstrap/onboarding results; no background enrollment or
silent project persistence. Endpoint is admin-owned, default
`https://cloudcode-pa.googleapis.com`, with no generation replay/failover.

Public native route:
`POST /antigravity/providers/:provider_name/v1internal:<operation>`.
This binds bootstrap, enrollment, catalog and generation to one provider/account.
Caller credentials authenticate to resource `:v1`; upstream bearer is injected
from that provider only. Reject query credentials, arbitrary query parameters,
conflicting credential carriers and client routing/project overrides. Streaming
accepts an empty query or exactly `alt=sse`; the upstream descriptor always sets
`alt=sse`. Other RPCs accept only an empty query. `llm::models` covers bootstrap/catalog,
`llm::invoke` generation, new `llm::manage` enrollment. Enforce DB-client and OAuth
scopes. Google-shaped local errors, transparent native upstream status/headers/
body/SSE. No OpenAI/Anthropic translation selectors are enabled.

Generation resolves model/alias only within the named enabled provider and its
enabled Antigravity model surface. Use actual fetchAvailableModels map for
discovery; preserve all IDs/metadata/quota, do not infer capabilities from names.
Publish discovery transactionally using existing configuration-generation guards
extended with backend_config. A disabled provider/model or rotated binding cannot
be resurrected by late results. Control operations are explicit client calls,
never automatic paid generation. UI adds the distinct preset, trusted project
configuration, native-only labels and the operation/protocol usage display.

## Work and acceptance records

| task_id | initial_worker | current_worker | sol_escalated | sol_repair_rounds |
| --- | --- | --- | --- | --- |
| AG0-reference-contract | explorer | explorer | false | n/a |
| AG1-native-package | sol_worker | coordinator takeover | false | 2/2 |
| AG2-host-native | sol_worker | coordinator takeover | false | 2/2 |
| AG3-admin | terra_worker | sol_worker | true | 1/2 |
| AG4-release-evidence | coordinator | coordinator | false | n/a |

AG1 handoff: Sol stopped after two validation/repair rounds (compile warnings,
then scoped formatting). Coordinator takeover preserved the implementation and
reproduced malformed nested project data raising `FunctionClauseError` in
`Access.get/3` (12/13 tests passed). Pattern-matched project extraction fixed the
defect. Added wrapper-path coverage for repeated usage and usage arriving after
STOP, including a final unwrapped native frame. Full package suite then passed
123 tests. The original acceptance requirements and repair counter remain in
force; live/E2E checks remain unrun.

AG1 accepted: rebuilt package consumer verification passed for both Google and
Antigravity, including warnings-as-errors compilation and dependency isolation.
Artifact SHA-256:
`60c0549871017665bd882678497446a8b7a0e789e733a055f0e779c36ac490b2`.
Scoped formatting and diff checks passed. AG2 uses the same Sol thread for a
separate host-integration task; AG1 counters remain unchanged.

AG2 first validation exposed an incorrect OAuth test fixture (repair round 1)
and an unapplied test database migration (environment setup). Concurrent compile
also reported duplicate Antigravity UI clauses. AG3 Terra stopped immediately;
read-only handoff found single clauses in the current file and no running
commands. Its five-file admin diff and unrun tests transferred to Sol for
exclusive review and verification. No UI acceptance is claimed yet.

AG1 follow-up audit reopened the existing coordinator takeover for a confirmed
observer defect, without resetting counters: observation-budget exhaustion
prevented `finish/2` from recording EOF/cancellation. The regression failed with
`:failed` instead of `:eof` (exit 2). Finalization now preserves actual transport
outcomes while retaining incomplete observation; event-budget exhaustion after
STOP cannot claim protocol completion. The full package suite passed 125 tests
and package warnings-as-errors compilation passed after this repair.
Both consumers also passed against the rebuilt artifact
`tmp/ai-protocol-package.QZqMNq/backplane_ai_protocol-1.7.0.tar`, SHA-256
`9f019c557423795f94d4699cd7d00d77e46697a92cca2c629c4bf8835ed6315c`.

AG2 Sol stopped at 2/2 and transferred exclusive ownership to the coordinator.
Router regressions reproduced alias binding returning 400 and malformed native
request data raising `Access.get/3` (6/8 passed, exit 2). The coordinator fixed
outer-model rewriting and safe native request metadata extraction, completed
Antigravity enum/auto-model route migration support, protected discovery headers,
and advertised `llm::manage`. Expanded migration, authorization, router, discovery
and metadata-controller checks passed 47 tests. No live/E2E calls were run.

AG3 configuration/log checks initially passed 36 tests. Final review found that
actual nested quota metadata needed separate rendering coverage. Sol fixed map
rendering and added a discovered-model fixture with nested quota, unknown fields,
and unavailable quota. The two admin suites then passed 37 tests; scoped format
and diff checks passed (AG3 repair round 1/2).

Required evidence before completion:

1. All five operation descriptors/response forms, bootstrap/onboarding pending,
   complete and error states; invalid/unsupported operations; no fake project.
2. Arbitrary inner native fields, signatures, tool-call/result sequences and
   multi-candidate data survive request/response and arbitrary SSE fragmentation.
3. Bounded malformed/large stream handling, late/repeated usage, non-EOF outcomes,
   HTTP 400/401/403/429/5xx, Retry-After parsing without replay.
4. Independent source-based fixtures identify reference commit and explicitly
   distinguish handcrafted examples from captured upstream recordings.
5. Actual packaged consumer exercises bootstrap -> enrollment pending/done ->
   models -> generation -> native tool continuation and streaming without host
   dependencies or real network. No fabricated live-provider evidence.
6. Native host component tests cover every RPC, scope/credential/project binding,
   query/header/path attacks, model revocation, native response preservation,
   stream transport failures and observation isolation, zero cross-protocol calls.
7. Migration up/down preserves old rows; downgrade refuses configured Antigravity
   surfaces. Provider UI create/reopen/update, project config, catalog and protocol
   display work. Existing Gemini and monitor tests remain green.
8. Focused tests, warnings-as-errors compilation, scoped format/diff checks and
   package dependency-isolation verification. E2E/live account checks deferred by
   user instruction, explicitly recorded separately from implementation evidence.

## Separate future scope

OpenAI Chat/Responses and Anthropic Messages conversion, account pools, automatic
failover/replay, and unobserved Google operations require separate designs and
acceptance. Existing Antigravity OAuth usage-monitor support must not regress.

## Operator workflow and verification boundary

The integration passed local component and package verification. The following
workflow does not constitute evidence of live account compatibility. Apply the
new database migration and restart the gateway before using the new surface.

1. Retain or create a Google OAuth vault credential using the existing login
   flow, and select it for the `google-antigravity` provider preset.
2. Call the provider-bound `loadCodeAssist` operation with a Backplane credential
   granting `llm::models`. Read the returned project and tier information.
3. If enrollment is needed, explicitly call `onboardUser` with a credential
   granting `llm::manage` and the selected `tierId`. Repeat that same RPC while
   pending. Backplane must never perform enrollment automatically.
4. Configure the resulting project ID on that provider's Antigravity API
   surface. Use dynamic model reload or `fetchAvailableModels` to discover the
   account's actual catalog. There is no built-in model list.
5. Enable the desired discovered model and use a Backplane credential granting
   `llm::invoke` to call `generateContent` or `streamGenerateContent?alt=sse`.
   Supply the outer model and opaque native `request`; the host binds the
   configured project and injects the provider's OAuth bearer token.
6. For native tool continuation, retain the upstream native parts, including
   thought signatures, and append native tool results in the next request.
   Reuse the bounded native session ID when continuing a session.

Local component tests must exercise this workflow with sanitized, source-derived
fixtures and mock transport. They do not establish that Google's internal
service currently accepts a particular account, tier, client version or model.
Live subscription verification and E2E remain deferred at the user's request.

Native request examples (documentation only; not executed):

```http
POST /antigravity/providers/my-subscription/v1internal:loadCodeAssist
Authorization: Bearer <backplane-client-token>
Content-Type: application/json

{}
```

```http
POST /antigravity/providers/my-subscription/v1internal:onboardUser
Authorization: Bearer <backplane-client-token-with-llm::manage>
Content-Type: application/json

{"tierId":"<tier-returned-by-loadCodeAssist>"}
```

```http
POST /antigravity/providers/my-subscription/v1internal:fetchAvailableModels
Authorization: Bearer <backplane-client-token>
Content-Type: application/json

{}
```

After configuring the returned project and enabling a discovered model:

```http
POST /antigravity/providers/my-subscription/v1internal:generateContent
Authorization: Bearer <backplane-client-token>
Content-Type: application/json

{"model":"<discovered-model-id>","request":{"contents":[{"role":"user","parts":[{"text":"Hello"}]}]}}
```

For streaming use `v1internal:streamGenerateContent?alt=sse` with the same native
body. The Backplane client token authenticates the caller; the subscription OAuth
token is resolved from the configured vault credential and never belongs in the
client request. These examples omit the outer project binding intentionally:
the host supplies the configured project, and conflicting values are rejected.

### Google GenerateContent compatibility

The standard `/v1beta/models` surface also lists resolvable aliases backed by
enabled Antigravity model surfaces. Resolution prefers an enabled native Google
provider and falls back to the directed Google-to-Antigravity translation only
when native resolution has no match. The Antigravity API continues to advertise
only `google_antigravity` in `native_protocols`.

For `generateContent` and `streamGenerateContent?alt=sse`, the host preserves
Google contents, tools, function calls and results, thought signatures,
generation configuration, labels, and the client session ID inside the native
request. It injects the configured project and provider OAuth credential outside
that request. Antigravity response envelopes are unwrapped to Google JSON or
incremental Google SSE. Provider HTTP errors, retry headers, and error bodies
retain their upstream status and contents.

The standard `countTokens` route accepts direct `contents` or a mutually
exclusive `generateContentRequest`. It forwards only text parts and binds the
resolved model inside the upstream request. It sends no project, generation
request ID, or session ID. System instructions, tools, tool configuration,
cached content, media, function calls and results, and unknown fields return 422
instead of producing an incomplete count. Malformed structures and caller-owned
routing fields return 400. A successful upstream response must contain a
non-negative integer `totalTokens`; otherwise the gateway returns 502. The exact
empty response object is normalized to `totalTokens: 0` because the verified
protobuf response omits its scalar field when the count is zero. Other nonempty
objects without `totalTokens` remain invalid.

#### Live `agy` verification

On 2026-09-24, `agy` reporting `User-Agent: cli/1.2.9` completed a real streamed
generation through the standard Gemini surface. The test used the existing
aliases `gemini-3.8-flash` to
`google-antigravity/gemini-3.8-flash-low` and `gemini-3.1-flash-lite` to
`google-antigravity/gemini-3.1-flash-lite`. The account project discovered by
`loadCodeAssist` was configured on the provider and remained server-side.

Use only the Backplane gateway URL and authorization header. Remove native
Antigravity, Gemini API-key, and custom model overrides for this test:

```bash
env -u CLOUD_CODE_URL \
  -u GEMINI_API_KEY \
  -u AGY_GATEWAY_API_KEY \
  -u AGY_GATEWAY_MODELS \
  AGY_GATEWAY_URL=http://localhost:4220 \
  AGY_GATEWAY_HEADERS="Authorization: Bearer $LOCAL_BACKPLANE_TOKEN" \
  agy -p 'Reply only BACKPLANE_GEMINI_OK. Do not use tools.' \
  --model gemini-3.8-flash-low \
  --print-timeout 60s \
  --mode plan
```

The command exited 0 and returned `BACKPLANE_GEMINI_OK`. `llm_logs` recorded a
`google_generate_content` request on the `/v1beta` path, resolution to the
Antigravity provider and `gemini-3.8-flash-low`, HTTP 200, success, and
`finish_reason: STOP`. `GET /v1beta/models` listed the configured aliases. A
non-streaming `generateContent` call returned `BACKPLANE_JSON_OK` as unwrapped
standard Gemini JSON. Caller project injection returned 400.

To verify token counting through the same Gemini surface, send the Backplane
token in the `Authorization` header. The request is translated to the native
Antigravity `countTokens` RPC; the OAuth credential and project remain
server-side:

```bash
curl -sS \
  -H "Authorization: Bearer $LOCAL_BACKPLANE_TOKEN" \
  -H 'Content-Type: application/json' \
  http://localhost:4220/v1beta/models/gemini-3.8-flash:countTokens \
  -d '{"contents":[{"role":"user","parts":[{"text":"Hello world"}]}]}'
```

The verified response is `{"totalTokens":2}`. Empty text returns zero, while
unsupported system instructions, tools, and media return 422 instead of an
incomplete estimate. `llm_logs` records this as `count_tokens` with the result
under `metadata.operation.total_tokens`; it does not add the count to a
generation usage record.

An `agy` file-read tool loop also exited 0 and returned a random marker from a
temporary file when `--add-dir` and the absolute file path were supplied. A
relative path was not a valid test because this CLI defaults its workspace to
the user's home directory.

The reproducible tool-loop form is:

```bash
agy_tmp="$(mktemp -d)"
printf 'BACKPLANE_TOOL_OK\n' > "$agy_tmp/probe.txt"
env -u CLOUD_CODE_URL \
  -u GEMINI_API_KEY \
  -u AGY_GATEWAY_API_KEY \
  -u AGY_GATEWAY_MODELS \
  AGY_GATEWAY_URL=http://localhost:4220 \
  AGY_GATEWAY_HEADERS="Authorization: Bearer $LOCAL_BACKPLANE_TOKEN" \
  agy --add-dir "$agy_tmp" \
  -p "Read $agy_tmp/probe.txt with the file reading tool and reply with only its exact marker. Do not modify files or execute shell commands." \
  --model gemini-3.8-flash-low \
  --print-timeout 60s \
  --mode plan
rm -rf "$agy_tmp"
```

The expected response contains `BACKPLANE_TOOL_OK` and the command exits 0.

For this account, `https://daily-cloudcode-pa.googleapis.com` accepted the live
request. The same request to `https://cloudcode-pa.googleapis.com` returned 429;
this observation is account-specific and is not a universal endpoint rule.

## Final acceptance evidence

All eight acceptance groups above passed local verification on 2026-09-23.
The final state retains both coordinator takeovers and the recorded worker repair
counters; no acceptance requirement was dropped.

| Area | Evidence |
| --- | --- |
| Pure protocol, bounded observation, fixtures | 125 package tests passed, including late usage, malformed nested values and transport completion after budget exhaustion |
| Native host and existing Gemini behavior | 167 focused LLM tests passed, including all RPCs, alias/revocation checks, scope enforcement, project/header/path/query boundaries, raw responses/SSE, discovery rotation and no retry on 429 |
| Migration | 2 isolated-schema tests passed; old rows preserved, Antigravity auto routes seeded, configured-surface downgrade refused |
| Authorization and metadata | 14 resource tests and 6 metadata-controller tests passed; `llm::manage` advertised and validated |
| Monitoring | 6 existing Antigravity monitor tests passed |
| Admin | 37 provider/log LiveView component tests passed, including real quota objects and unavailable values |
| Static checks | `mix compile --warnings-as-errors`, scoped `mix format --check-formatted`, and `git diff --check` passed |
| Independent package | `bash scripts/verify_ai_protocol_package.sh` passed for both Google and Antigravity consumers, using the actual unpacked artifact and dependency-isolation check |

Final artifact: `tmp/ai-protocol-package.Ni8jCt/backplane_ai_protocol-1.7.0.tar`.
SHA-256: `d88cf787ebecaee692fa4594c08cc6b47a29713023d114c42100a2582209abed`.

The initial combined regression run found an obsolete three-surface seed
assertion; it was updated to require all four exact surfaces, and the final LLM
suite passed all 167 tests. Existing test-support redefinition, form-ID and
sandbox/background-task diagnostics remain; they did not fail the scoped suites.
No production configuration was changed. The in-progress migration was reapplied
only to the test database, and isolated schemas exercised upgrade/downgrade.

The original 2026-09-23 acceptance did not run real subscription/API calls. The
2026-09-24 verification above adds that evidence. Browser E2E, the full umbrella
suite, Credo, Dialyzer, and CI workflows were not run. The existing OAuth E2E
metadata expectation was updated for the new advertised scope, but that E2E test
was not executed.
