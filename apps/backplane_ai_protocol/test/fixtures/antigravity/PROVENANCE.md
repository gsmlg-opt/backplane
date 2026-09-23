# Antigravity fixture provenance

`native_lifecycle.json` is a handcrafted, sanitized source-based fixture. It is
not a captured Antigravity or Google response and is not evidence of a live
subscription request.

The request and response shapes were derived from the MIT-licensed
`antigravity-claude-proxy` repository at commit
`daa39d6c6239ac078a4e69de85094dde35558ef6`, specifically:

- `src/cloudcode/model-api.js` (`loadCodeAssist`, `fetchAvailableModels`)
- `src/account-manager/onboarding.js` (`onboardUser`)
- `src/cloudcode/request-builder.js` and the generation handlers

Names, IDs, quota values, text and opaque signatures are synthetic examples.
No OAuth tokens, client secrets, account identifiers, default project IDs or
machine fingerprints are present.
