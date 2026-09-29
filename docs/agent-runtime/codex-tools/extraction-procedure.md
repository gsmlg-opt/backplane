# Codex tool extraction procedure

This procedure freezes how CT-00 evidence is produced. It is intentionally
deterministic and does not fetch private data or silently replace the pinned
Codex source.

## Inputs

- Backplane baseline commit `7e3d81e18ddd612e20a8e11b60f3e1ad7d3bcb6d`,
  which must remain an ancestor of the current implementation commit.
- Codex commit `46fdd5ef39735f4159cdcf0ec5e85c10521494e5`.
- Repository root and optional `CODEX_SOURCE_ROOT` containing the exact Codex
  object. A checkout at another revision is evidence of availability only, not
  evidence for the pinned source.

## Reproduce local evidence

From the Backplane root:

```text
ruby scripts/codex_tools_inventory.rb --generate
ruby scripts/codex_tools_inventory.rb --check
```

`--generate` records the fixed Backplane baseline relationship and runtime
hashes in `local-source-manifest.json`, then writes a reviewed table of
constructor and registration source records with exact file hashes into packaged
`priv/codex/source-inventory.json`. Constructors are not executed and schemas
are not exported from Rust, so this is source-audit evidence rather than a
generated behavioral contract fixture. `--check` regenerates the reviewed table
in memory and fails on source, symbol, registration-entrypoint hash, pin,
JSON-shape, or ledger-disposition drift.

## Reproduce pinned Codex extraction

Provide an exact object without downloading it in this repository:

```text
CODEX_SOURCE_ROOT=/path/to/codex-at-46fdd5e ruby scripts/codex_tools_inventory.rb --generate
```

The script accepts the Codex root only when its `git rev-parse HEAD` equals the
required pin. Both generation and source-aware checking require
`CODEX_SOURCE_ROOT`; no machine-local absolute checkout path is persisted. A
missing/wrong revision fails rather than silently retaining guessed inventory.

## Interpretation rules

`inventory` means the family is named by the approved plan. `available` means a
Backplane implementation or owning service was observed. `admitted` and
`exposed` require an actual host-selected registration and authorized route;
source names alone are insufficient.

The ledger also records the independent completion fields required by the plan:

- `contract_status`: `missing`, `exported`, or `verified`;
- `execution_status`: `not_implemented`, `partial`, `reference_verified`,
  `backend_verified`, `provider_hosted`, or `test_only`;
- `availability`: `available`, `missing_backend`, `unsupported_platform`,
  `unsupported_provider`, `disabled_profile`, or `denied_policy`;
- `parity`: `exact_for_profile`, `adapted`, `divergent`, or `unverified`.

Each family identifies its public tools, handler, required backends, focused
tests, and deviations. Exact-source inventory alone never upgrades contract,
execution, availability, or parity status.
