# Deferred candidate ownership and metadata search

## Owner isolation (#88)

DynamicRuntime keeps independent Dynamic instances keyed by the exact caller,
run ID and incarnation. An absent caller uses a private host-direct identity;
present callers must be nonempty strings. Run IDs must be nonempty strings and
incarnations positive integers. The private identity grants no authority.

Candidate bounds apply per owner. Partitions remain until Runtime shutdown;
there is no implicit refresh, expiry or eviction. Plugin receipts retain their
separate existing Dynamic state. Low-level Dynamic name collisions, snapshots,
and publication rules remain unchanged within each partition.

Publication still requires strict catalog admission and the current producer-bound
Conversation callback. A rejected stage leaves the owner's old partition intact.
An accepted stage consumes candidates; subsequent Conversation cancellation can
discard its pending catalog without restoring those candidates. Hosts must not
infer retry/reset semantics from cancellation. Results become executable only at
the next provider turn and cannot authorize another call in the same batch.

Validation uses the public DynamicRuntime API with an unmatched query and no
staging context, followed by successive real Conversations sharing one Runtime.
The second run failed before the fix with `dynamic tool namespace collision`.
Additional tests cover callers, run IDs, incarnations, host-direct use, invalid
identities, duplicate candidates, catalog collisions and failed-stage rollback.
Scoped CT07 and Conversation catalog tests cover publication, stale producers,
strict/current catalog checks and cancellation. Commands and results are recorded
in the delivery report; temporary red/green logs are development evidence only.

## Pinned metadata search (#87)

The generic metadata, tokenizer and BM25 compatibility target is Codex commit
`46fdd5ef39735f4159cdcf0ec5e85c10521494e5`. Search indexes each individually
admitted Backplane candidate. This scope does not include Codex's specialized
MCP search documents, namespace grouping or provider result aggregation.

Function documents contain the declared name, underscore-expanded name,
description, and recursive input-schema descriptions, sorted properties,
`items` and `anyOf`. Named namespaces add their name and optional
`metadata.namespace_description`; the default is `Tools in the <name> namespace.`,
except `functions`, whose default description is empty. Unnamespaced candidates
gain no implicit namespace. Custom tools index name, description and optional
`format.syntax`, with no function-name expansion. Output schemas, enum values,
`$defs`, grammar definitions, backend context and arbitrary metadata are excluded.

The pure Elixir implementation uses the exact deunicode 1.6.2 mapping, the NLTK
English stopwords from stop-words 0.9.0, English Snowball matching rust-stemmers
1.2.0, the applicable ASCII word boundaries of unicode-segmentation 1.12.0, and
FxHash32 token identities. BM25 follows 2.3.2 with `k1=1.2`, `b=0.75`, repeated
query-token contributions and per-operation f32 rounding. Equal scores use
canonical tool name ascending; the upstream leaves ties unspecified.

Only the requesting owner's still-discovered candidates contribute to corpus
statistics. Successfully staged candidates leave that corpus. A rejected stage
preserves the prior state. Search results retain the existing public summary
fields and publication boundary.

Missing, non-string, invalid UTF-8 and trimmed-empty queries return structured
validation errors. A nonblank query containing only stopwords is valid and has
no matches. Omitted limit is 8; explicit limits must be positive integers within
`max_results`. When `max_results` is below 8, callers must supply a smaller limit.

`dev/tool_search_oracle/` records the exact source pin, locked Rust crate
checksums, fixture generator and regeneration instructions. Checked-in fixtures
compare metadata, transliteration, tokens and hashes exactly; scores allow four
f32 ULP with an absolute floor of `1e-7`, and non-tied ordering must match.
Coverage includes the complete upstream English Snowball vocabulary, Unicode,
unknown characters, punctuation, contractions, decimals, underscores, repeated
terms, IDF, length normalization, empty corpora and an actual hash collision.
Normal tests consume those fixtures without invoking Rust. The vocabulary and
development oracle are excluded from the Hex package; production data and
third-party notices ship under Runtime `priv/codex/tool_search/`.
