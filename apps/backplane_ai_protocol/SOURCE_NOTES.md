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

