# Ollama Cloud Provider Preset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dedicated Ollama Cloud choice to the Add LLM Provider page without changing the existing local Ollama preset.

**Architecture:** Add a static `Backplane.LLM.ProviderPreset` `ollama-cloud` entry with an API-key credential constraint, plus a narrow `CredentialPlug` `ollama-cloud` clause that keeps Anthropic-surface Bearer auth independent of the editable provider display name. The existing LiveView remains catalog-driven and focused tests protect the visible option, exact form defaults, and both auth safeguards.

**Tech Stack:** Elixir 1.18, Phoenix LiveView, ExUnit, PostgreSQL through devenv

---

## File Structure

- Modify `apps/backplane_llama/lib/backplane/llm/provider_preset.ex`: define the Ollama Cloud creation defaults and API-key credential constraint beside local Ollama.
- Modify `apps/backplane_llama/test/backplane/llm/provider_preset_test.exs`: lock the catalog order, exact cloud surface configuration, and API-key auth type.
- Modify `apps/backplane_admin/test/backplane/admin/live/providers_live_test.exs`: prove the separate card is visible, selecting it populates cloud URLs, and only API-key credentials are offered.
- Modify `apps/backplane_llama/lib/backplane/llm/credential_plug.ex`: preserve Bearer auth for renamed providers whose preset is `ollama-cloud`.
- Modify `apps/backplane_llama/test/backplane/llm/credential_plug_test.exs`: regress renamed Ollama Cloud Anthropic-surface Bearer auth.
- No schema, migration, LiveView implementation, component, or broad credential-policy changes are needed.

### Task 1: Add the Ollama Cloud preset test-first

**Files:** `provider_preset_test.exs`, `providers_live_test.exs`, and `provider_preset.ex`

- [ ] Add `"ollama-cloud"` after `"ollama"`, and add the cloud preset test with exact name, default name, credential kind, URLs, enabled surfaces, and discovery paths (without an auth-type assertion).
- [ ] Add `assert html =~ "Ollama Cloud"` and the cloud selection test asserting the four cloud form values plus the local OpenAI URL is absent. Do not add OAuth filtering or exact local/cloud button selectors in this task.
- [ ] Run the two scoped files. RED must show the missing key, unknown preset, and missing cloud button.
- [ ] Add the static preset map after local Ollama and before custom, without `credential_auth_type`.
- [ ] Run `devenv shell -- mix format` on the three files, then rerun the two files. GREEN must be 11 + 19 = 30 tests, 0 failures.
- [ ] Run exact-file `mix format --check-formatted` and `git diff --check`; commit only the three files as `feat(llm): add Ollama Cloud provider preset`.

### Task 2: Constrain Ollama Cloud credentials test-first

**Files:** the same preset/UI files as Task 1.

- [ ] Add `assert preset.credential_auth_type == "api_key"` to the cloud unit test. In the existing cloud LiveView selection test, add:

```elixir
assert has_element?(view, "#provider-credential option[value='test-cred']")
refute has_element?(view, "#provider-credential option[value='openai-codex']")
refute has_element?(view, "#provider-credential option[value='google-antigravity']")
```

  In the dedicated new-provider-page test, retain `view` and add:

```elixir
assert has_element?(view, "button[phx-value-preset='ollama']", "Ollama")
assert has_element?(view, "button[phx-value-preset='ollama-cloud']", "Ollama Cloud")
```

- [ ] Run `devenv shell -- mix test apps/backplane_llama/test/backplane/llm/provider_preset_test.exs apps/backplane_admin/test/backplane/admin/live/providers_live_test.exs`. RED must show the missing auth type and OAuth options still present.
- [ ] Add `credential_auth_type: "api_key"` immediately after `credential_kind` in the cloud map.
- [ ] Rerun the same command; GREEN must be 11 + 19 = 30 tests, 0 failures. Run exact-file formatting for these three files and `git diff --check`.
- [ ] Commit only these three files as `fix(llm): constrain Ollama Cloud credentials`.

### Task 3: Preserve renamed Ollama Cloud Bearer auth test-first

**Files:** `apps/backplane_llama/test/backplane/llm/credential_plug_test.exs` and `apps/backplane_llama/lib/backplane/llm/credential_plug.ex`

- [ ] Add this complete regression test under `describe "build_auth_headers/1"`:

```elixir
test "preserves bearer auth for a renamed Ollama Cloud provider" do
  Credentials.store("ollama-cloud-cred", "ollama-cloud-test-token", "llm")

  {:ok, provider} =
    Provider.create(%{
      name: "anthropic-via-ollama",
      preset_key: "ollama-cloud",
      api_type: :anthropic,
      api_url: "https://ollama.com",
      credential: "ollama-cloud-cred",
      models: ["llama3.2"]
    })

  assert {:ok, headers} = CredentialPlug.build_auth_headers(provider)
  assert {"authorization", "Bearer ollama-cloud-test-token"} in headers
  refute {"x-api-key", "ollama-cloud-test-token"} in headers
end
```

- [ ] Run `devenv shell -- mix test apps/backplane_llama/test/backplane/llm/credential_plug_test.exs`. RED must show `x-api-key` instead of the expected Bearer header.
- [ ] Add exactly `defp anthropic_api?(%Provider{preset_key: "ollama-cloud"}), do: false` before the existing name heuristic, leaving all other behavior unchanged.
- [ ] Rerun the focused command; GREEN must be 17 tests, 0 failures. Run exact-file formatting for both files and `git diff --check`.
- [ ] Commit only these two files as `fix(llm): preserve Ollama Cloud bearer auth`.

### Task 4: Record project knowledge and final evidence

**Files:**

- No repository files change in this task.

- [ ] **Step 1: Re-run final verification from the committed tree**

Run:

```bash
devenv shell -- mix test \
  apps/backplane_llama/test/backplane/llm/provider_preset_test.exs \
  apps/backplane_admin/test/backplane/admin/live/providers_live_test.exs \
  apps/backplane_llama/test/backplane/llm/credential_plug_test.exs
devenv shell -- mix format --check-formatted \
  apps/backplane_llama/lib/backplane/llm/provider_preset.ex \
  apps/backplane_llama/test/backplane/llm/provider_preset_test.exs \
  apps/backplane_admin/test/backplane/admin/live/providers_live_test.exs \
  apps/backplane_llama/lib/backplane/llm/credential_plug.ex \
  apps/backplane_llama/test/backplane/llm/credential_plug_test.exs
git diff --check
git status --short --branch
```

Expected: 11 + 19 + 17 = 47 tests, 0 failures; formatting and diff checks pass; the branch is clean.

- [ ] **Step 2: Update the required Agent Note in place**

First call `mcp__agent_note__read_note_lines` with the exact existing note id `a3c8b5fe-d602-40c1-8097-300115439bea`.

Use the returned `revision` and `tag` unchanged in `mcp__agent_note__edit_note`. Submit one `swap` edit spanning line 1 through the final numbered body line, replacing the full body with this refreshed body:

> Added the `ollama-cloud` provider preset beside the unchanged local `ollama` preset. Ollama Cloud defaults to `https://ollama.com/v1` for OpenAI compatibility and `https://ollama.com` for Anthropic Messages, with `/models` and `/v1/models` discovery paths respectively. The preset only accepts API-key credentials, excluding unrelated OAuth tokens, and renamed Ollama Cloud providers retain `Authorization: Bearer` on the Anthropic-compatible surface. Verification: 28 scoped Backplane Llama tests and 19 provider LiveView tests pass, formatting passes, and `git diff --check` passes.

The expected title (`Backplane adds a dedicated Ollama Cloud LLM provider preset`) and `project: backplane` label are invariants; `edit_note` changes only the body.

Then call `mcp__agent_note__get_note` with the exact same note id and verify the expected title, exact refreshed body, and `project: backplane` label. The expected result is the same note id with its revision incremented by one and no duplicate note created.

---

## Scope Guard

Stop when the preset, the three focused test files, the final scoped checks, and the Agent Note are complete. Report but do not fix unrelated dependency advisories, the pre-existing LiveView missing-form-id warnings, or failures outside these scoped files.
