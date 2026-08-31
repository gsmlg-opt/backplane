# Ollama Cloud Provider Preset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dedicated Ollama Cloud choice to the Add LLM Provider page without changing the existing local Ollama preset.

**Architecture:** Extend the static `Backplane.LLM.ProviderPreset` catalog with one `ollama-cloud` entry. The existing LiveView renders and selects catalog entries automatically, so implementation code stays in the catalog while focused unit and LiveView tests protect the visible option and exact form defaults.

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

**Files:**

- Modify: `apps/backplane_llama/test/backplane/llm/provider_preset_test.exs:6-75`
- Modify: `apps/backplane_admin/test/backplane/admin/live/providers_live_test.exs:53-138`
- Modify: `apps/backplane_llama/lib/backplane/llm/provider_preset.ex:154-176`

- [ ] **Step 1: Add the failing preset catalog expectations**

Add `"ollama-cloud"` immediately after `"ollama"` in the expected `ProviderPreset.keys/0` list. Add this test after the existing local Ollama test:

```elixir
test "ollama cloud uses hosted openai and anthropic compatibility defaults" do
  preset = ProviderPreset.fetch!("ollama-cloud")

  assert preset.name == "Ollama Cloud"
  assert preset.default_name == "ollama-cloud"
  assert preset.credential_kind == "llm"
  assert preset.credential_auth_type == "api_key"
  assert preset.default_base_url == "https://ollama.com"
  assert preset.openai.enabled
  assert preset.openai.base_url == "https://ollama.com/v1"
  assert preset.openai.discovery_path == "/models"
  assert preset.anthropic.enabled
  assert preset.anthropic.base_url == "https://ollama.com"
  assert preset.anthropic.discovery_path == "/v1/models"
end
```

- [ ] **Step 2: Add the failing Add Provider page expectations**

Change the dedicated new-provider-page test to retain `view`, then assert separate cards with `has_element?(view, "button[phx-value-preset='ollama']", "Ollama")` and `has_element?(view, "button[phx-value-preset='ollama-cloud']", "Ollama Cloud")` (alongside the text assertion). Add this separate selection test after the existing provider-preset selection test:

```elixir
test "ollama cloud preset populates hosted compatibility defaults", %{conn: conn} do
  {:ok, view, _html} = live(conn, "/llama/providers/new")

  view
  |> element("button[phx-value-preset='ollama-cloud']")
  |> render_click()

  assert has_element?(view, "#provider-name[value='ollama-cloud']")
  assert has_element?(view, "#provider-base-url[value='https://ollama.com']")
  assert has_element?(view, "#provider-openai-base-url[value='https://ollama.com/v1']")
  assert has_element?(view, "#provider-anthropic-base-url[value='https://ollama.com']")
  assert has_element?(view, "#provider-credential option[value='test-cred']")
  refute has_element?(view, "#provider-credential option[value='openai-codex']")
  refute has_element?(view, "#provider-credential option[value='google-antigravity']")

  refute has_element?(
           view,
           "#provider-openai-base-url[value='http://localhost:11434/v1']"
         )
end
```

- [ ] **Step 3: Run the scoped tests and verify RED**

Run:

```bash
devenv shell -- mix test \
  apps/backplane_llama/test/backplane/llm/provider_preset_test.exs \
  apps/backplane_admin/test/backplane/admin/live/providers_live_test.exs
```

Expected: FAIL because `ollama-cloud` is absent from `ProviderPreset.keys/0`, `ProviderPreset.fetch!/1` raises for the unknown key, and the LiveView has no `ollama-cloud` preset button.

- [ ] **Step 4: Add the minimal static preset**

Insert this map immediately after the existing `ollama` preset and before `custom` in `Backplane.LLM.ProviderPreset`:

```elixir
%{
  key: "ollama-cloud",
  name: "Ollama Cloud",
  default_name: "ollama-cloud",
  credential_kind: "llm",
  credential_auth_type: "api_key",
  default_base_url: "https://ollama.com",
  openai: %{
    enabled: true,
    base_url: "https://ollama.com/v1",
    discovery_path: "/models"
  },
  anthropic: %{
    enabled: true,
    base_url: "https://ollama.com",
    discovery_path: "/v1/models"
  },
  notes:
    "Ollama Cloud exposes hosted OpenAI-compatible and Anthropic-compatible endpoints using an Ollama API key.",
  docs_urls: [
    "https://docs.ollama.com/cloud",
    "https://docs.ollama.com/api/authentication",
    "https://docs.ollama.com/api/openai-compatibility",
    "https://docs.ollama.com/api/anthropic-compatibility"
  ]
},
```

- [ ] **Step 5: Format the changed Elixir files**

Run:

```bash
devenv shell -- mix format \
  apps/backplane_llama/lib/backplane/llm/provider_preset.ex \
  apps/backplane_llama/test/backplane/llm/provider_preset_test.exs \
  apps/backplane_admin/test/backplane/admin/live/providers_live_test.exs
```

Expected: command exits 0.

- [ ] **Step 6: Run the scoped tests and verify GREEN**

Run:

```bash
devenv shell -- mix test \
  apps/backplane_llama/test/backplane/llm/provider_preset_test.exs \
  apps/backplane_admin/test/backplane/admin/live/providers_live_test.exs
```

Expected: 11 + 19 = 30 tests, 0 failures. Existing LiveView missing-form-id warnings may remain; do not widen scope to fix them.

- [ ] **Step 7: Run static scoped checks**

Run:

```bash
devenv shell -- mix format --check-formatted \
  apps/backplane_llama/lib/backplane/llm/provider_preset.ex \
  apps/backplane_llama/test/backplane/llm/provider_preset_test.exs \
  apps/backplane_admin/test/backplane/admin/live/providers_live_test.exs
git diff --check
```

Expected: both commands exit 0 with no output from `git diff --check`.

- [ ] **Step 8: Review and commit the implementation**

Inspect only the approved files:

```bash
git diff -- \
  apps/backplane_llama/lib/backplane/llm/provider_preset.ex \
  apps/backplane_llama/test/backplane/llm/provider_preset_test.exs \
  apps/backplane_admin/test/backplane/admin/live/providers_live_test.exs
```

Stage and commit them:

```bash
git add \
  apps/backplane_llama/lib/backplane/llm/provider_preset.ex \
  apps/backplane_llama/test/backplane/llm/provider_preset_test.exs \
  apps/backplane_admin/test/backplane/admin/live/providers_live_test.exs
git commit -m "feat(llm): add Ollama Cloud provider preset"
```

Expected: one feature commit containing only the preset and its focused tests.

### Task 2: Constrain Ollama Cloud credentials test-first

**Files:**

- Modify: `apps/backplane_llama/test/backplane/llm/provider_preset_test.exs`
- Modify: `apps/backplane_admin/test/backplane/admin/live/providers_live_test.exs`
- Modify: `apps/backplane_llama/lib/backplane/llm/provider_preset.ex`

- [ ] **Step 1: Add failing API-key expectations**

Assert `preset.credential_auth_type == "api_key"` and verify the API-key credential remains available while `openai-codex` and `google-antigravity` are absent after selecting Ollama Cloud.

- [ ] **Step 2: Run the two scoped files and verify RED**

Expected: the new auth-type assertion fails and OAuth credential options remain visible.

- [ ] **Step 3: Add `credential_auth_type: "api_key"`**

Insert it immediately after `credential_kind` in the Ollama Cloud preset. The existing provider form filtering then enforces API-key-only selection.

- [ ] **Step 4: Run the two scoped files and verify GREEN**

Expected: 11 + 19 tests, 0 failures.

### Task 3: Preserve renamed Ollama Cloud Bearer auth test-first

**Files:**

- Modify: `apps/backplane_llama/test/backplane/llm/credential_plug_test.exs`
- Modify: `apps/backplane_llama/lib/backplane/llm/credential_plug.ex`

- [ ] **Step 1: Add the failing regression test**

Create an API-key credential and an Anthropic-surface provider named `anthropic-via-ollama` with `preset_key: "ollama-cloud"`; assert `build_auth_headers/1` returns `{"authorization", "Bearer <test token>"}` and not `{"x-api-key", "<test token>"}`.

- [ ] **Step 2: Run the focused test and verify RED**

Expected: the current name heuristic emits `x-api-key`.

- [ ] **Step 3: Add the narrow preset override**

Add `defp anthropic_api?(%Provider{preset_key: "ollama-cloud"}), do: false` before the existing name heuristic. Preserve all other preset and legacy behavior.

- [ ] **Step 4: Run the focused test and verify GREEN**

Expected: 17 tests, 0 failures.

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

- [ ] **Step 2: Save the required Agent Note**

Call `mcp__agent_note__save_note` with:

```json
{
  "title": "Backplane adds a dedicated Ollama Cloud LLM provider preset",
  "content": "Added the `ollama-cloud` provider preset beside the unchanged local `ollama` preset. Ollama Cloud defaults to `https://ollama.com/v1` for OpenAI compatibility and `https://ollama.com` for Anthropic Messages, with `/models` and `/v1/models` discovery paths respectively. Both surfaces reuse Backplane's existing Bearer credential handling. Verification: provider preset and provider LiveView scoped tests pass, formatting passes, and `git diff --check` passes.",
  "labels": [["project", "backplane"]]
}
```

Expected: the tool returns a new note id and revision.

---

## Scope Guard

Stop when the preset, the two focused test files, the final scoped checks, and the Agent Note are complete. Report but do not fix unrelated dependency advisories, the pre-existing LiveView missing-form-id warnings, or failures outside these scoped files.
