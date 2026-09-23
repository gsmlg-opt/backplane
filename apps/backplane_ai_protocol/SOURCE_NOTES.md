# Source notes

This package is being prepared from the pinned inventory in
`docs/ai-protocol/evidence/source_inventory.md` at the Backplane, Sigma, and Synapsis commits
recorded there. No Sigma or Synapsis implementation code has been copied yet.

## Disposition

Sigma `sigma_ai` is the initial extraction source for neutral request, event, message, usage,
error, and SSE primitives. Synapsis provider codecs are compatibility evidence and may inform
translation in later work packages.

The package must not absorb Backplane credential storage, production routing, native Codex
transport, or host-owned persistence. Sigma agent loops, Synapsis agent topology, tools,
approvals, daemon/background work, persistence, PubSub, and credential/config ownership remain
host-owned.

## Antigravity native evidence

The Antigravity native facade is based on behavioral evidence from the
MIT-licensed `antigravity-claude-proxy` repository at commit
`daa39d6c6239ac078a4e69de85094dde35558ef6`. The relevant source files are
`src/cloudcode/model-api.js`, `src/account-manager/onboarding.js`,
`src/cloudcode/request-builder.js`, `src/cloudcode/message-handler.js`, and
`src/cloudcode/streaming-handler.js`.

Only the five evidenced Cloud Code RPC shapes are represented. The package does
not copy OAuth client credentials, fallback project IDs, endpoint failover,
machine-derived user agents, Node client fingerprints, prompt injection or
scrubbing, signature caches, model curation, account pooling, or retry policy.
The fixture under `test/fixtures/antigravity` is handcrafted from those source
shapes and is explicitly not a captured upstream response.
