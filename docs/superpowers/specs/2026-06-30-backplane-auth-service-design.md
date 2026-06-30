# Backplane Auth Service Design

**Date:** 2026-06-30
**Status:** Approved direction, pending written review
**Scope:** Build `backplane_auth` as a standalone OAuth/OIDC service inside the
Backplane umbrella. The service is exposed through `backplane_api` and is meant
for external first-party applications such as `gsmlg_umbrella` and
`gsmlg_app_backend`.

## Goal

Backplane needs a real authentication service, not fake admin UI cards and not a
feature that only protects Backplane's own MCP or LLM routes. The first release
should make Backplane act like a small Keycloak-style issuer for trusted
applications: users log in to Backplane Auth, applications perform OAuth/OIDC
flows against it, APIs verify the issued tokens, and operators manage users,
clients, roles, scopes, sessions, and audit events from the Backplane admin UI.

The Auth service is part of the Backplane release and uses the existing
`backplane_api` web/API endpoint. It must still be a standalone service boundary:
external applications consume it through OAuth/OIDC, and existing Backplane
services do not become protected by it in v1.

## Superseded Direction

`docs/oauth-design.md` and the `2026-06-26-oauth-rbac-*` plans were centered on
making `/mcp` an OAuth-protected MCP resource. That is no longer the v1 target.
Those documents can remain as historical research, but implementation should
follow this spec first.

The existing `/auth/*` admin pages are also not sufficient. They currently show
mostly readiness/placeholder content. The new work should replace those pages
with real Auth service management surfaces as the domain pieces land.

## Non-goals For V1

- Protecting `/mcp`, `/v1/*`, `/skills/*`, `/host-agent/*`, or the Backplane
  admin endpoint with the new Auth service.
- Dynamic client registration. First-party apps are registered by operators in
  the admin UI.
- SAML, SCIM, LDAP, organization tenancy, external IdP federation, or social
  login. Local Backplane Auth users are the first release login mechanism.
- Full Keycloak feature parity. The target is a focused OAuth/OIDC issuer for
  the user's own applications.
- Reusing outbound provider credential OAuth under `Backplane.Settings.OAuth*`.
  That code is for Backplane acting as a client of Anthropic/OpenAI/Google/etc.,
  not for Backplane acting as an identity provider.

## Architecture

### Umbrella Boundaries

`apps/backplane_auth` is the new domain app. It owns Auth concepts and pure
service APIs:

- users and password credentials
- browser login sessions
- OAuth/OIDC clients
- authorization grants and token lifecycle
- roles, scopes, and role assignments
- signing keys and JWKS publication data
- audit events

`apps/backplane_api` owns the public HTTP contract. It defines controllers,
plugs, route pipelines, and browser pages for the Auth service, then calls
`Backplane.Auth` domain functions.

`apps/backplane_admin` owns operator management UI. It should manage Auth data by
calling `Backplane.Auth` contexts, not by embedding placeholder cards or raw SQL.

`apps/backplane_system` continues to own shared infrastructure such as
`Backplane.Repo`, encryption helpers, and existing runtime settings. The new
Auth app may depend on this infrastructure, but Auth-specific schemas and
contexts should live under `Backplane.Auth`.

### Runtime Shape

There is no separate Auth endpoint or Auth port in v1. Auth is served by the
existing public API endpoint:

- dev: `http://localhost:4220`
- prod: existing Backplane API host/port

The issuer is the API base URL. For example:

```text
https://backplane.example.com
```

An external app should be able to configure that issuer, read discovery metadata,
redirect users to `/oauth/authorize`, exchange codes at `/oauth/token`, and
verify JWTs with `/oauth/jwks`.

## HTTP Surface

Add these routes to `backplane_api`:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/.well-known/openid-configuration` | OIDC discovery document |
| `GET` | `/oauth/authorize` | Authorization endpoint, authorization code + PKCE |
| `POST` | `/oauth/token` | Code exchange and refresh-token grant |
| `GET` | `/oauth/jwks` | Public signing keys |
| `GET` | `/oauth/userinfo` | OIDC user profile for bearer tokens |
| `POST` | `/oauth/introspect` | Token introspection for confidential clients |
| `POST` | `/oauth/revoke` | Revoke access/refresh tokens |
| `GET` | `/oauth/login` | Login form for an authorization request |
| `POST` | `/oauth/login` | Login submission |
| `POST` | `/oauth/logout` | End browser Auth session |

Route modules should live under `Backplane.Api.Auth.*` or an equivalent
`backplane_api` namespace. Domain modules stay under `Backplane.Auth.*`.

## Protocol Profile

V1 supports:

- OAuth 2 authorization code flow with PKCE S256.
- Refresh token grant with rotation.
- Confidential clients using client authentication at the token, introspection,
  and revocation endpoints.
- Public clients only when explicitly marked public and PKCE is required.
- OIDC discovery, JWKS, ID tokens, and `/userinfo`.
- JWT access tokens signed by Backplane Auth.

V1 rejects:

- implicit grant
- password grant
- device-code grant
- dynamic client registration
- `plain` PKCE
- redirect URI wildcards

Boruta should be used as the OAuth/OpenID protocol engine where it fits. The
Backplane Auth domain must wrap it behind `Backplane.Auth` functions so future
changes do not leak Boruta table names or structs into `backplane_api` and
`backplane_admin`.

## Domain Model

Use `Backplane.Repo`, but keep Auth-specific schema modules in `backplane_auth`.
Existing Boruta tables may remain `oauth_*`; Backplane-owned tables should use
clear Auth names.

Core records:

- `auth_users`: email, display name, active flag, password state, login metadata.
- `auth_sessions`: browser login sessions for authorization flows and admin
  visibility.
- `auth_clients`: operator-managed OAuth/OIDC client applications. This can wrap
  or extend Boruta's `oauth_clients`, but the public context API should use
  Backplane Auth naming.
- `auth_scopes`: named scopes shown to operators and granted to applications.
- `auth_roles`: reusable role bundles.
- `auth_role_scopes`: scope membership for roles.
- `auth_user_roles`: role assignment for users.
- `auth_signing_keys`: active and retired signing keys for JWKS.
- `auth_audit_events`: append-only security event log.

If existing `users`, `auth_providers`, and `user_identities` tables are kept
temporarily, the implementation plan must either migrate them to the `auth_*`
naming or clearly wrap them as legacy storage behind `Backplane.Auth`. New code
should not expand the old `Backplane.Accounts` boundary.

## Authorization Flow

1. An external app redirects to `/oauth/authorize` with `client_id`,
   `redirect_uri`, `response_type=code`, `scope`, `state`, `code_challenge`, and
   `code_challenge_method=S256`.
2. `backplane_api` validates the request shape and asks `Backplane.Auth` to load
   the client and validate redirect URI, scopes, and PKCE policy.
3. If no Auth browser session exists, the user sees `/oauth/login`.
4. The user signs in with local Backplane Auth credentials.
5. Backplane Auth records the login event and resumes the pending authorization
   request.
6. V1 auto-approves first-party clients that are enabled and allowed to request
   the scopes. A consent screen can be added later.
7. Backplane Auth issues an authorization code.
8. The client exchanges the code at `/oauth/token` with its PKCE verifier.
9. Backplane Auth returns access token, refresh token, ID token when `openid` was
   requested, expiration metadata, and token type.
10. External APIs verify the JWT locally via `/oauth/jwks`, or call
    `/oauth/introspect` when configured to do remote validation.

## Token Model

Access tokens are JWTs signed by Backplane Auth. They include:

- issuer: API base URL
- subject: Auth user id
- audience: requested client/API audience
- client id
- scopes
- issued-at and expiration
- token id for audit/revocation correlation

Refresh tokens are stored server-side and rotated on every refresh. Reuse of a
previous refresh token revokes the token family and writes a high-severity audit
event.

ID tokens are OIDC tokens for clients that request `openid`. They should expose
only stable identity claims needed by first-party applications: subject, email,
email verified flag, display name, issued-at, expiration, issuer, audience, and
auth time.

## Admin UI

Replace the current fake Auth pages with real management pages:

- Overview: issuer URL, JWKS key status, counts of enabled clients/users, recent
  auth events, and protocol status.
- Clients: create/edit OAuth clients, redirect URIs, public/confidential flag,
  allowed scopes, token TTLs, rotate client secret, disable client.
- Users: create users, force password reset, disable user, view active sessions.
- Roles: create roles and assign scopes.
- Assignments: assign roles to users and preview effective scopes.
- Tokens and Sessions: list/revoke sessions and refresh-token families.
- Scopes: manage available scopes and descriptions.
- Audit: searchable append-only event stream.

The existing `/auth/*` route group in `backplane_admin` can remain, but every
page should either show real data/actions or be removed until the backed feature
exists. Placeholder cards are not acceptable as the final v1 surface.

## Security Invariants

- Password hashes use a modern password hashing library already accepted by the
  repo's dependency policy.
- Login rotates the browser session id.
- Authorization requests are short-lived, single-use, and tied to the browser
  session that completed login.
- Redirect URIs are exact-match against registered client URIs.
- PKCE S256 is required for public clients.
- Client secrets are generated server-side, shown once, and stored hashed or
  encrypted according to the protocol engine's requirements.
- Signing keys have ids (`kid`) and support rotation without instantly breaking
  existing access tokens.
- Audit logs never store plaintext passwords, refresh tokens, client secrets, or
  authorization codes.
- Existing Backplane PAT and legacy-token behavior remains unchanged in v1.

## First-Release Phasing

1. Create `apps/backplane_auth` and move/wrap current identity/OAuth domain code
   behind `Backplane.Auth`.
2. Add local user/password login and browser Auth session support.
3. Add admin-managed OAuth clients and scopes.
4. Wire `backplane_api` OIDC discovery, authorize, token, JWKS, userinfo,
   introspect, revoke, login, and logout routes.
5. Add JWT signing keys and token verification fixtures for external apps.
6. Replace Auth admin placeholder pages with real CRUD and operational actions.
7. Add integration documentation for `gsmlg_umbrella` and
   `gsmlg_app_backend`.

Each phase must be independently testable. Existing Backplane route behavior must
be covered by regression tests showing `/mcp`, `/v1/*`, `/skills/*`, and
`/host-agent/*` were not changed by the Auth service release.

## Acceptance Criteria

- A configured external app can complete authorization code + PKCE login against
  `backplane_api`.
- The app can exchange the code for JWT access token, refresh token, and ID token.
- The app can verify access tokens using `/oauth/jwks`.
- `/oauth/userinfo`, `/oauth/introspect`, and `/oauth/revoke` work for valid
  clients.
- Operators can manage users, clients, roles, scopes, sessions, and audit events
  through real admin pages.
- Existing Backplane services keep their current auth behavior in v1.
