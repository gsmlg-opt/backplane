# Backplane Auth Integration: gsmlg_umbrella

`gsmlg_umbrella` should treat Backplane Auth as an external OIDC issuer. The app
does not call Backplane internals and should not depend on umbrella database
tables from this repo.

## Backplane Admin Setup

Create an OAuth client in Backplane Admin under **Auth -> OAuth -> Clients**.

Recommended development values:

| Field | Value |
|---|---|
| Name | `gsmlg_umbrella` |
| Client type | Public for local browser apps, confidential for server-side exchange |
| Redirect URI | `http://localhost:<umbrella-port>/auth/backplane/callback` |
| PKCE | Enabled |
| Scopes | `openid profile email` plus app scopes such as `umbrella:read` |

For production, use an exact HTTPS redirect URI. Wildcard redirect hosts are not
accepted.

## Application Configuration

Configure the app from the Backplane API base URL:

```text
BACKPLANE_AUTH_ISSUER=https://backplane.example.com
BACKPLANE_AUTH_CLIENT_ID=<oauth client id>
BACKPLANE_AUTH_CLIENT_SECRET=<only for confidential clients>
BACKPLANE_AUTH_REDIRECT_URI=https://umbrella.example.com/auth/backplane/callback
BACKPLANE_AUTH_SCOPES=openid profile email umbrella:read
```

Discover endpoints from:

```text
GET ${BACKPLANE_AUTH_ISSUER}/.well-known/openid-configuration
```

The important v1 endpoints are:

| Purpose | Path |
|---|---|
| Authorization | `/oauth/authorize` |
| Token exchange | `/oauth/token` |
| JWKS | `/oauth/jwks` |
| UserInfo | `/oauth/userinfo` |
| Introspection | `/oauth/introspect` |
| Revocation | `/oauth/revoke` |

## Login Flow

1. Generate `state`, `code_verifier`, and `code_challenge` using PKCE S256.
2. Redirect the user to `${issuer}/oauth/authorize` with `response_type=code`,
   `client_id`, exact `redirect_uri`, requested `scope`, `state`,
   `code_challenge`, and `code_challenge_method=S256`.
3. Validate the callback `state`.
4. POST the authorization `code`, `redirect_uri`, and `code_verifier` to
   `${issuer}/oauth/token`.
5. Store the returned refresh token server-side only. Use the access token for
   app API calls and the ID token for the browser login session.

## Token Verification

Verify access tokens and ID tokens using the issuer JWKS:

```text
GET ${BACKPLANE_AUTH_ISSUER}/oauth/jwks
```

Required checks:

- `iss` equals `BACKPLANE_AUTH_ISSUER`
- `aud` equals the registered client id
- `exp` is in the future
- `scope` includes the application-required scope
- ID-token `email_verified` is `true` when email identity is required

Backplane Auth v1 is for first-party applications. It does not protect
Backplane's `/mcp`, `/v1/*`, `/skills/*`, `/host-agent/*`, or admin routes.
