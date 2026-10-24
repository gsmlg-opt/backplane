# Pinned tool search data and algorithms

Compatibility target: OpenAI Codex commit
`46fdd5ef39735f4159cdcf0ec5e85c10521494e5` (Apache-2.0), generic tool metadata
text and English tool search. Development oracle sources and Cargo checksums
are in `dev/tool_search_oracle/`; none are required by the Runtime package.

* OpenAI Codex, Copyright 2025 OpenAI: generic metadata traversal and namespace
  defaults are adapted into Elixir for Backplane contracts, atom/string schema
  keys and validated boolean leaves. These are modified derivatives, not
  unmodified Codex source. See LICENSE-codex (Apache-2.0) and NOTICE-codex,
  copied verbatim from the pinned revision's root LICENSE and NOTICE at
  `https://github.com/openai/codex/tree/46fdd5ef39735f4159cdcf0ec5e85c10521494e5`.
  The full upstream NOTICE is preserved, including its third-party attribution;
  this does not imply that Backplane search contains Ratatui code.

* deunicode 1.6.2, Kornel Lesinski and contributors: exact `pointers.bin`
  (419,994 bytes) and `mapping.txt` (56,405 bytes), BSD-3-Clause; see
  LICENSE-deunicode. Unknown characters map to `[?]`.
* stop-words 0.9.0, Chris McComb: exact `src/nltk/english`, MIT; see
  LICENSE-stop-words. This is its NLTK-only English data, without ISO defaults.
* rust-stemmers 1.2.0, Jakob Demler, MIT (LICENSE-rust-stemmers): English
  algorithm ported from its generated Snowball implementation. The development-only Snowball test
  vocabulary license is retained under dev/tool_search_oracle; test fixtures
  and that vocabulary are excluded from the published Runtime package.
* bm25 2.3.2, Michael: tokenizer, embedding and scorer behavior ported under
  MIT (LICENSE-bm25). Constants, f32 operation order and repeated query tokens
  are preserved.
* FxHash32 from fxhash 0.2.1, originally the Rust compiler's hash algorithm,
  MIT/Apache-2.0. The Elixir port preserves 32-bit rotation/overflow, little
  endian token bytes and Rust str's separately hashed 0xff terminator.
  See LICENSE-fxhash-unicode for the chosen MIT license.
* ASCII word boundaries implement the applicable UAX #29 rules used by
  unicode-segmentation 1.12.0 after deunicode's ASCII-only normalization.

The development oracle lockfile records exact registry checksums. SHA256SUMS
records the shipped source data and license bytes. No Rust, NIF, Port, executable
helper or production dependency is used for search.
