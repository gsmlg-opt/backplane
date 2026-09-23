# Google GenAI M1 implementation status — 2026-09-23

Baseline: `8c72c1d66e59ef1f714167a8d006b3cc95608559`, mixed worktree preserved.

M1 implementation is complete for native Gemini Developer API GenerateContent,
SSE generation, countTokens, provider configuration, model discovery/catalog,
observation and admin UI (W0–W3). This does not promise the whole GenAI SDK.
W5 cross-protocol translation and W6 Interactions/Cloud are separate milestones.
Existing W4 codec work is preserved; it is not an M1 prerequisite or a newly
validated deliverable in this continuation.

The user explicitly deferred all E2E and Gemini API-key testing. No live Google
request, SDK-to-Backplane listener test, or browser E2E ran in this continuation.
The original [acceptance matrix](backplane-google-genai-implement-plan.md#11-必须覆盖的验收矩阵)
remains unchanged. Implementation completion is not release acceptance: deferred
listener, SDK and live-provider checks must still pass before release.

## Implemented boundaries

- `/v1beta/models` list/get and allowlisted native operations; single-segment
  aliases and normalized upstream model targets; raw generation bodies and
  responses use the existing Relayixir forwarding path without IR translation.
- Google SDK header adapts to Backplane authentication; scoped authorization,
  query-key rejection before endpoint telemetry, client credential stripping,
  trusted API-key injection, and protected header precedence. Native Google
  rejects non-API-key bindings before token resolution.
- Local Google-shaped errors; no new error body after response commitment;
  upstream transport failures remain errors even after HTTP 200 begins.
- Complete Google model pagination, transactional publication, and configuration,
  credential, model and surface generation checks. Late results cannot recreate
  operator-removed surfaces. Failed pages preserve the previous catalog.
- Bounded observation preserves native usage semantics and separates countTokens
  from generation. Admin pages show native protocol, API version, metadata,
  refresh status and usage completeness without inventing advanced capabilities.
- Google surface migration preserves existing data and refuses a rollback that
  would discard configured Google APIs. Legacy presets retain explicit migration
  diagnostics rather than silently changing endpoints or authentication.

## Passing non-E2E evidence

All commands below exited 0. Injected transports and `Req.Test` are component
tests, not evidence of real listener forwarding.

| Checks | Result | Local evidence |
| --- | --- | --- |
| Native/auth/catalog/discovery/provider/resolver/metadata/observer regression batch | 137 LLM + 13 protocol tests passed | `/tmp/genai-coordinator-final.out` |
| Isolated migration up/down/refusal | 3 passed, included in the same batch | same log |
| Relayixir committed-response callback boundary | 1 passed, included in the same batch | same log |
| Admin provider/log + access-event/usage-accumulator regression | 38 admin + 27 LLM passed | `/tmp/genai-admin-observation-final.out` |
| Final API-key-only correction with credential, router and discovery regression | 25 passed | `/tmp/genai-credential-green.out` |
| Warnings-as-errors compilation | passed | `/tmp/genai-final-gate-0.out` |
| Scoped formatting | 47 files passed; final credential implementation/test also passed | `/tmp/genai-format.out`, `/tmp/genai-final-gate-1.out` |
| Diff whitespace check | passed | `/tmp/genai-final-gate-2.out` |

The main regression batch used:

```sh
mix test \
  apps/backplane_llama/test/backplane/llm/google \
  apps/backplane_llama/test/backplane/llm/google_observer_integration_test.exs \
  apps/backplane_llama/test/backplane/llm/credential_plug_test.exs \
  apps/backplane_llama/test/backplane/llm/resource_authorization_test.exs \
  apps/backplane_llama/test/backplane/llm/model_metadata_test.exs \
  apps/backplane_llama/test/backplane/llm/protocol_route_test.exs \
  apps/backplane_llama/test/backplane/llm/provider_test.exs \
  apps/backplane_llama/test/backplane/llm/provider_preset_test.exs \
  apps/backplane_llama/test/backplane/llm/model_discovery_test.exs \
  apps/backplane_llama/test/backplane/llm/model_resolver_test.exs \
  apps/backplane_ai_protocol/test/backplane/google_generate_content_observer_test.exs \
  apps/backplane_system/test/backplane/repo/migrations/expand_llm_google_api_surface_test.exs \
  apps/relayixir/test/relayixir/proxy/http_plug_error_callback_test.exs
```

W0 independent response provenance is now a sanitized official js-genai v2.24.0
recording with immutable source, original hash and explicit redactions; see
[fixture provenance](../../integrations/google-genai/fixtures/official/PROVENANCE.md).
Earlier SDK recording-server tests and desktop observations are historical
evidence, not rerun results; see [repair handoff](google-genai-repair-handoff.md).

## Deferred and not run

Real listener forwarding, SDK-to-Backplane pagination, byte preservation over the
actual transport, disconnect cleanup/slow clients, and live Gemini smoke remain
deferred. No E2E acceptance item is marked passing based on injected transports.
Full umbrella tests, strict Credo, Dialyzer and the CI workflow check were not run.
Test output still contains existing MCP support warnings and asynchronous Vault
sandbox teardown warnings; the selected suites nevertheless passed.

At implementation handoff, no commit or push had been requested or performed.
Agent Note was not written because
`.agents/current.md` is absent, so configured project resolution is unavailable.

## Subsequent commit-and-push validation

The user subsequently requested scoped commits and push. Remote `main` was
fast-forwarded from the implementation baseline to `f6961866` before committing;
the three incoming agent-runtime commits did not overlap the Google changes.
The previously preserved W4 changes were additionally checked: all 110 AI
protocol tests passed, and `scripts/verify_ai_protocol_package.sh` passed its
independent packaged-consumer test, warnings-as-errors compilation and dependency
isolation checks. This local package validation does not exercise HTTP listeners,
Google services or API keys. The E2E deferral remains unchanged.
