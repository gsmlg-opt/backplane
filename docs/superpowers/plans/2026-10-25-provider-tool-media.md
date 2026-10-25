# Native PDF Tool-Result Media Implementation Plan

> **For agentic workers:** Use subagent-driven-development or executing-plans to implement these bounded tasks. The coordinator owns Git mutations, shared BEAM verification, and release delivery.

**Goal:** Deliver the approved #108 Anthropic PDF URL resource/link subset, together with #106/#107 and the approved Memory fixture cleanup, in 1.10.38.

**Architecture:** Keep canonical media validation and persistence intact. Use the same context-aware compatibility rules in preflight and native tool-result encoding; reuse the Anthropic envelope and retain explicit errors elsewhere.

**Tech Stack:** Elixir/OTP, existing AI Protocol codecs and Jason, ExUnit, existing release workflows. No new dependency or lockfile changes.

---

## Task 1: Functional red cases and native fixture

**Files:** `apps/backplane_ai_protocol/test/backplane/media_content_test.exs`, a native JSON fixture under `apps/backplane_ai_protocol/test/fixtures/anthropic/`.

- [x] Add canonical JSON-reload cases for both exact PDF forms and both tool statuses. Preserve mixed text/image/document order and canonical input identity.
- [x] Use this exact successful native mapping as an independently authored fixture derived from the official Anthropic schema, with its provenance recorded:

```elixir
%{"type" => "tool_result", "tool_use_id" => "call-pdf", "is_error" => false,
  "content" => [
    %{"type" => "document", "source" => %{"type" => "url", "url" => "https://example.invalid/document.pdf"}},
    %{"type" => "document", "title" => "Reference", "source" => %{"type" => "url", "url" => "https://example.invalid/link.pdf"}}
  ]}
```

- [x] Test new media with message/block extensions, inline data/text, extra link fields, other MIME types/schemes, other roles/protocols, and audio. Require typed incompatibility before submission, without changing canonical data.
- [x] Run `mix test apps/backplane_ai_protocol/test/backplane/media_content_test.exs`; verify new supported-form tests fail because the current codec rejects them.

## Task 2: Shared compatibility and Anthropic mapping

**Files:** `apps/backplane_ai_protocol/lib/backplane/ai_protocol/media.ex`, `apps/backplane_ai_protocol/lib/backplane/ai_protocol/codec/anthropic.ex`.

- [x] Add an internal role-aware media path used by both preflight and Anthropic tool-result encoding. Existing two-argument media behavior stays compatible.
- [x] Admit only tool-role HTTPS `application/pdf` resource maps with exactly `uri`/`mime_type`, or link maps with exactly `uri`/`mime_type`/`name`; require empty block/message extensions.
- [x] Emit native URL documents, mapping the exact link name to document title. Preserve the existing envelope's call ID, effect status, and block order. Unsupported forms return the existing typed incompatibility family with `:not_submitted`.
- [x] Run the focused media tests, then `MIX_ENV=test mix do --app backplane_ai_protocol test`. Preserve existing text/image and user-media behavior. Focused: 18 tests; owning suite: 169 tests; zero failures.
- [x] Document the precise subset and limitations in `README.md` and `SOURCE_NOTES.md`; record official source URLs and fixture capture/authoring date without claiming provider execution.

## Task 3: Approved Memory fixture cleanup

**File:** `apps/backplane_memory/test/backplane/memory/workers/summary_worker_concurrency_test.exs`.

- [x] Reproduce the existing fixture leaving three daily rows and three subject contributions in a fresh database; the following retention tests fail two of seven assertions.
- [x] Verify a temporary single-file candidate using a unique fixture host and subject/host-scoped activity deletion leaves zero rows; all seven retention tests then pass in another fresh database. Drop both task-owned databases.
- [x] Apply the reviewed candidate exactly; leave production Memory code and retention assertions unchanged.
- [x] Run the Memory suite in a fresh task-owned test partition with CI's known failing seed `160062` and `--exclude memory_qualification_runtime`; drop that database after the suite exits. Result: 1,448 tests, zero failures, five excluded.

## Task 4: Integrate and release

**Files:** Only approved source/test/docs paths above, existing #106/#107 paths, and already prepared unified 1.10.38 version paths.

- [x] Review the combined diff and run focused checks, strict compilation, changed-file formatting, Credo, release/workflow/Hex dependency contracts, and the Hermes oracle. Serialize all BEAM commands with `/tmp/backplane-ir38-beam.lock` and `ERL_FLAGS='+S 4:4'`. Separate spec-compliance and code-quality reviews passed; canonical CI still supplies whole-repository formatting and Dialyzer.
- [ ] Commit scoped changes and push main. Require CI, Test, Agent Runtime, AI Protocol, and Audio Integration (31 remote jobs) at the exact final SHA. Skill Protocol has no manual dispatch and its paths are unchanged; prove parity with its preceding green run and execute its standalone-package and DB-backed HTTP checks locally at the final SHA. Rebind verifier source literals only after that SHA is final.
- [ ] Verify the version/tag is unused and remote main has not advanced, then dispatch `release.yml` with `version=1.10.38` and `release_apps=all`.
- [ ] Require all 16 release jobs to pass. Independently verify release assets/sidecars/qualification/docs, all five Hex source inventories and HexDocs, image digest/revision, and six archive metadata sets.
- [ ] Use a fresh official Hex-only consumer for native image containment, explicit-empty presentation, and PDF media canonical reload/native wire behavior. A task-local loopback HTTP fixture captures JSON from `Codec.encode_request(:anthropic, request)` without contacting a provider or adding a package dependency. `encode_rest_request/3` remains Google-only.
- [ ] Update #106/#107/#108 with bounded evidence and close only after publication proof. State unsupported audio/media forms and the absence of real provider/model acceptance or deployment verification. Verify final Git/issue convergence and stop.
