Source revisions and lock identities were recorded in `source_inventory.md` and are not repeated here.

## Backplane

### Missing target package

command: `mix do --app backplane_ai_protocol cmd mix compile --warnings-as-errors`

result:

```text
warning: could not find application :backplane_ai_protocol
```

exit code: 0

interpretation: expected before W1.1 creates the package; this is not a new runtime failure.

### Umbrella compile

command: `mix compile --warnings-as-errors`

result: compilation failed after emitting the following pre-existing warning in
`apps/backplane_memory/lib/backplane/memory/memories/verification.ex:629`:

```text
warning: expected the module in &module.fun/arity to expand to a variable or an atom, got: repo()
```

exit code: 1

interpretation: pre-existing warning-as-error baseline, independent of the untracked `docs/ai-protocol/` work.

## Sigma

### Scoped test

command: `mix do --app sigma_ai cmd mix test`

result: `51 tests, 1 failure`; `Sigma.Ai.Providers.OpenAITest` fails because `Sigma.Logs.start_session/1` and `Sigma.Logs.stop_session/1` are unavailable in the isolated `sigma_ai` application.

exit code: 2

interpretation: pre-existing scoped extraction failure, unrelated to Backplane changes.

## Synapsis

### Scoped test

command: `mix do --app synapsis_provider cmd mix test`

result: `342 tests, 75 failures`; the failures are dominated by `ArgumentError: the table identifier does not refer to an existing ETS table` from `Synapsis.Provider.Registry`, including tests that exercise registry-backed persistence.

exit code: 2

interpretation: pre-existing scoped extraction/test-isolation failure, unrelated to Backplane changes. W1.1 must not broaden the Synapsis behavior contract from this current result.
