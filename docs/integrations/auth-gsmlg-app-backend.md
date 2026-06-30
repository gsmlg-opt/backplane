# Backplane Auth Integration: gsmlg_app_backend

`gsmlg_app_backend` should use Backplane Auth as its OAuth/OIDC issuer and
validate Backplane-issued access tokens at the API boundary.

## Backplane Admin Setup

Create a confidential OAuth client in Backplane Admin under
**Auth -> OAuth -> Clients**.

Recommended values:

| Field | Value |
|---|---|
| Name | `gsmlg_app_backend` |
| Client type | Confidential |
| Redirect URI | `https://api.example.com/auth/backplane/callback` |
| PKCE | Enabled |
| Scopes | `openid profile email app:read app:write` |

Store the generated client secret in the backend secret manager. Do not expose it
to browsers or mobile clients.

## Backend Configuration

```text
BACKPLANE_AUTH_ISSUER=https://backplane.example.com
BACKPLANE_AUTH_CLIENT_ID=<oauth client id>
BACKPLANE_AUTH_CLIENT_SECRET=<oauth client secret>
BACKPLANE_AUTH_REDIRECT_URI=https://api.example.com/auth/backplane/callback
BACKPLANE_AUTH_SCOPES=openid profile email app:read app:write
```

The backend should read discovery metadata at startup and cache the JWKS with a
short refresh interval:

```text
GET ${BACKPLANE_AUTH_ISSUER}/.well-known/openid-configuration
GET ${BACKPLANE_AUTH_ISSUER}/oauth/jwks
```

## Authorization Code Exchange

Use authorization code with PKCE S256. Confidential clients authenticate to
`/oauth/token` with HTTP Basic auth:

```http
POST /oauth/token
Authorization: Basic base64(client_id:client_secret)
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code&
code=<code>&
redirect_uri=<exact redirect uri>&
code_verifier=<pkce verifier>
```

Refresh tokens rotate. Persist only the newest refresh token and treat
`invalid_grant` during refresh as a forced re-login.

## API Request Validation

For each bearer token received by `gsmlg_app_backend`:

1. Verify the JWT signature using `/oauth/jwks`.
2. Require `iss == BACKPLANE_AUTH_ISSUER`.
3. Require `aud == BACKPLANE_AUTH_CLIENT_ID` unless a later audience model is
   introduced for resource APIs.
4. Require `exp` to be in the future.
5. Require the endpoint-specific scope, such as `app:read` or `app:write`.
6. Use `/oauth/userinfo` or `/oauth/introspect` only when the backend needs a
   live revocation check or a fresh user profile.

Confidential introspection example:

```http
POST /oauth/introspect
Authorization: Basic base64(client_id:client_secret)
Content-Type: application/x-www-form-urlencoded

token=<access token>
```

## Logout And Revocation

Revoke access or refresh tokens when a user disconnects the app:

```http
POST /oauth/revoke
Authorization: Basic base64(client_id:client_secret)
Content-Type: application/x-www-form-urlencoded

token=<access-or-refresh-token>
```

Backplane Auth v1 is standalone for first-party applications. Existing Backplane
service routes keep their current auth behavior and are not protected by these
tokens in the first release.
