# Get Current Codex Plan Usage With Auth Token

## Goal

Implement a direct HTTP module that reads the current Codex plan usage using an existing ChatGPT/Codex OAuth access token.

This module does not use:

```text
codex cli
codex app-server
codex login
codex mcp-server
```

It only uses:

```text
OAuth access token
ChatGPT account/workspace ID
direct HTTPS request to Codex/ChatGPT backend usage endpoint
```

## Important Stability Note

This direct HTTP endpoint is not the preferred stable public API. The documented stable surface is Codex App Server `account/rateLimits/read`.

Use this direct-token implementation only when you intentionally want to avoid Codex CLI/App Server and accept that backend paths or response fields may change.

## Required Inputs

The module needs:

```text
access_token
chatgpt_account_id
```

Optional:

```text
user_agent
is_fedramp_account
```

`access_token` comes from your existing Codex/ChatGPT OAuth device-code flow.

`chatgpt_account_id` should come from your decoded token metadata or account metadata collected during login.

## Endpoint

Use the ChatGPT backend usage endpoint:

```http
GET https://chatgpt.com/backend-api/wham/usage
```

Alternative Codex API-style endpoint:

```http
GET https://codex.openai.com/api/codex/usage
```

Recommended default:

```text
https://chatgpt.com/backend-api/wham/usage
```

because the token is a ChatGPT/Codex OAuth token.

## HTTP Request

```http
GET /backend-api/wham/usage HTTP/1.1
Host: chatgpt.com
Authorization: Bearer <access_token>
ChatGPT-Account-ID: <chatgpt_account_id>
User-Agent: codex-cli
Accept: application/json
```

Example curl:

```bash
curl 'https://chatgpt.com/backend-api/wham/usage' \
  -H "Authorization: Bearer $OPENAI_CODEX_ACCESS_TOKEN" \
  -H "ChatGPT-Account-ID: $CHATGPT_ACCOUNT_ID" \
  -H "User-Agent: codex-cli" \
  -H "Accept: application/json"
```

If the account is a FedRAMP account, also send:

```http
X-OpenAI-Fedramp: true
```

## Expected Response Shape

The raw response is expected to look like:

```json
{
  "plan_type": "plus",
  "rate_limit": {
    "primary_window": {
      "used_percent": 25,
      "limit_window_seconds": 18000,
      "reset_after_seconds": 3600,
      "reset_at": 1760000000
    },
    "secondary_window": {
      "used_percent": 10,
      "limit_window_seconds": 604800,
      "reset_after_seconds": 300000,
      "reset_at": 1760500000
    }
  },
  "credits": {
    "has_credits": true,
    "unlimited": false,
    "balance": "9.99"
  },
  "additional_rate_limits": [
    {
      "metered_feature": "codex_other",
      "limit_name": "codex_other",
      "rate_limit": {
        "primary_window": {
          "used_percent": 42,
          "limit_window_seconds": 3600,
          "reset_after_seconds": 1200,
          "reset_at": 1760001000
        }
      }
    }
  ],
  "rate_limit_reached_type": {
    "type": "rate_limit_reached"
  }
}
```

All fields should be treated as optional except `plan_type`.

## Normalized Output

Normalize the raw response into this shape:

```json
{
  "status": "ok",
  "plan_type": "plus",
  "limits": {
    "codex": {
      "limit_id": "codex",
      "limit_name": null,
      "primary": {
        "used_percent": 25,
        "window_duration_mins": 300,
        "resets_at": 1760000000
      },
      "secondary": {
        "used_percent": 10,
        "window_duration_mins": 10080,
        "resets_at": 1760500000
      },
      "credits": {
        "has_credits": true,
        "unlimited": false,
        "balance": "9.99"
      },
      "rate_limit_reached_type": "rate_limit_reached"
    },
    "codex_other": {
      "limit_id": "codex_other",
      "limit_name": "codex_other",
      "primary": {
        "used_percent": 42,
        "window_duration_mins": 60,
        "resets_at": 1760001000
      },
      "secondary": null,
      "credits": null,
      "rate_limit_reached_type": null
    }
  }
}
```

## Normalization Rules

### Main Codex bucket

Always create a primary bucket named:

```text
codex
```

from the top-level `rate_limit` field.

### Additional buckets

For every item in `additional_rate_limits`, create another bucket.

Use:

```text
limit_id = additional_rate_limits[].metered_feature
limit_name = additional_rate_limits[].limit_name
```

### Window conversion

Raw backend field:

```text
limit_window_seconds
```

Normalized field:

```text
window_duration_mins
```

Conversion:

```text
window_duration_mins = ceil(limit_window_seconds / 60)
```

### Reset timestamp

Use:

```text
reset_at
```

as the normalized:

```text
resets_at
```

This is a Unix timestamp in seconds.

### Usage percent

Use:

```text
used_percent
```

as:

```text
used_percent
```

Do not assume it is an integer forever. Store it as a number.

### Credits

If `credits` is missing or null, return:

```json
"credits": null
```

Otherwise return:

```json
{
  "has_credits": true,
  "unlimited": false,
  "balance": "9.99"
}
```

### Rate-limit reached type

If present:

```json
{
  "rate_limit_reached_type": {
    "type": "workspace_member_credits_depleted"
  }
}
```

normalize to:

```json
"rate_limit_reached_type": "workspace_member_credits_depleted"
```

Known values may include:

```text
rate_limit_reached
workspace_owner_credits_depleted
workspace_member_credits_depleted
workspace_owner_usage_limit_reached
workspace_member_usage_limit_reached
unknown
```

Treat unknown values as strings and pass them through.

## Minimal Module API

Expose:

```text
get_current_usage()
get_current_usage!(token_state)
normalize_usage_response(raw)
```

Suggested input:

```json
{
  "access_token": "<access-token>",
  "chatgpt_account_id": "org_123",
  "expires_at": 1760000000
}
```

Suggested output:

```json
{
  "status": "ok",
  "plan_type": "plus",
  "limits": {
    "codex": {
      "primary": {
        "used_percent": 25,
        "window_duration_mins": 300,
        "resets_at": 1760000000
      }
    }
  }
}
```

## Request Algorithm

```text
get_current_usage(token_state):

  1. Ensure access_token is present.
  2. Ensure chatgpt_account_id is present.
  3. If access token expires within 5 minutes, refresh it first.
  4. Send GET https://chatgpt.com/backend-api/wham/usage.
  5. Include Authorization: Bearer <access_token>.
  6. Include ChatGPT-Account-ID: <chatgpt_account_id>.
  7. If 200, parse and normalize response.
  8. If 401, refresh access token once and retry once.
  9. If still 401, require OAuth login again.
  10. If 429, return rate_limited.
  11. If other non-2xx, return upstream_error.
```

## 401 Handling

On `401 Unauthorized`:

```text
1. Acquire per-account refresh lock.
2. Reload token state.
3. If another process already refreshed, retry with latest token.
4. Otherwise refresh OAuth token.
5. Save new token set atomically.
6. Retry usage request once.
7. If still unauthorized, mark account unauthenticated.
```

Return:

```json
{
  "status": "error",
  "error": "unauthorized",
  "message": "The Codex OAuth token was rejected. Re-authentication is required."
}
```

## 429 Handling

On `429 Too Many Requests`, return:

```json
{
  "status": "error",
  "error": "rate_limited",
  "message": "Usage endpoint is rate limited.",
  "retry_after": 60
}
```

Use the `Retry-After` response header if present.

## Other Error Handling

### Missing token

```json
{
  "status": "error",
  "error": "missing_access_token"
}
```

### Missing account ID

```json
{
  "status": "error",
  "error": "missing_chatgpt_account_id"
}
```

### Bad JSON

```json
{
  "status": "error",
  "error": "invalid_usage_response"
}
```

### Upstream failure

```json
{
  "status": "error",
  "error": "usage_upstream_error",
  "status_code": 500
}
```

## Cache Policy

Use a short cache.

Recommended:

```text
cache_ttl = 30 seconds
manual_refresh = bypass cache
background_refresh = every 1-5 minutes only while UI is open
```

Do not poll every few seconds.

Usage can change after Codex turns, so refresh after a task/turn completes if you need accurate display.

## Display Format

Display:

```text
Plan: Plus

Codex:
  Primary: 25% used
  Window: 5 hours
  Resets: 2026-06-04 18:30

  Secondary: 10% used
  Window: 7 days
  Resets: 2026-06-08 00:00

Credits: 9.99
Limit reached: no
```

If `rate_limit_reached_type` is present:

```text
Limit reached: workspace_member_credits_depleted
```

## Security Rules

Never log:

```text
access_token
refresh_token
Authorization header
full raw request headers
full raw response if it may include sensitive fields
```

Safe to log:

```text
usage request succeeded
usage request failed
status code
plan_type
limit_id
used_percent
resets_at
```

Keep refresh token private inside the OAuth module. This usage module only needs a valid access token.

## Acceptance Checklist

Implementation is complete when:

```text
1. It sends GET /backend-api/wham/usage without Codex CLI.
2. It uses Authorization: Bearer <access_token>.
3. It sends ChatGPT-Account-ID.
4. It refreshes token before expiry.
5. It retries once after 401.
6. It parses plan_type.
7. It parses the main codex rate_limit bucket.
8. It parses additional_rate_limits.
9. It parses credits.
10. It parses rate_limit_reached_type.
11. It normalizes window duration from seconds to minutes.
12. It returns reset timestamps as Unix seconds.
13. It never logs tokens.
14. It treats this endpoint as unstable/source-derived.
```

## Final Rule

Use this direct HTTP method only when you explicitly want no Codex CLI/App Server dependency.

The stable documented abstraction is still Codex App Server `account/rateLimits/read`; this direct endpoint should be wrapped behind your own module boundary so it can be replaced if OpenAI changes the backend path or response shape.
