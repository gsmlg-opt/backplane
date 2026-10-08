# Code Mode source contract fixtures

Pinned source: `openai/codex` revision
`46fdd5ef39735f4159cdcf0ec5e85c10521494e5`.

`contract.json` records reviewed source paths and SHA-256 hashes. Its programs
and expected observations are independently authored from the source helper
description, pragma parser, runtime defaults, and freeform grammar. They are
not output captures, and no native Codex engine was executed to produce them.
The tests execute Backplane's packaged Deno adapter against these expectations.

Source descriptions define text/media/store/load/notification/exit and running
cell behavior. Runtime defaults independently specify 10000 ms for exec and
wait, and 10000 tokens for exec output. The parser accepts leading whitespace,
CRLF, nullable optional fields, and nonnegative safe integers; it rejects
unknown fields, malformed JSON, negative/fractional fields, and empty source.

Host authority, cancellation, exact incarnation handles, timer generations and
uncertain outcomes are Backplane safety requirements, tested independently from
source-output conformance. Bounds stricter than native safe integers and the
four-bytes-per-token output estimate are host adaptations, not native parity.
