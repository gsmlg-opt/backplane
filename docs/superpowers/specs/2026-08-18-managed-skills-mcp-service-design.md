# Managed Skills MCP Service Design

**Date:** 2026-08-18
**Status:** Approved for implementation planning

## Context

Backplane already exposes five Skills MCP tools through the native tool registry:

- `skill::search`
- `skill::load`
- `skill::list`
- `skill::download`
- `skill::publish`

They are callable through `/mcp`, but `/mcp/managed` only understands managed-service registrations for Day, Web, and Math. As a result, operators cannot see, enable, disable, or debug the Skills tools from the Managed MCP UI.

## Goals

- Present Skills as a first-class service at `/mcp/managed`.
- Persistently enable and disable all `skill::*` tools as one service.
- Provide the existing managed-service debug and tool-detail experiences.
- Preserve tool names, schemas, behavior, client scopes, and skill-load auditing.
- Preserve current deployments by enabling the service by default.

## Non-goals

- Renaming the `skill` namespace or any tool.
- Changing skill archive, search, load, download, or publish behavior.
- Adding per-tool enablement or new Skills configuration fields.
- Redesigning the Managed MCP UI or the shared tool registry.

## Architecture

Add `Backplane.Services.Skills` as a managed-service adapter with prefix `skill`.
The adapter implements `Backplane.Services.ManagedService` and delegates its tool
definitions and execution to `Backplane.Tools.Skill`.

`Backplane.Tools.Skill.tools/0` remains the single source for tool names,
descriptions, and input schemas. `Backplane.Services.Skills.tools/0` transforms
each native `{module, atom handler}` definition into the function handler expected
by `ToolRegistry.register_managed/2`. The wrapper adds an enablement guard and then
calls `Backplane.Tools.Skill.call/1` with the existing `_handler` dispatch value.

This adapter is preferred over changing `Backplane.Tools.Skill` directly because
it keeps the existing Skills implementation and direct tests stable while isolating
managed-service lifecycle concerns in one module.

## Registration and Lifecycle

The persisted setting is `services.skill.enabled` with a default value of `true`.
No database migration is required because `Backplane.Settings` seeds declared
defaults into `system_settings`.

At application startup:

1. Synchronize with `Backplane.Settings` so persisted values are loaded before
   service registration is reconciled.
2. Stop registering `Backplane.Tools.Skill` through the native tool list.
3. Include `Backplane.Services.Skills` in the managed-service list.
4. Register each managed service only when its `enabled?/0` value is true.

Skills must never be registered through both the native and managed paths. The
registry entry origin becomes `{:managed, "skill"}` while its public MCP name
remains unchanged.

At runtime, the Managed MCP toggle performs these operations in order:

- Enable: persist `true`, then register every adapter tool under prefix `skill`.
- Disable: persist `false`, then deregister every tool under prefix `skill`.

Registry registration and deregistration continue to emit the existing
`notifications/tools/list_changed` notification. The adapter also checks
`enabled?/0` immediately before delegation so an in-flight call or a direct admin
debug call cannot bypass a completed disable operation.

## Managed MCP UI

Add a Skills service descriptor anywhere the admin UI currently enumerates managed
services:

- `/mcp/managed` lists **Skills**, its `skill::` prefix, status, tool count, tool
  links, settings/debug navigation, and enable/disable action.
- `/mcp/managed/skill?tab=debug` lists all five tool definitions, their schemas,
  and the standard JSON debug form.
- `/mcp/managed/skill/tool/:tool_name` displays the existing tool-detail and test
  runner view for each Skills tool.

The debug and detail routes remain reachable while the service is disabled. Calls
made there return the adapter's disabled-service error rather than executing the
underlying Skills operation. Re-enabling restores debugging without a restart.

## MCP and Compatibility Behavior

When enabled, `tools/list` and `tools/call` behave as they do today. Existing
allowlists such as `skill::*` continue to match. The `skill::load` audit hook remains
name-based and therefore continues to record successful loads.

When disabled:

- `skill::*` tools are absent from `tools/list`.
- `tools/call` resolves them as unknown because they are absent from the registry.
- Admin debug and detail calls return a disabled-service error through the guarded
  adapter handler.

The service defaults to enabled so an upgrade does not unexpectedly remove tools
from existing clients.

## Error Handling

- A failed settings write does not mutate the registry.
- Registry synchronization uses the existing idempotent deregister-then-register
  behavior, preventing duplicate entries.
- Delegated Skills errors retain their current result shape and are rendered by
  the existing managed-tool error handling.
- Unknown service and tool routes retain the current redirect-and-flash behavior.

## Final Review Hardening

Production review added four constraints to the approved adapter design:

- Settings records whether its authoritative database load succeeded. Managed
  service reconciliation uses a successful snapshot and fails startup closed when
  that load is unavailable; an application-level retry retries the load.
- Skills desired-state writes and read-modify-write toggles serialize persistence
  and registry synchronization under one node-local lock. Managed MCP serializes
  the corresponding Day, Web, and Math UI toggles by prefix.
- `/mcp/managed` page loads are read-only. Startup reconciliation and successful
  toggle operations are the only synchronization points, so a page visit cannot
  create registry gaps or emit unchanged tool-list notifications.
- `skill` is reserved for the built-in service across config warnings, database
  changesets, and runtime upstream startup. Legacy conflicting upstreams are
  rejected before child startup and logged with their name, prefix, and reason.

## Test Strategy

Focused tests will prove:

1. The adapter exposes exactly the five current `skill::*` definitions and delegates
   successful calls without duplicating schemas.
2. A disabled adapter rejects direct execution.
3. Startup and runtime reconciliation register Skills only when enabled and never
   leave a native Skills entry behind.
4. `/mcp/managed` renders Skills, all enabled tool links, and the `skill` service
   route.
5. Toggling Skills persists the setting, removes/restores only `skill::*` entries,
   and updates the page state.
6. The Skills debug page documents its schemas, successfully runs an enabled
   `skill::list` call, and reports the disabled-service error when disabled.
7. A Skills tool-detail page renders and invokes through the guarded managed
   handler.
8. MCP `tools/list` includes the five tools when enabled and excludes them when
   disabled; existing `skill::load` audit coverage remains green.

Verification remains scoped to the affected service, registry, transport, and
admin LiveView test files.
