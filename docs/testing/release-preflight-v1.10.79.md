# v1.10.79 release preflight — 2026-11-18

This is the historical preflight for the v1.10.79 candidate based on `5e412d32bd9cafed23ae66206bd7de6b50228147`. At the time of this preflight, the test requirement was unmet and the candidate was left uncommitted and unpublished. The results below apply to that checkout at the time of testing.

## Checks performed

| Check | Result |
| --- | --- |
| Previous two-pass OpenAI qualification | All 15 configured operation types have two successful checks; Responses and Realtime WS use rc.19 HTTP/1 over CONNECT |
| Previous focused WS regressions | 45 tests, 0 failures |
| Warnings-as-errors compile of current implementation | Passed before this preflight; source unchanged during preflight |
| Full `mix format --check-formatted` | Passed |
| CI/release/Hex dependency/workflow split contracts | 67 tests, 0 failures |
| `mix credo --strict` | No issues in 2,037 source files |
| Relayixir app suite | 284 tests, 0 failures |
| Llama app suite | 738 tests, 1 failure |
| Admin app suite | 411 tests, 2 failures |
| Isolated Skill Protocol lifecycle and Google observer files | 19 tests, 0 failures; this does not erase failures in their broader runs |
| Default full umbrella suite | Did not pass; interrupted after failures and repeated Agent Runtime timeouts |

The owner-app command was `devenv shell --no-tui -- mix test apps/backplane_llama/test apps/backplane_admin/test apps/relayixir/test`. Its 1,433 tests had three failures. No tests were excluded or weakened to obtain a passing release gate.

## Unresolved failures

1. `apps/backplane_admin/test/backplane/admin/live/host_services_live_test.exs:93`: the existing Host Service Provider creation test submits conversation enablement controls removed from Providers by the approved separation. Its intended coverage needs to follow Provider creation and the independent LLM configuration step. It currently fails before submission because those controls no longer exist.
2. `apps/backplane_admin/test/backplane/admin/live/host_services_live_test.exs:141`: the Host Embeddings creation button and form no longer exist on the delegated Embeddings page. Retaining legacy records in a read-only inventory does not preserve this creation workflow. This is an unresolved compatibility gap, not a passing test or an account problem.
3. `apps/backplane_llama/test/backplane/llm/google_observer_integration_test.exs:114`: the owner-app run lacked `snapshot.metadata.operation` for countTokens. The whole file passed in an isolated follow-up; the broader-run failure remains recorded and its cause is unconfirmed.
4. `apps/backplane_skill_protocol/test/backplane/skill_protocol/fetch_lifecycle_test.exs:92`: the default umbrella run failed in the on-exit cleanup waiting for a monitored process's DOWN message. The whole lifecycle file subsequently passed in isolation. Its cleanup monitor is created by the test process and consumed from an on-exit callback; no outside-scope test modification was made.
5. The default umbrella run reached at least nine Agent Runtime failures, including a finite-root cancellation assertion, unavailable Code Mode backends and 60-second Code Mode timeouts. The devenv shell confirms `DENO_NOT_INSTALLED`; the dedicated Agent Runtime workflow installs Deno 2.8.3. Missing Deno explains the unavailable-backend precondition, but the other failures have not all been attributed to that cause. The run was interrupted after further timeouts and database sandbox ownership timeouts, so no complete umbrella result is claimed.

Raw local logs are `/tmp/backplane-patch-full-tests.log`, `/tmp/backplane-patch-owner-tests.log`, `/tmp/backplane-patch-isolated-failures.log`, `/tmp/backplane-patch-contracts.log`, `/tmp/backplane-patch-format.log` and `/tmp/backplane-patch-credo.log`. This report contains only sanitized failure summaries. No new paid OpenAI calls were made during the release preflight.

The target version/tag was checked as free, but no public artifacts were created. Dialyzer, production assets, hosted CI and publication were not run for this candidate. Gateway and PostgreSQL remain available for local investigation. Before releasing, resolve the Host Service workflow coverage/compatibility gap and remaining broader-suite failures, then repeat the affected checks without weakening assertions.
