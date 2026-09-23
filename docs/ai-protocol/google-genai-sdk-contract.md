# Google GenAI SDK Contract Baseline

Baseline: Backplane `8c72c1d66e59ef1f714167a8d006b3cc95608559`, recorded 2026-09-23. The historical W0 handoff was **BLOCKED_IMPLEMENTATION**; see the coordinator repair results below. No paid requests or production dependency changes were made.

## M1 continuation boundary

The user explicitly deferred all E2E and Gemini API-key testing. The existing
loopback SDK results below are historical passing evidence; this continuation
must not claim a new SDK-to-Backplane or live Google verification.

The independent official response fixture is now available as
`fixtures/official/generate-content-recorded-response.json`, sourced from the
pinned official TypeScript SDK system-test recording. The provenance file records
its immutable commit, original source hash, JSON extraction path and exact
sanitization. The original synthetic fixture is retained and clearly distinguished.

## Coordinator repair, 2026-09-23

The user explicitly authorized coordinator takeover. Historical counters remain
`initial_worker=terra_worker`, `sol_escalated=true`, `sol_repair_rounds=2/2`;
`current_worker=coordinator`. No worker is still writing.

Current checks pass: `npm run test:typescript`, `npm run test:python`,
`go test -count=1 ./test/go`, and `npx tsc --noEmit`.
All three pinned SDKs made five loopback requests and matched the complete
method/path/query/body expectations. `fixtures/requests/*.captured.json` are now
exported directly from those executed recording servers, without credentials.
The original `*.json` expectation files remain independently authored assertions.

Repairs: the TypeScript path check now accepts both `/models` and `/models/...`;
the request reader uses Node's `IncomingMessage`; Python uses unittest discovery
to avoid collision with the standard-library `test` package; Go dependency
checksums are recorded in `go.sum` with the original SDK version unchanged.

The official REST reference was retrieved successfully and its response and usage
JSON representations were extracted into `fixtures/official/generate-content-schema.txt`.
The original response sample remains synthetic. A separate sanitized official SDK
system-recording response was added during M1 completion; see
`fixtures/official/PROVENANCE.md` for exact sources and evidence limitations.

Verified subset: deployment prefix `/deploy`, explicit `v1beta`, full
`models/gemini-2.5-flash` name, API-key header, generate, SSE (two events without
`[DONE]`), countTokens, single-page list and get. Pagination, bare-name normalization,
SDK-to-Backplane forwarding, and live Google smoke remain unverified/skipped.
No paid request was made. The W2 listener implementation is still separate work.

The remaining sections preserve the prior stopped handoff as historical evidence;
their failures and restrictions describe the pre-takeover state, not the current
loopback test results.

## Historical fixed clients

| SDK | Exact version | Source inspected | Local recording result |
| --- | --- | --- | --- |
| TypeScript `@google/genai` | `2.24.0` | Installed npm artifact declarations and implementation; repository tag not independently verified | Failed after five local requests |
| Python `google-genai` | `2.25.0` | Registry listing, successful local installation and imported version; no completed source/contract verification | Test module import failed; SDK calls and assertions not run |
| Go `google.golang.org/genai` | `v1.71.0` | Downloaded Go module artifact and source signatures | Missing checksum entry; harness did not compile or run |

The harnesses are intended to exercise loopback servers with `/deploy`, `v1beta`, `models/gemini-2.5-flash`, generate, SSE generate, countTokens, models list and get. Only TypeScript executed these calls. The three JSON files under `integrations/google-genai/fixtures/requests/` were manually authored as expected requests, not exported from recordings. They remain untracked at handoff, not committed. TypeScript recorded requests in memory but failed before comparing them with its fixture; Python and Go captured no requests. These fixtures must not be represented as independently SDK-generated evidence.

## Partial observations and unverified expectations

In the last TypeScript run, generate returned the asserted text, SSE iteration returned two synthetic events without `[DONE]` (including the asserted final usage total of 6), countTokens returned 3, and list/get returned the asserted model name. The in-memory recording count was five. The header, no-query-key and path-prefix assertions passed for the first three recordings. For the fourth (list), header and no-query-key assertions passed, then the path assertion rejected the actual `/deploy/v1beta/models` because the regex incorrectly required a trailing slash. The fifth recording's header/path assertions and the complete method/path/query/body fixture comparison were never reached.

TypeScript's installed declarations and executed async iteration establish that `models.list()` returns a pager rather than an indexable array. Inspected Go source declares `Page[Model]`; its runtime behavior was not tested. Python pager behavior was not verified. Multi-page listing, exact full request bodies/targets, bare model-name normalization, and all Python/Go wire behavior remain unverified by these runs. Planned contract coverage is not passing evidence.

The response fixture is manually authored synthetic data. `integrations/google-genai/fixtures/official/PROVENANCE.md` records the provenance limitation: no successful official-document retrieval or official response capture was established. The harnesses embed synthetic responses rather than reading that JSON file.

## Backplane boundary

Only partial `TypeScript SDK -> local recording server` behavior was observed; no SDK has a passing full contract check. No `SDK -> Backplane -> Google` check ran. The supplied baseline entry trace is `Backplane.Api.Endpoint -> Backplane.LLM.ProxyPlug -> LLM Router`, with ProxyPlug before parsers and recognizing only `/v1` at that baseline. W1 owns provider base URL configuration for `/v1beta`; its completion does not establish W0 listener compatibility. SDK-to-Backplane was not run. Live Google requests were intentionally skipped: no credential or paid smoke was authorized.

## Last commands and actual outcomes

Commands below ran from `integrations/google-genai` unless noted. They are evidence, not a verified reproduction recipe or authorization to rerun.

| Command | Actual outcome |
| --- | --- |
| `npm run test:typescript` (round 1) | Exit 1: expected `/^genai-js\//`, actual `'google-genai-sdk/2.24.0 gl-node/v24.11.1'` at test line 121. Pager repair allowed execution to reach this assertion. |
| `npm run test:typescript` (round 2, last run) | Exit 1: `AssertionError [ERR_ASSERTION]: The input did not match the regular expression /^\/deploy\/v1beta\/models\//. Input:` followed by `'/deploy/v1beta/models'`, at test line 124. |
| `npm run test:python` (runs `.venv/bin/python -m unittest test/python_contract_test.py`) | Exit 1: `ImportError: Failed to import test module: python_contract_test`; `ModuleNotFoundError: No module named 'test.python_contract_test'`. No contract assertion executed. Import resolution cause was not investigated further. |
| `go test ./test/go` | Exit 1: `test/go/contract_test.go:13:2: missing go.sum entry for module providing package google.golang.org/genai (imported by backplane.local/google-genai-contract/test/go); to add:` followed by `go get -t backplane.local/google-genai-contract/test/go`. Setup failed before compilation/assertions. |
| `npx tsc --noEmit && git diff --check -- integrations/google-genai docs/ai-protocol/google-genai-sdk-contract.md` | Interrupted with Ctrl-C; no compiler result recorded. The chained diff check is not a passing check. |
| `git diff --check -- integrations/google-genai docs/ai-protocol/google-genai-sdk-contract.md` (repository root, before correction) | Exit 0, but W0 files were untracked and thus not covered by the ordinary tracked diff. Not harness acceptance evidence. |

Version/setup evidence: `python3 -m pip index versions google-genai` listed `2.25.0`; `GOPROXY=https://proxy.golang.org go list -m -versions google.golang.org/genai` listed `v1.71.0`; `GOPROXY=https://proxy.golang.org go mod download -json google.golang.org/genai@v1.71.0` succeeded and reported module sum `h1:Wfo9n0uSzMhZH7d+rP7QxxSWELEDSD4z6O8W/C9s3oM=`. This did not populate the harness's missing `go.sum`. The Python 3.12 command `python3.12 -m venv --clear .venv && .venv/bin/pip install 'google-genai==2.25.0' && .venv/bin/python -c 'import google.genai; print(google.genai.__version__)'` finished successfully and printed `2.25.0`; installation is not a contract-test pass. Earlier Python 3.14 installation attempts do not establish contract behavior. TypeScript pin evidence is the installed npm artifact; no independent npm registry/tag verification was recorded in this escalation.

## Stopped task record

- Task `W0`; escalated assignment; `initial_worker=terra_worker`, `current_worker=sol_worker`, `sol_escalated=true`, `sol_repair_rounds=2/2`.
- Status: **BLOCKED_IMPLEMENTATION**. No further implementation or test execution is authorized. This documentation-only factual correction does not reset or extend the counter.
- Prior commands were reported stopped at handoff. No commits, pushes, production dependency changes or paid requests were made. Implementation/harness files and other workers' changes are preserved.
- Required decision: the coordinating parent must explicitly authorize reopening or another disposition before any harness repair/validation. Outstanding work includes assertion/runner corrections, Go dependency checksums, actual captured request fixtures, verified official response provenance, and passing acceptance checks. W4 owns all Mix validation; no Mix command is part of this correction.
