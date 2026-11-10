# OpenAI API Proxy Implementation Plan

**Goal:** Deliver native OpenAI non-chat API proxy capabilities with individual configuration menus, and keep MiniMax audio separately named within Llama.

**Architecture:** Existing providers own the endpoint and credential; explicit service rows own capability/model admission and resource limits. HTTP proxy, Realtime transport and administration are disjoint implementation units, integrated and verified by the coordinator.

**Tech Stack:** Elixir/Ecto, Plug/Relayixir, HTTP.WebSocket/Gaoxy, Phoenix LiveView and DuskMoon.

## 1. Service configuration and HTTP (HTTP worker)

- [x] Add `openai/service.ex` and migration `20261110000006_create_llm_openai_services.exs`: kinds, provider association, nonempty allowed models, optional default, independent enablement and bounded limits. Reject unavailable, OAuth and host-linked providers. Resolve qualified/unambiguous configured models and build API-key-only upstream headers.
- [x] Add native HTTP dispatch for Decisions, image JSON/multipart, speech, transcription, Realtime client secrets and WebRTC calls. Preserve repeated multipart fields, native options and response bytes. Integrate authentication before parsing, existing rate limits and safe access metadata. Preserve MiniMax dispatch and its old validation independently.
- [x] Add local-upstream tests for routing, default/ambiguous/disabled models, credentials, upload/binary/SSE preservation, upstream errors and no replay.

## 2. Realtime transport (Realtime worker)

- [x] Add `openai/realtime_websocket.ex` and transport/policy modules. Pin selected service/provider/model, inject server credential, relay native JSON events with bounded queues/frames/lifetime and acknowledgements.
- [x] Register supervision, GET route and invocation scope. Close on owner/upstream loss; never reconnect or replay.
- [x] Add policy/local-socket tests for session configuration, model escape, bidirectional events, revocation, errors and cleanup.

## 3. Capability menus and navigation (coordinator)

- [x] Add `OpenAIProxyLive`: separate live actions for Decisions, Images, TTS, ASR and Realtime, with Add/Edit modal forms, allowed/default models and limits. Create enabled by default; preserve enabled state on edit and toggle through table icon actions. Display provider endpoint and credential reference; audit action/entity/id only.
- [x] Add per-capability entries to the existing Llama sidebar; keep embedding/MiniMax audio there, update internal references and redirect temporary API Proxy addresses. No additional top-level menu.
- [x] Add LiveView CRUD/isolation/validation/navigation/redirect regressions; update existing tests to canonical addresses.

## 4. Integrated qualification (coordinator)

- [x] Serialize `devenv shell --no-tui -- mix test` for new llama tests and relevant existing proxy/audio/embedding suites, then admin tests. Inspect failures before rerunning.
- [x] Format only changed Elixir files and run scoped formatting checks, compile with warnings-as-errors and focused Credo where feasible.
- [x] Review final diff for scope, credential/payload retention, one-shot dispatch, client scope checks and cleanup. Inspect admin pages with a browser when available, and record limitations accurately.
- [x] Write operator documentation and, if supported and useful, one coherent Agent Note implementation review. Leave changes uncommitted as requested by repository policy.

## Qualification evidence (2026-11-10)

- Local upstream/parser/service and existing HTTP routing, authentication, embedding and audio regressions: 99 tests passed. Realtime policy and real local WebSocket transport: 20 tests passed.
- Admin/navigation/audio/embedding/host-service scope: 53 cases exercised. The provider-select tuple bug was corrected and all 9 OpenAI page tests passed on rerun; the remaining 44 cases passed unchanged. The final responsive-layout edit was followed by another 9/9 OpenAI page run.
- Changed Elixir files passed formatting checks; test-environment compilation passed with warnings as errors. Strict Credo reported no issues (its umbrella invocation analyzed 1905 files).
- Browser: connected LiveView; configuration edit/save succeeded; desktop and 390px mobile layout checked, including bounded horizontal table scrolling; Realtime configuration fields and both legacy redirects confirmed. Current navigation had no console warnings/errors. Expected connection-refused messages occurred while restarting only the task-owned test server. Screenshot rendering worked, but the browser tool rejected local screenshot export paths, so no saved screenshot artifact is claimed.
- Tests used a disposable PostgreSQL cluster because the existing development PostgreSQL binary could not load plpgsql during a baseline migration. The existing PostgreSQL process was left running. Existing provider-form missing-ID warnings and test-sandbox/Vault teardown logs were observed without expanding scope.
- No real OpenAI call, account entitlement check, production load test, full-suite run, Dialyzer, release or deployment was performed. WebRTC media, SIP/call management, semantic SSE completion and unavailable token totals remain outside the verified boundary; see `docs/openai-api-proxy.md`.
- Operator documentation is in `docs/openai-api-proxy.md`; the verified implementation review is Agent Note `3d1d10b0-fc6b-437d-8dab-51ccf16976f9` (project `backplane`, revision 2). Changes remain uncommitted.

## Navigation correction (2026-11-11)

User clarified that all API configuration belongs under Llama. Removed the separate API Proxy top-level entry and moved capability paths to `/llama/openai/:kind`; embeddings and MiniMax retain `/llama/embedding` and `/llama/audio`. Temporary `/api-proxy/*` URLs redirect into Llama. Updated navigation regressions and the implementation review to reflect this correction.

Verification: 53 admin tests plus 12 audio access tests passed; changed-file formatting and test-environment warnings-as-errors compilation passed. The running local devenv page shows Llama highlighted, no API Proxy top-level entry, and connected LiveView. All seven capability pages and temporary-address redirects returned HTTP 200.

## Modal form interaction (2026-11-11)

Decisions, Images, Speech, Transcription and Realtime now show an Add button instead of a permanent inline form. Add and Edit render a DuskMoon native dialog; a small LiveView hook opens it in the top layer and forwards native dismissal to the form reset event. Successful saves remove the modal, validation errors retain inputs, and Cancel/close/Escape discard unsaved changes. Focus is restored to the triggering button.

Verification: 15 OpenAI page/navigation tests passed, including all five Add flows, create/edit success, validation retention, cancel/reset and unchanged configuration after cancellation. Browser checks covered all five real modal openings and close buttons, cancel/edit, Escape, invalid submission retention and a scrollable 390px Realtime form. No live provider request or successful mutation of development configuration was used for browser verification. Format checks, test-environment warnings-as-errors compilation and JavaScript syntax checks passed.

## Default enablement and table actions (2026-11-11)

New capability routes default to enabled in the schema and database. Migration `20261111000000_enable_new_openai_services_by_default.exs` changes the database default without changing existing row states. Add/Edit forms omit enabled fields and ignore submitted enabled values; edits retain the current state. The table owns enable/disable, with Edit, Enable/Disable and Delete rendered as icon buttons with accessible labels and tooltips.

Verification: 40 OpenAI service/HTTP/request/Realtime tests and 16 admin/navigation tests passed, including all five capability defaults and preservation of disabled state after editing. Both development and test databases applied the migration. Browser checks confirmed all five Add dialogs omit enabled controls, the Edit dialog omits them too, and all three table actions expose icons, accessible names and tooltip descriptions. Development configurations were not changed during browser checks. Changed-file formatting, test-environment warnings-as-errors compilation and strict Credo passed; existing Vault sandbox teardown warnings remain outside scope.
