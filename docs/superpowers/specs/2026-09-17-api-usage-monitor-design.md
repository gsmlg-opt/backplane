# API Usage Monitor

## Approved Scope

Add **System → Monitor → API Usage** beside Plan Usage. Operators can add, edit,
pause, refresh, and delete named API accounts for OpenRouter and DeepSeek using
references to API-key credentials in the encrypted vault. This is independent
of subscription plans and LLM routing.

OpenRouter exposes key spending/limits through `GET /api/v1/key`. An optional
management-key credential enables purchased credits, remaining account balance,
and account spending through `GET /api/v1/credits`. Management-key failure must
not hide successfully retrieved key usage. DeepSeek `GET /user/balance` exposes
available, granted, and topped-up balances per currency and an availability flag;
it does not supply usage totals. Unsupported data is unavailable, never zero.

## Persistence And Secrets

`monitor_api_accounts` stores UUID, unique name, provider, credential name,
optional management credential name, active flag, and timestamps. Account
definitions belong to `backplane_monitor`; migrations belong to
`backplane_system`. Credentials must exist, have kind `llm` or `service`, and use
API-key authentication. Selection uses safe vault metadata, never decrypted
values. Resolve and validate secrets only in provider polling; snapshots, forms,
errors, and audit records must not contain keys or raw HTTP responses.
Pausing an existing account remains possible if its referenced key has been
removed; creating, activating, or changing a definition still validates keys.

## Runtime And Result Contract

A supervised `Backplane.Monitor.ApiUsageServer` owns in-memory snapshots and
refreshes active accounts every five minutes through supervised tasks. Manual
refresh is asynchronous so the LiveView remains responsive. Do not overlap
requests for the same account; ignore results after edits, pause, or deletion.
Keep the last successful snapshot after errors, with a visible error and
separate attempt/success timestamps. Restart rebuilds the ephemeral cache.

Definition reads run in supervised tasks with five-second deadlines, not in the
cache owner. CRUD notifications invalidate by ID and cancel in-flight requests.
Invalidated accounts retain their last success but cannot refresh until an
authoritative read succeeds; confirmed deletion or credential/provider rebinding
discards the previous values. Generation checks prevent stale reads restoring
old definitions, and each waiting UI read has an eight-second total deadline
across retries, returning cached state on expiry.

`ApiUsageFetcher.fetch_usage(account)` returns `{:ok, data}` or a safe
`{:error, reason}`. Data contains `balances` (currency, total/granted/topped-up
amount strings), `usage` (label, amount string, currency), optional `limit`
(amount, remaining, currency, reset), optional `is_available`, and `warnings`.
Missing provider fields remain nil/absent. Currency amounts use decimal parsing;
invalid/malformed provider data is an error, not fabricated data.

## UI And Validation

Use existing DuskMoon components at `/system/monitor/api-usage` with new/edit
patch routes. Render account cards with explicit account/key labels, currencies,
last success, refreshing/paused/error status, and missing-data hints. CRUD and
toggle actions use existing secret-free admin audit conventions.

Scoped validation covers schema/context credential rules; authenticated mocked
provider requests, malformed responses and partial OpenRouter results; refresh
success/error, stale results and CRUD lifecycle; menu/routes, LiveView CRUD,
provider-specific presentation, and secret non-disclosure. No public API route
or subscription-plan semantics change. No commit/push is authorized.
