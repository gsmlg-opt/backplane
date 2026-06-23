# Backplane Admin/API Phoenix Split Design

**Status:** Approved for implementation planning
**Date:** 2026-06-23

## Goal

Split the existing Phoenix web surface into two Phoenix OTP apps that run on separate ports:

- `apps/backplane_admin`, OTP app `:backplane_admin`, module namespace `Backplane.Admin`
- `apps/backplane_api`, OTP app `:backplane_api`, module namespace `Backplane.Api`

The split preserves current route contracts while making public/API traffic and admin UI traffic independently bindable.

## Current State

`apps/backplane_web` currently owns all Phoenix endpoint behavior:

- Public documentation page at `/`
- MCP, LLM, skills, host-agent, health, and metrics APIs
- Admin LiveView UI under `/admin/*`
- Static assets, LiveView socket, and host-agent socket
- Endpoint-level `Backplane.LLM.ProxyPlug`, which must run before normal body parsers so LLM proxy requests can preserve raw bodies

The router already has a conceptual route split. The refactor should turn that conceptual split into two explicit Phoenix apps rather than changing product behavior.

## Target Apps

### `backplane_admin`

`backplane_admin` is the admin Phoenix app.

Primary modules:

- `Backplane.Admin.Application`
- `Backplane.Admin.Endpoint`
- `Backplane.Admin.Router`
- `Backplane.Admin.Layouts`
- `Backplane.Admin.*Live`
- `Backplane.Admin.OAuthCallbackController`

Route ownership:

- `/admin/*`
- `/admin/oauth/callback`
- development-only LiveDashboard on the admin port
- admin LiveView socket
- admin static assets

The admin app keeps the existing `/admin` path prefix even though it runs on a dedicated port. The admin root path on its own port is not a public home page; `/admin` remains the entry point.

### `backplane_api`

`backplane_api` is the public and API Phoenix app.

Primary modules:

- `Backplane.Api.Application`
- `Backplane.Api.Endpoint`
- `Backplane.Api.Router`
- `Backplane.Api.PageController`
- `Backplane.Api.PageHTML`
- `Backplane.Api.HostAgentSocket`
- `Backplane.Api.HostAgentChannel`

Route ownership:

- `/`
- `/api/mcp`
- `/api/v1/*`
- `/api/anthropic/*`
- `/api/llm/*`
- `/api/host-agent/*`
- `/api/skills/*`
- `/health`
- `/metrics`
- `/host-agent/socket`
- public static assets

The host-agent socket belongs with `backplane_api` because it is an API-facing endpoint concern, not an admin LiveView route.

## Retiring `backplane_web`

`apps/backplane_web` should not remain as a long-term third Phoenix app.

The implementation can use temporary compatibility modules during a commit sequence if that reduces risk, but the completed refactor should remove:

- `:backplane_web` from releases and runtime config
- `BackplaneWeb.Endpoint`
- `BackplaneWeb.Router`
- `BackplaneWeb` macro host
- `apps/backplane_web` asset and test ownership

## Ports And Runtime Config

Development defaults:

- `Backplane.Api.Endpoint`: port `4220`
- `Backplane.Admin.Endpoint`: port `4221`

Test defaults:

- `Backplane.Api.Endpoint`: port `4002`
- `Backplane.Admin.Endpoint`: port `4003`

Production defaults:

- `Backplane.Api.Endpoint`: port `4100`
- `Backplane.Admin.Endpoint`: port `4101`

Environment variables:

- `BACKPLANE_API_PORT` controls the API endpoint port.
- `BACKPLANE_ADMIN_PORT` controls the admin endpoint port.
- Existing `BACKPLANE_PORT` and `PORT` remain backward-compatible aliases for the API port.
- `PHX_SERVER=true` starts both endpoints in the release.
- If separate server switches are introduced, `PHX_SERVER=true` remains the default umbrella-level switch.

Endpoint URL config must support separate public origins:

- API external URL for public docs and API references
- Admin external URL for admin links and OAuth callback redirect URIs

## Secret Configuration

The split should remove core encryption's dependency on a Phoenix endpoint config.

Current behavior reads the secret key from `:backplane_web, BackplaneWeb.Endpoint`. The refactor should introduce a core secret configuration used by `Backplane.Settings.Encryption`, then configure both Phoenix endpoints from the same runtime secret unless a later requirement needs separate cookie secrets.

Required outcome:

- Core encrypted credentials keep decrypting with the same existing `SECRET_KEY_BASE`.
- Both endpoints can sign sessions and LiveView tokens.
- No core app reads `Backplane.Admin.Endpoint` or `Backplane.Api.Endpoint` just to find encryption material.

## Routing And Plug Boundaries

`Backplane.Api.Endpoint` must keep `Backplane.LLM.ProxyPlug` before ordinary `Plug.Parsers`.

Reason: LLM proxy routes under `/api/v1/*` and `/api/anthropic/*` rely on raw request bodies for model extraction and upstream proxying. Moving those requests behind the normal Phoenix parser would risk changing streaming/proxy behavior.

Public API route behavior should remain source-compatible:

- MCP remains at `/api/mcp`.
- OpenAI-compatible LLM proxy remains at `/api/v1/*`.
- Anthropic-compatible LLM proxy remains at `/api/anthropic/*`.
- LLM admin JSON API remains at `/api/llm/*`.
- Skills APIs remain at `/api/skills/*`.
- Host-agent API remains at `/api/host-agent/*`.

Admin route behavior should remain source-compatible:

- Existing `/admin/*` paths stay intact.
- Existing LiveView navigation paths stay intact.
- Existing OAuth callback path stays `/admin/oauth/callback`, but its generated absolute redirect URI uses `Backplane.Admin.Endpoint`.

Cross-app links must not use `~p` verified routes when they point to the other endpoint. Use configured external origins plus literal paths for those links.

## Assets

Each Phoenix app should own its asset build.

Admin assets:

- LiveView client
- DuskMoon admin UI components
- admin layout CSS
- admin-only hooks and events

API assets:

- public home page CSS/JS
- public static images and icons
- no LiveView client unless a public LiveView is added

The implementation should avoid a shared third web app just for assets. Shared images or common CSS can be duplicated initially or moved to a non-Phoenix support location only if duplication becomes a real maintenance problem.

## Test Structure

Admin tests move under `apps/backplane_admin/test`.

Recommended test support modules:

- `Backplane.Admin.LiveCase`
- `Backplane.Admin.ConnCase` if controller-only admin tests need it

API tests move under `apps/backplane_api/test`.

Recommended test support modules:

- `Backplane.Api.ConnCase`
- `Backplane.Api.ChannelCase`

Existing lower-level tests for MCP, LLM, skills, and core settings should remain in their owning non-Phoenix apps unless they specifically exercise endpoint routing.

## Release, Docker, And CI

The `backplane` release should include both Phoenix apps:

- `backplane_api: :permanent`
- `backplane_admin: :permanent`

It should no longer include `backplane_web`.

Docker and workflows should:

- copy both app `mix.exs` files before `mix deps.get`
- install/build assets for both Phoenix apps
- expose API and admin ports
- keep `BACKPLANE_PORT`/`PORT` compatibility for the API endpoint

Top-level `mix assets.deploy` should build both app asset bundles.

## Migration Strategy

1. Add core secret config and update encryption to stop reading from `BackplaneWeb.Endpoint`.
2. Scaffold `apps/backplane_api` as a Phoenix app with `Backplane.Api` modules.
3. Move public page, public router routes, API endpoint plugs, health/metrics forwards, and host-agent socket/channel into `backplane_api`.
4. Scaffold `apps/backplane_admin` as a Phoenix app with `Backplane.Admin` modules.
5. Move admin LiveViews, admin layouts, admin router routes, and OAuth callback into `backplane_admin`.
6. Update verified routes, cross-app links, OAuth redirect URI generation, test support modules, and endpoint config.
7. Update umbrella deps, release config, Dockerfile, CI workflows, README, and AGENTS project overview.
8. Remove `apps/backplane_web` after compile and scoped route tests pass.

This should be implemented in small commits, with route-level tests after each endpoint becomes independently callable.

## Acceptance Criteria

- `devenv shell -- mix compile` succeeds.
- `devenv shell -- mix test apps/backplane_api/test` succeeds.
- `devenv shell -- mix test apps/backplane_admin/test` succeeds.
- `GET http://localhost:4220/` serves the public page in dev.
- `GET http://localhost:4221/admin/dashboard/overview` serves the admin dashboard in dev.
- `POST http://localhost:4220/api/mcp` reaches the MCP transport.
- LLM proxy requests under `http://localhost:4220/api/v1/*` and `http://localhost:4220/api/anthropic/*` preserve current behavior.
- `http://localhost:4220/admin/*` is not served by the API endpoint.
- `http://localhost:4221/api/*` is not served by the admin endpoint.
- OAuth redirect URI generation points at the configured admin origin.
- The release starts both endpoints when `PHX_SERVER=true`.
- `apps/backplane_web` is absent from the final release configuration.

## Risks

- Verified route macros will fail until each moved module points at the correct endpoint/router pair.
- Cross-app links can silently point at the wrong port if they use same-origin paths.
- The LLM proxy can regress if `Backplane.LLM.ProxyPlug` moves behind `Plug.Parsers`.
- Session and LiveView signing can regress if endpoint secrets or salts are accidentally changed.
- Existing tests may hide endpoint coupling through `@endpoint BackplaneWeb.Endpoint`.
- OAuth callback redirects can break if they continue using the retired endpoint module.

## Out Of Scope

- Changing API paths or admin paths.
- Changing MCP, LLM, skills, or host-agent request/response contracts.
- Introducing a reverse proxy or path-based deployment layer.
- Reworking the admin UI design.
- Moving core business logic between non-Phoenix umbrella apps.
