> **Superseded** by [docs/superpowers/specs/2026-11-09-memory-simplification-design.md](../superpowers/specs/2026-11-09-memory-simplification-design.md).

# Hermes memory integration

The partition, authorization and access-binding protocol this document used to
describe was retired. The Hermes plugin now reads and writes the global memory
store through the host agent's `memory::*` tools.

Current documentation:

- [`integrations/memory/hermes/README.md`](../../integrations/memory/hermes/README.md) for installation, behavior, failure modes and privacy.
- [Memory architecture: Plugins](../architecture/memory.md#plugins).
- [Host agent deployment](../deploy/host_agent.md#5-install-memory-plugins).
