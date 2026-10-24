# Pinned tool-search oracle (development only)

Codex compatibility target: `46fdd5ef39735f4159cdcf0ec5e85c10521494e5`.
`pinned/` retains the unmodified relevant Codex sources and its Cargo.lock.
Source checksums are in `pinned/SHA256SUMS`. Codex is Apache-2.0 licensed.
Its exact upstream `LICENSE` and `NOTICE` from this revision are retained in
`pinned/` alongside those sources. They were retrieved from
`https://raw.githubusercontent.com/openai/codex/46fdd5ef39735f4159cdcf0ec5e85c10521494e5/`.
The Runtime's modified Elixir metadata traversal adapts the Codex algorithm to
Backplane contracts, atom/string schema keys and validated boolean leaves;
`priv/codex/tool_search/LICENSE-codex` and `NOTICE-codex` retain the applicable
Apache-2.0 terms and upstream attribution in the published package.
The oracle Cargo.lock locks registry sources and checksums, including bm25 2.3.2,
deunicode 1.6.2, rust-stemmers 1.2.0, stop-words 0.9.0 (NLTK only),
unicode-segmentation 1.12.0 and fxhash 0.2.1. The metadata adapter follows the
pinned generic text traversal and DynamicToolHandler namespace defaults; it
maps Backplane's Contract fields and does not include MCP-specific search text.

Run `CARGO_BUILD_JOBS=2 cargo build --locked --manifest-path dev/tool_search_oracle/Cargo.toml`
then `python3 dev/tool_search_oracle/generate.py`. Vocabulary generation uses the
locked rust-stemmers crate's English test corpus in Cargo's registry cache.
This full vocabulary fixture is development/test material with its upstream
GPL-3.0 license preserved as LICENSE-snowball-vocabulary. It is excluded from the
Runtime package. Backplane's MIT license does not replace the Apache-2.0 terms
for Codex-derived material or the other shipped third-party notices.
Ordinary Elixir tests read checked-in fixtures; they do not
invoke this oracle or require Rust, Cargo, Python or a native helper.

Fixtures compare exact metadata text, transliteration, tokens and FxHash32 hashes;
all positive scores within four f32 ULP (absolute floor 1e-7), and exact ranking.
Ties use canonical-name order locally; the upstream scorer leaves ties unspecified.
The corpus includes recursive schemas, namespace defaults/custom tools, all
English Snowball test vocabulary, Unicode and unknowns, ASCII word boundaries,
including 894 leading/trailing punctuation cases and quoted stopwords,
repeated terms, rare-term IDF, length normalization, empty corpora, stopwords and
a deterministic real FxHash32 collision. Tests separately verify owner-local
corpora, consumed candidates and invalid public-runtime input.
