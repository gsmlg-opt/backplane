# API Usage Monitor Implementation Plan

> **For agentic workers:** Use subagent-driven-development for disjoint provider
> and UI tasks, with local persistence/runtime implementation and final review.

**Goal:** Add vaulted OpenRouter/DeepSeek account monitoring under System → Monitor.

**Architecture:** Separate API-account persistence and cached asynchronous polling
in `backplane_monitor`, using the existing vault and TaskSupervisor. A DuskMoon
LiveView owns management/presentation without changing subscription Plans.

**Tech Stack:** Elixir/OTP, Ecto/PostgreSQL, Req/Req.Test, Phoenix LiveView, DuskMoon.

## Shared Interfaces

```elixir
Backplane.Monitor.ApiAccount.providers() # ["openrouter", "deepseek"]
Backplane.Monitor.ApiAccounts.list_accounts()
Backplane.Monitor.ApiAccounts.get_account(id)
Backplane.Monitor.ApiAccounts.change_account(account, attrs)
Backplane.Monitor.ApiAccounts.create_account(attrs)
Backplane.Monitor.ApiAccounts.update_account(account, attrs)
Backplane.Monitor.ApiAccounts.delete_account(account)
Backplane.Monitor.ApiAccounts.credential_options() # safe credential metadata
Backplane.Monitor.ApiAccounts.list_states()
Backplane.Monitor.ApiAccounts.refresh_account(id) # :ok, asynchronous
Backplane.Monitor.ApiAccounts.refresh_all() # :ok, asynchronous
Backplane.Monitor.ApiUsageFetcher.fetch_usage(account) # {:ok, data} | {:error, safe_reason}
```

Snapshot shape:
```elixir
%{account: account, usage: nil, error: nil, fetched_at: nil,
  last_success_at: nil, refreshing: false}
```

Normalized provider result:
```elixir
%{balances: [%{currency: "USD", total_balance: "10.00",
              granted_balance: nil, topped_up_balance: nil}],
  usage: [%{label: "Key usage (all time)", amount: "2.00", currency: "USD"}],
  limit: nil, is_available: nil, warnings: []}
```

## Task 1: Persistence And Runtime (Local)

Files: `apps/backplane_monitor/lib/backplane/monitor/api_account.ex`,
`api_accounts.ex`, `api_usage_server.ex`,
`apps/backplane_monitor/lib/backplane_monitor/application.ex`,
`apps/backplane_system/priv/repo/migrations/20260917000000_create_monitor_api_accounts.exs`.

- [x] Add failing `api_account_test.exs`, `api_accounts_test.exs`, and
  `api_usage_server_test.exs` under `apps/backplane_monitor/test/backplane/monitor/`.
- [x] Verify missing modules fail, then add the schema/migration and context.
- [x] Validate provider, unique name, eligible credential references, optional
  management-key applicability, and server-side secret type checks.
- [x] Implement periodic supervised asynchronous refresh, non-overlap,
  last-success retention, and invalidation after edits/deletion/pause.
- [x] Register the server after the existing TaskSupervisor; keep startup safe
  for database migration commands by deferring database reads to polling/context.
- [x] Run scoped monitor tests and warnings-as-errors compilation.

## Task 2: Provider Adapters (Parallel Worker)

Files: `apps/backplane_monitor/lib/backplane/monitor/api_usage_fetcher.ex`,
`providers/openrouter.ex`, `providers/deepseek.ex`; corresponding new provider
and fetcher tests under `apps/backplane_monitor/test/backplane/monitor/`.

- [x] Add Req.Test regressions first and observe failures before implementation.
- [x] Validate/resolve API-key credential names at polling time; expose no secrets
  or remote response bodies in errors. Use fixed HTTPS endpoints and bounded
  timeouts, no redirect forwarding of bearer headers.
- [x] Parse key usage and optional account credits independently for OpenRouter;
  normalize numeric fields to decimal strings and label account/key scope.
- [x] Parse DeepSeek currency balances; leave usage absent and honor availability.
- [x] Cover success, unavailable optional credits, missing/malformed numeric fields,
  HTTP/network failure, bearer header injection, and secret non-disclosure.

## Task 3: Admin UI (Parallel Worker)

Files: `apps/backplane_admin/lib/backplane/admin/live/api_usage_live.ex`,
`components/layouts.ex`, `router.ex`,
`apps/backplane_admin/test/backplane/admin/live/api_usage_live_test.exs`.

- [x] Add failing route/menu/CRUD LiveView regressions using the shared interfaces.
- [x] Add API Usage beside Plan Usage under Monitor, with index/new/edit routes.
- [x] Add vaulted credential forms, optional OpenRouter management credential,
  provider cards, pause/delete, and asynchronous refresh controls.
- [x] Display unsupported usage/balances explicitly, preserve decimal/currency
  information, render stale success plus error, and audit only action/entity ID.
- [x] Run only the new LiveView tests and existing touched menu/plan UI tests.

## Task 4: Integration And Verification (Local)

- [x] Review both patches for approved behavior, security, and code quality.
- [x] Format only changed Elixir files, run new scoped monitor/admin tests and
  adjacent existing Monitor tests, and `git diff --check`.
- [x] Document API Usage in README and save an agent note labeled `project: backplane`.
- [x] Report validation and the production migration requirement; do not commit.

Commands:
```sh
MIX_ENV=test mix ecto.migrate
mix test apps/backplane_monitor/test/backplane/monitor/api_account_test.exs
mix test apps/backplane_monitor/test/backplane/monitor/api_accounts_test.exs
mix test apps/backplane_monitor/test/backplane/monitor/api_usage_server_test.exs
mix test apps/backplane_monitor/test/backplane/monitor/api_usage_fetcher_test.exs
mix test apps/backplane_monitor/test/backplane/monitor/providers/openrouter_test.exs
mix test apps/backplane_monitor/test/backplane/monitor/providers/deepseek_test.exs
mix test apps/backplane_admin/test/backplane/admin/live/api_usage_live_test.exs
mix compile --warnings-as-errors
git diff --check
```

Expected: scoped tests pass, compilation has no warnings, whitespace checks clean.

## Verification Results

- Final scoped suite: 79 monitor tests and 18 admin tests, zero failures.
- Changed-file formatting checks, warnings-as-errors compilation, seven-source-file
  strict Credo, and whitespace checks passed.
- Runtime regression tests failed before fixes, then passed; follow-up runtime
  and provider/UI reviews found no remaining concrete issues.
- Test output includes a sandbox/Vault owner-exit cleanup log and existing Plan
  Usage missing-form-ID warnings; unrelated code was not changed.
- Isolated test-endpoint HTTP smoke returned 200 for index/new pages. Browser
  visual verification was unavailable; no live provider requests were made.
- Agent note saved with `project: backplane` (ID
  `a0195aa3-f6b1-4763-9c15-cfcb62d8ebce`).
- Test database migration completed. Development/production still require
  `mix ecto.migrate` before starting the upgraded app. No commit/push performed.
