# Ollama Cloud Provider Preset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dedicated Ollama Cloud choice to the Add LLM Provider page without changing the existing local Ollama preset.

**Architecture:** Extend the static `Backplane.LLM.ProviderPreset` catalog with one `ollama-cloud` entry. The existing LiveView renders and selects catalog entries automatically, so implementation code stays in the catalog while focused unit and LiveView tests protect the visible option and exact form defaults.

**Tech Stack:** Elixir 1.18, Phoenix LiveView, ExUnit, PostgreSQL through devenv

---

## File Structure

- Modify `apps/backplane_llama/lib/backplane/llm/provider_preset.ex`: define the Ollama Cloud creation defaults beside local Ollama.
- Modify `apps/backplane_llama/test/backplane/llm/provider_preset_test.exs`: lock the catalog order and exact cloud surface configuration.
- Modify `apps/backplane_admin/test/backplane/admin/live/providers_live_test.exs`: prove the separate card is visible and selecting it populates cloud URLs.
- No schema, migration, LiveView implementation, component, or credential-policy file changes are needed.

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

Add `assert html =~ "Ollama Cloud"` after the existing `assert html =~ "Ollama"` assertion in the dedicated new-provider-page test. Add this separate selection test after the existing provider-preset selection test:

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

Expected: 30 tests, 0 failures. Existing LiveView missing-form-id warnings may remain; do not widen scope to fix them.

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

### Task 2: Record project knowledge and final evidence

**Files:**

- No repository files change in this task.

- [ ] **Step 1: Re-run final verification from the committed tree**

Run:

```bash
devenv shell -- mix test \
  apps/backplane_llama/test/backplane/llm/provider_preset_test.exs \
  apps/backplane_admin/test/backplane/admin/live/providers_live_test.exs
devenv shell -- mix format --check-formatted \
  apps/backplane_llama/lib/backplane/llm/provider_preset.ex \
  apps/backplane_llama/test/backplane/llm/provider_preset_test.exs \
  apps/backplane_admin/test/backplane/admin/live/providers_live_test.exs
git diff --check
git status --short --branch
```

Expected: 30 tests, 0 failures; formatting and diff checks pass; the branch is clean.

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
