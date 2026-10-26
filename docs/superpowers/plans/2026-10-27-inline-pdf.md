# Inline PDF Implementation Plan

> **For agentic workers:** Execute this approved plan inline, task by task, using writing-plans and test-driven-development. The coordinator owns Git and release delivery; no worker commits or worktrees.

**Goal:** Persist ordered URI-bearing user PDFs and encode their exact bytes as native Anthropic and Google PDF parts under explicit structural limits.

**Architecture:** Keep the existing resource constructor and serialization unchanged. Media revalidation receives caller options, admits the exact PDF subset, and bounds the ordered collection of admitted PDF data maps. Provider helpers preserve actual message context and content order through final encoding.

**Tech Stack:** Elixir, ExUnit, existing Jason, OTP `:httpc`/`:gen_tcp`; no dependencies.

**Scope:** Only the production/test/documentation allowlist in `docs/superpowers/specs/2026-10-27-inline-pdf-design.md`, plus this plan. Baseline `main` at `d153846a8d2a9ce9d5aabbb818f53e553edbb20d`. The specification records user approval; implementation follows that approved contract. Other concurrent changes are outside this worker's ownership.

## File responsibilities

- `apps/backplane_ai_protocol/lib/backplane/ai_protocol/media.ex`: option-aware media preflight/encoding, exact inline PDF mapping, fixed decoded ceiling, aggregate PDF data-map validation.
- `apps/backplane_ai_protocol/lib/backplane/ai_protocol/codec/anthropic.ex`: preserve message context/options for user and tool media.
- `apps/backplane_ai_protocol/lib/backplane/ai_protocol/codec/google.ex`: propagate context/options through contents/message/parts/system helpers, retaining thought-signature positions.
- `apps/backplane_ai_protocol/lib/backplane/ai_protocol/codec/openai.ex` and `openai_responses.ex`: only preflight option propagation.
- `apps/backplane_ai_protocol/test/backplane/inline_pdf_test.exs`: canonical reload, independent native fixture comparisons, limits/error matrix, loopback body acceptance.
- `apps/backplane_ai_protocol/test/backplane/media_content_test.exs`: regression checks for raised/smaller caller media limits and unchanged mappings.
- `apps/backplane_ai_protocol/test/fixtures/pdf/{first,second}.pdf`: locally authored finite distinct documents.
- `apps/backplane_ai_protocol/test/fixtures/{anthropic,google_genai}/inline_pdf_user.json` and adjacent `PROVENANCE.md`: independently authored native request expectations and schema provenance.
- `apps/backplane_ai_protocol/{README.md,SOURCE_NOTES.md}` and `lib/backplane/ai_protocol/{codec,content_block}.ex`: precise public contract documentation only.

## Task 1: Establish failing functional coverage

- [x] Author two one-page PDFs with explicit object offsets/xref/trailer and distinct text; author expected JSON directly from the official native schemas, independently of Elixir encoders. Record source versions/dates in provenance.
- [x] Add `InlinePdfTest` with public `ContentBlock.new/2`, `Message.new/2`, `Request.new/2`, `Serialization.to_json/1` and `decode_and_validate/3` reconstruction. Fixed role/status maps avoid arbitrary atom creation. Assert full reconstructed request equality, exact source identities and ordered content.
- [x] Compare full Anthropic output and Google REST body to the independently authored fixtures; compare Google compatibility envelope after adding model/stream only. Decode each native PDF base64 and compare original file bytes.
- [x] Add >262144-byte string, 10 MiB and 10 MiB+1 decoded cases, invalid/empty base64, omitted/smaller codec/reload options, aggregate bytes/list/depth/nodes/map limits, and block/message metadata/role/protocol rejection cases.
- [x] Add OTP loopback tests for `POST /v1/messages` and `/v1beta/models/fixture-model:generateContent`, checking Content-Length, complete serialized body and parsed native order.
- [x] Run red: `python /tmp/backplane-1.10.43-internal-EYMX5h/pdf-implementation/run-ai-check.py pdf-red test test/backplane/inline_pdf_test.exs`. Expect unsupported-media failures from current code, retaining exact logs and exit code.

Core expected mapping:

```elixir
%{"type" => "document", "source" => %{"type" => "base64", "media_type" => "application/pdf", "data" => original}}
%{"inlineData" => %{"mimeType" => "application/pdf", "data" => original}}
```

## Task 2: Implement the narrow media contract

- [x] Preserve wrappers `preflight/2`, `encode/2`, `encode/3`; add option-aware `preflight/3` and `encode/4`. Revalidate with `ContentBlock.new(block, opts)` before subset checks.
- [x] Require exact resource data keys `uri`, `mime_type`, `data`, exact MIME, empty block/message extensions, user role and Anthropic/Google protocol. Require decoded bytes in `1..10_485_760`; preserve original base64 and omit canonical-only URI in native output. Keep existing URL PDFs, Google references and audio branches intact.
- [x] Collect admitted data maps only after successful per-block checks and apply the existing bounded portable term validator once:

```elixir
Validation.term(inline_pdf_data_maps, Keyword.get(opts, :limits, %{}))
```

- [x] Pass original opts into all four media preflight calls. Route Anthropic media through message-aware final helpers, including tool results. Route Google media through context/opts-aware parts and system helpers; leave thought-signature position logic unchanged.
- [x] Run green: `python /tmp/backplane-1.10.43-internal-EYMX5h/pdf-implementation/run-ai-check.py pdf-green test test/backplane/inline_pdf_test.exs test/backplane/media_content_test.exs`. Expect zero failures. Diagnose before a repair; record cumulative repair rounds (maximum two unsuccessful rounds).

## Task 3: Document and verify the integrated contract

- [x] Document the URI identity exception, exact metadata subset, roles/protocols, fixed decoded ceiling, aggregate-only PDF accounting and unchanged defaults.
- [x] Document larger limits at construction, JSON decoded validation/reconstruction, encoded reload and encoding; show 32 MiB profile and host-owned complete-body limits. State `to_json/1` does not enforce encoded size.
- [x] Run explicitly scoped format checks for changed Elixir files and warnings-as-errors compile in the owning app; run the owning AI protocol test files explicitly (no unrelated umbrella tests).
- [x] Inspect the final scoped diff against all seven acceptance criteria, record actual commands/results and ensure worker commands finished. Return implementation/fixture/loopback evidence and provider acceptance limitations to the coordinator. Parent performs release acceptance separately.

## Verification execution

The AI-specific runner uses cwd `apps/backplane_ai_protocol`, `MIX_ENV=test`, `ERL_FLAGS='+S 4:4'`, and `flock /tmp/backplane-ir43-beam.lock` for every Mix command. Logs and result JSON live under `/tmp/backplane-1.10.43-internal-EYMX5h/pdf-implementation`. It captures flushed PTY output without `unbuffer`; no global packages are installed.

## Plan self-review

- Spec coverage: tasks 1–2 cover exact subset, persistence/order, both Google APIs, metadata/roles, 10 MiB ceiling, aggregate structural limits and option propagation; task 1 covers loopback composition; task 3 covers unchanged media/docs/provider limits.
- Placeholder scan: no unresolved steps or missing file ownership. Production signatures match the approved added arities; the constructor/serialization/Validation/dependency contracts remain unchanged.
- Authorization: inline execution already requested; no additional design gate. Parent owns commit/push/release and shared Agent Note writes.

## Actual verification and limits

- Behavioral red: `pdf-red` — 11 tests, 9 expected failures on absent mappings/options. One initial test syntax setup error was corrected before this behavioral red result.
- First implementation green: `pdf-green` — 29 tests, 0 failures.
- Compatibility expansion: a new OpenAI audio expectation exceeded the approved preflight-only scope. Source inspection showed its existing final `Media.encode/2` default wrapper; the regression now characterizes that unchanged behavior and targets raised final limits only for Google audio and Anthropic tool PDF references. One test-only repair round passed (`pdf-compatibility-repair1`: 31 tests, 0 failures); no production repair was needed.
- Owning app suite: `pdf-suite` — all 13 explicit AI protocol test files, 191 tests, 0 failures, including thought-signature/media/image regressions.
- `pdf-compile`: warnings-as-errors compile passed. `pdf-format-check`: all nine changed Elixir files passed. Scoped `git diff --check` passed.
- Independently authored fixture PDF headers/xref/object offsets/stream lengths/EOF passed structural checks. Refreshed official source snapshots and hashes are recorded in fixture provenance.
- Logs, exact argv/cwd/exit/duration records and summary: `/tmp/backplane-1.10.43-internal-EYMX5h/pdf-implementation`.
- Scope review confirms constructor/Serialization/Validation/dependencies unchanged, documentation-only edits in Codec/ContentBlock, and preflight-only edits in both OpenAI codecs.
- No authenticated provider call, release publication or downstream dependency acceptance was performed by this worker. Parent owns release acceptance. All worker commands finished; no temporary service persists.
