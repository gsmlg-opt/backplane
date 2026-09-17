# API Usage Dashboard And Configuration Implementation Plan

> **For agentic workers:** Use executing-plans to implement the scoped tasks.

**Goal:** Separate API-account configuration from dashboard figures and provide
a persistent global API-fetch switch.

**Architecture:** Reuse ApiAccounts and ApiUsageServer snapshots. Keep table
reads independent of the cache, and enforce Settings policy at every fetch entry
point plus cancellation on Settings changes. Use existing DuskMoon/LiveView UI.

**Tech Stack:** Elixir/OTP, Phoenix LiveView, Ecto, Settings PubSub, DuskMoon.

## Task 1: Runtime Policy (Main)

Files: `apps/backplane_monitor/lib/backplane/monitor/api_accounts.ex`,
`api_usage_server.ex`, corresponding monitor tests,
`apps/backplane_system/lib/backplane/settings.ex`.

- [x] Write regressions for disabled initial sync/manual/periodic/definition
  refresh, in-flight cancellation with cached-success retention, and re-enable.
  Run `mix test apps/backplane_monitor/test/backplane/monitor/api_usage_server_test.exs`
  and observe failures before implementation.
- [x] Add boolean default `monitor.api_usage.enabled = true`; expose
  `ApiAccounts.fetching_enabled?/0` and `set_fetching_enabled(boolean)/1` returning
  `:ok | {:error, reason}` using Settings plus serialized runtime acknowledgement.
- [x] Subscribe the runtime to Settings changes; prevent starts while disabled,
  cancel active requests and retain success, reconcile/refresh on re-enable.
- [x] Run focused runtime/context tests and warnings-as-errors compilation.

## Task 2: Configuration And Dashboard UI (Worker)

Files: `apps/backplane_admin/lib/backplane/admin/live/api_usage_live.ex`, new
`dashboard_api_usage_live.ex`, their corresponding LiveView tests.

- [x] Add failing tests for figures absent from config but present on dashboard,
  no cache reads on config visits, and disabled dashboard controls/banner.
- [x] Change config assigns to account records from `ApiAccounts.list_accounts/0`;
  retain forms/audits and use a DuskMoon table matching Plan Usage.
- [x] Move existing provider cards/safe presentation to DashboardApiUsageLive;
  set current_path `/dashboard/usage/api`, subscribe to Settings changes, use
  existing async refresh and 5s/30s cache reload cadence.
- [x] Run only new/touched LiveView tests after main adds routes.

## Task 3: System Config UI (Worker)

Files: new `apps/backplane_admin/lib/backplane/admin/live/system_config_live.ex`
and corresponding `system_config_live_test.exs`.

- [x] Write regressions for default/persisted toggle, live setting changes,
  and the global scope independent of per-account activation.
- [x] Render a DuskMoon boolean control labeled API information fetching,
  call the approved context setter, show safe errors, use existing audit style,
  and link to API-account configuration and usage dashboard.
- [x] Run only System Config tests after routes/context are available.

## Task 4: Navigation, Docs And Integration (Main)

Files: `apps/backplane_admin/lib/backplane/admin/router.ex`,
`components/layouts.ex`, `AGENTS.md`, `README.md`, this plan/design.

- [x] Add `/dashboard/usage/api` and `/system/config` routes, Dashboard API Usage
  next to Plan Usage, and System Config navigation.
- [x] Review worker patches and runtime gating; format changed files only.
- [x] Run `mix test apps/backplane_monitor/test` plus exact API Usage/config and
  adjacent Plan Usage LiveView tests; run changed-source Credo, formatting check,
  warnings-as-errors compile and `git diff --check`.
- [x] Document new page responsibilities/switch, save project-labeled agent note,
  report verified results and restart requirement. Do not commit/push.

## Final Evidence

- Final scoped `mix test --warnings-as-errors --seed 0`: 86 Monitor + 11 Settings
  + 40 admin tests, zero failures. Randomized scoped integration also passed.
- Changed-file formatting check, warnings-as-errors compilation, strict Credo
  on 13 source files and whitespace checks passed.
- Re-enable rejects cached/stale definitions until a successful fresh read;
  both review findings were reproduced before fixes and covered by regressions.
- Runtime and UI follow-up reviews found no remaining concrete issues.
- Output includes sandbox/Vault owner-exit cleanup logging and existing Plan
  Usage missing-form-ID warnings. No unrelated fixes, live provider requests,
  browser visual verification or whole-umbrella test runs were performed.
- Saved project agent note `e13164ba-e4d2-4790-90ad-12a5b52ced5b`.
- No new migration for this setting. Fully restart the app to initialize the
  updated cache state; no commit/push performed.
