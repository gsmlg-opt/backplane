# Ollama Cloud Provider Preset Design

## Goal

Add Ollama Cloud as a dedicated choice on the Add LLM Provider page while keeping the existing local Ollama preset unchanged.

## Scope

The feature adds one static `Backplane.LLM.ProviderPreset` entry:

- key: `ollama-cloud`
- display name: `Ollama Cloud`
- default provider name: `ollama-cloud`
- credential kind: `llm`
- default base URL: `https://ollama.com`

The preset enables both supported API surfaces:

| Surface | Base URL | Model discovery path |
| --- | --- | --- |
| OpenAI-compatible | `https://ollama.com/v1` | `/models` |
| Anthropic Messages | `https://ollama.com` | `/v1/models` |

The existing `ollama` preset continues to point to `http://localhost:11434` and remains a separate card.

## Architecture and Data Flow

`Backplane.LLM.ProviderPreset.all/0` remains the single source of creation defaults. `Backplane.Admin.ProviderNewLive` already renders every catalog entry and builds the form from the selected preset, so no new UI component or event handler is needed.

When a user selects Ollama Cloud, the existing form fills both cloud surface URLs and requires an existing `llm` credential. Saving creates the provider and its enabled `llm_provider_apis` rows through the current transaction. Runtime requests reuse `Backplane.LLM.CredentialPlug`; because Ollama Cloud is a third-party Anthropic-compatible provider, both surfaces receive `Authorization: Bearer <token>`.

## Errors and Security

No new error type is introduced. Missing credentials, invalid URLs, provider persistence failures, model-discovery failures, and upstream authentication failures continue through the existing provider flow.

The preset stores only a credential reference. The Ollama API key remains in Backplane's encrypted credential store and is never embedded in the preset or provider URL.

## Testing

Use test-driven development with focused coverage:

1. Extend `ProviderPresetTest` first so it fails while `ollama-cloud` is absent, then assert the exact cloud URLs, both enabled surfaces, discovery paths, and preservation of local Ollama defaults.
2. Extend `ProvidersLiveTest` so the Add LLM Provider page must render a separate Ollama Cloud card and selecting it must populate the cloud defaults without changing the local Ollama selection.
3. Run the two scoped test files, formatting checks for changed Elixir files, and `git diff --check`.

No migration, schema change, credential-policy change, or unrelated UI cleanup is in scope.

## Sources

- [Ollama Cloud](https://docs.ollama.com/cloud)
- [Ollama authentication](https://docs.ollama.com/api/authentication)
- [Ollama OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility)
- [Ollama Anthropic compatibility](https://docs.ollama.com/api/anthropic-compatibility)
