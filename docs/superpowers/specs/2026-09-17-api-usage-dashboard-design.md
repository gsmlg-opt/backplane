# API Usage Dashboard And Configuration

## Approved Behavior

- System → Monitor → API Usage is a configuration table like Plan Usage: name,
  provider, credential names, enabled status, and add/edit/delete/pause/resume.
  It neither displays usage figures nor loads usage snapshots or offers refresh.
- Dashboard → API Usage at `/dashboard/usage/api` displays account credits,
  key/account spending, limits, availability, timestamps, refreshing/errors,
  unsupported-data hints, and manual refresh. Existing secret-safe provider
  normalization and last-success retention remain unchanged.
- System → Config at `/system/config` contains a persistent global API-fetch
  switch, `monitor.api_usage.enabled`, default true. Individual account active
  flags still apply. Subscription Plan Usage is unaffected.
- Disabling prevents automatic/manual fetching and cancels supervised in-flight
  requests. Cached successful values remain visible with a disabled indication.
  Re-enabling reconciles current definitions and refreshes active accounts.
- Re-enable gates cached definitions until a successful fresh read, cancels
  pre-transition definition tasks, advances their generation, and preserves
  waiting callers' original deadlines. Failed reads keep fetching gated.
- Existing Settings PubSub propagates changes, and the context setter waits for
  runtime cancellation before returning. UI controls do not bypass runtime policy.

## Ownership And Validation

No migration is needed: use the existing system_settings table. Main owns monitor
policy/context/runtime, the Settings default, router/navigation, documentation,
and scoped integration. UI workers own disjoint configuration/dashboard and
System Config LiveViews/tests. Preserve all existing uncommitted feature work.

Tests cover configuration-only pages with no snapshot requests, dashboard
provider figures and safe errors, disabled controls/preserved cache, persistent
switch behavior, automatic/manual/CRUD fetch gating, cancellation/late results,
and re-enable reconciliation. Run only Monitor and touched admin/System tests.
No commits, pushes, unrelated changes, or real provider requests are authorized.
