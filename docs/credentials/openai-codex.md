# OpenAI Codex Device-Code OAuth Flow Without Codex CLI

## Goal

Create an OAuth module that authenticates a user with OpenAI Codex using the device-code flow, without shelling out to `codex login`, `codex app-server`, or any Codex CLI command.

The module should:

* request a device login code
* show the user a verification URL and one-time code
* poll until the user completes login
* exchange the returned authorization code for OAuth tokens
* persist tokens securely
* refresh tokens when needed
* revoke/logout when needed

This document only covers OAuth. It does not cover model requests, agent sessions, tools, proxying, or runtime orchestration.

---

## Flow Summary

```text
1. Request device user code
2. Show verification URL + user code
3. Poll device token endpoint
4. Receive authorization_code + PKCE verifier
5. Exchange authorization_code for tokens
6. Store id_token, access_token, refresh_token securely
7. Refresh access token when close to expiry
8. Revoke refresh token on logout
```

---

## Constants

Use these constants in the module:

```text
ISSUER = https://auth.openai.com
ACCOUNTS_API = https://auth.openai.com/api/accounts
DEVICE_USER_CODE_URL = https://auth.openai.com/api/accounts/deviceauth/usercode
DEVICE_TOKEN_URL = https://auth.openai.com/api/accounts/deviceauth/token
TOKEN_URL = https://auth.openai.com/oauth/token
REVOKE_URL = https://auth.openai.com/oauth/revoke
DEVICE_VERIFICATION_URL = https://auth.openai.com/codex/device
DEVICE_CALLBACK_URL = https://auth.openai.com/deviceauth/callback
```

Use the Codex OAuth public client ID:

```text
CLIENT_ID = app_EMoamEEZ73f0CkXaXp7hrann
```

Treat the client ID as public configuration, not a secret.

---

## Module API

The OAuth module should expose only these functions:

```text
start_device_login()
poll_device_login(login)
exchange_authorization_code(code_result)
refresh_tokens(token_set)
revoke_tokens(token_set)
read_token_state()
logout()
```

Suggested data types:

```text
DeviceLogin:
  login_id
  device_auth_id
  verification_url
  user_code
  interval_seconds
  expires_at
  status

DeviceCodeResult:
  authorization_code
  code_challenge
  code_verifier

TokenSet:
  id_token
  access_token
  refresh_token
  expires_at
  account_id
  plan_type
```

---

## Step 1 — Request Device User Code

Send:

```http
POST https://auth.openai.com/api/accounts/deviceauth/usercode
Content-Type: application/json
```

Body:

```json
{
  "client_id": "app_EMoamEEZ73f0CkXaXp7hrann"
}
```

Expected response:

```json
{
  "device_auth_id": "<device-auth-id>",
  "user_code": "ABCD-1234",
  "interval": "5"
}
```

Some responses may use `usercode` instead of `user_code`, so accept both.

Store:

```text
device_auth_id
user_code
interval_seconds
expires_at = now + 15 minutes
status = pending
```

Return to caller:

```json
{
  "status": "pending",
  "verification_url": "https://auth.openai.com/codex/device",
  "user_code": "ABCD-1234",
  "expires_in_seconds": 900
}
```

---

## Step 2 — Show User Login Instructions

Show the user:

```text
Open this URL:

https://auth.openai.com/codex/device

Enter this code:

ABCD-1234
```

The code expires after about 15 minutes.

Do not log the code as a normal info log. Device codes are sensitive because they authorize a login attempt.

---

## Step 3 — Poll for Authorization Code

Poll:

```http
POST https://auth.openai.com/api/accounts/deviceauth/token
Content-Type: application/json
```

Body:

```json
{
  "device_auth_id": "<device-auth-id>",
  "user_code": "ABCD-1234"
}
```

Polling behavior:

```text
200 -> login completed; parse response
403 -> still pending; sleep interval_seconds and retry
404 -> still pending or not ready; sleep interval_seconds and retry
other -> fail
timeout after 15 minutes
```

Success response:

```json
{
  "authorization_code": "<authorization-code>",
  "code_challenge": "<pkce-code-challenge>",
  "code_verifier": "<pkce-code-verifier>"
}
```

Store only temporarily:

```text
authorization_code
code_verifier
code_challenge
```

These values are one-time exchange material. Do not persist them long term.

---

## Step 4 — Exchange Authorization Code for Tokens

Send:

```http
POST https://auth.openai.com/oauth/token
Content-Type: application/x-www-form-urlencoded
```

Body:

```text
grant_type=authorization_code
&code=<authorization_code>
&redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback
&client_id=app_EMoamEEZ73f0CkXaXp7hrann
&code_verifier=<code_verifier>
```

Expected response:

```json
{
  "id_token": "<jwt>",
  "access_token": "<access-token>",
  "refresh_token": "<refresh-token>"
}
```

After this succeeds, the OAuth login is complete.

---

## Step 5 — Parse Token Metadata

Decode the JWT payload of `id_token` and/or `access_token`.

Do not need to verify the JWT signature just to extract local metadata, but never use unverified decoded claims for authorization decisions.

Useful metadata:

```text
chatgpt_account_id
chatgpt_plan_type
email
organization_id
project_id
exp
```

Store:

```text
account_id
plan_type
email
expires_at
```

Keep the original tokens encrypted or in a secure credential store.

---

## Step 6 — Persist Tokens Securely

Store this token set:

```json
{
  "type": "codex_device_oauth",
  "auth_mode": "chatgpt",
  "id_token": "<jwt>",
  "access_token": "<access-token>",
  "refresh_token": "<refresh-token>",
  "expires_at": 1760000000000,
  "account_id": "<chatgpt-account-id>",
  "plan_type": "plus"
}
```

Storage requirements:

```text
- encrypt at rest if using a database
- use OS keychain if available
- use file mode 0600 if using a local file
- directory mode should be 0700
- never print tokens in logs
- never send tokens to the browser
- never pass tokens into model context
```

Safe log fields:

```text
login_started
login_completed
token_refreshed
logout_completed
account_id_hash
plan_type
```

Unsafe log fields:

```text
id_token
access_token
refresh_token
authorization_code
code_verifier
auth headers
raw token endpoint response
```

---

## Step 7 — Refresh Tokens

When the access token is expired or near expiry, refresh it.

Use a skew window:

```text
refresh when now >= expires_at - 5 minutes
```

Send:

```http
POST https://auth.openai.com/oauth/token
Content-Type: application/x-www-form-urlencoded
```

Body:

```text
grant_type=refresh_token
&refresh_token=<refresh-token>
&client_id=app_EMoamEEZ73f0CkXaXp7hrann
```

Expected response usually includes a fresh token set:

```json
{
  "id_token": "<new-jwt>",
  "access_token": "<new-access-token>",
  "refresh_token": "<new-refresh-token>"
}
```

Important refresh rule:

```text
Treat refresh tokens as rotating / single-use.
```

When refresh succeeds:

```text
1. write the new token set atomically
2. replace the old refresh token immediately
3. do not keep using the old refresh token
```

To avoid `refresh_token_reused` errors:

```text
- use a per-account refresh lock
- allow only one process to refresh a token set
- persist the new refresh token before releasing the lock
- reload token state before refreshing
- if another process already refreshed, reuse the newer stored tokens
```

---

## Step 8 — Logout / Revoke

On logout, revoke the refresh token.

Send:

```http
POST https://auth.openai.com/oauth/revoke
Content-Type: application/json
```

Body:

```json
{
  "token": "<refresh-token>",
  "token_type_hint": "refresh_token",
  "client_id": "app_EMoamEEZ73f0CkXaXp7hrann"
}
```

Then delete local token state.

Local logout sequence:

```text
1. load current token set
2. call revoke endpoint with refresh_token
3. delete local token store even if remote revoke fails
4. clear in-memory token cache
5. mark account unauthenticated
```

---

## State Machine

```text
unauthenticated
  -> device_code_pending
  -> authorization_code_ready
  -> token_exchange_running
  -> authenticated
  -> refreshing
  -> authenticated
  -> logged_out
```

Error states:

```text
device_code_disabled
device_code_expired
poll_timeout
token_exchange_failed
refresh_failed
refresh_token_reused
revocation_failed
```

---

## Error Handling

### Device code disabled

If `/deviceauth/usercode` returns `404`, return:

```json
{
  "error": "device_code_login_disabled",
  "message": "Device-code login is not enabled for this account or server."
}
```

### Poll timeout

If polling exceeds 15 minutes:

```json
{
  "error": "device_code_expired",
  "message": "Device-code login expired. Start a new login."
}
```

### Token exchange failure

If `/oauth/token` fails during authorization-code exchange:

```json
{
  "error": "token_exchange_failed",
  "message": "Failed to exchange Codex authorization code for tokens."
}
```

### Refresh token reused

If refresh fails with `refresh_token_reused`:

```json
{
  "error": "refresh_token_reused",
  "message": "The refresh token was already consumed. Reload token state or re-authenticate."
}
```

Recovery:

```text
1. reload token store
2. if newer tokens exist, use them
3. otherwise require a fresh device-code login
```

---

## Minimal HTTP Sequence

```text
POST /api/accounts/deviceauth/usercode
  -> device_auth_id, user_code, interval

User opens:
  https://auth.openai.com/codex/device

Repeated:
POST /api/accounts/deviceauth/token
  -> 403/404 pending
  -> 200 authorization_code, code_verifier

POST /oauth/token
  grant_type=authorization_code
  -> id_token, access_token, refresh_token

Later:
POST /oauth/token
  grant_type=refresh_token
  -> new token set

Logout:
POST /oauth/revoke
  -> revoke refresh token
```

---

## Acceptance Checklist

The OAuth module is complete when:

```text
1. It requests a device code without invoking Codex CLI.
2. It returns verification URL and user code.
3. It polls until completion or timeout.
4. It exchanges authorization_code for tokens.
5. It securely stores id_token, access_token, refresh_token.
6. It decodes token metadata for account display.
7. It refreshes tokens with a per-account lock.
8. It handles refresh-token rotation.
9. It revokes tokens on logout.
10. It never logs or exposes raw secrets.
```

---

## Implementation Rule

Keep OAuth isolated.

The module should only return:

```text
authenticated / unauthenticated
account metadata
valid access token for internal use
```

It should not know anything about agent runtime, tools, model routing, sessions, or proxy behavior.
