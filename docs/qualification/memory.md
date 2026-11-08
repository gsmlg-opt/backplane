# Memory verification

The memory qualification profiles (`mix memory.qualify`, `mix memory.eval`,
`mix memory.seed_bench`, replay browser qualification and the
`memory-qualification` CI artifact) were retired with the memory
simplification. See
[docs/superpowers/specs/2026-11-09-memory-simplification-design.md](../superpowers/specs/2026-11-09-memory-simplification-design.md).

Current verification is the ordinary test suites:

- `mix do --app backplane_memory cmd mix test` (also the `Memory Test` workflow)
- `apps/backplane/test/integration/memory_mcp_contract_test.exs` (gateway `memory::*` contract)
- host-agent capture tests in `apps/backplane_host_agent/test/backplane/host_agent/memory/`
- `Memory Plugins` workflow for the Hermes / OpenClaw provider contracts

This file is still attached to releases under its historical asset name
`memory-qualification.md` so the release asset inventory is unchanged.
