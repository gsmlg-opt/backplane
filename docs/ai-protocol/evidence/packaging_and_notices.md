# Packaging and Source Notices

## Source-package observations

| Source | License evidence | Packaging note |
| --- | --- | --- |
| Backplane root | No root `LICENSE` or `COPYING` file found at the pinned SHA. | `day_ex` and `relayixir` declare MIT; `backplane_mcp_protocol` declares LGPL-3.0 and includes its license text. |
| Sigma `sigma_ai` | Root `LICENSE` is MIT, Copyright (c) 2026 GSMLG Limited. | The child `mix.exs` has no package declaration; compatibility must be maintained if code is later copied. |
| Synapsis `synapsis_provider` | No root or top-level `LICENSE`, `COPYING`, or `NOTICE` file found at the pinned SHA. | The child `mix.exs` has no package metadata or license declaration. Do not copy this source until ownership and license terms are resolved. |

## W1.1 package notices

Both new packages declare MIT and include a source-note file. Since no Sigma or Synapsis implementation code was copied, the new MIT declaration covers only the Backplane skeleton. Later extraction must add and verify exact upstream notices before copying any code.
