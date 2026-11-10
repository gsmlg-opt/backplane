# Memory Plan 5 — Agent Plugins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every client the user runs — Claude Code, Codex, Cursor, Hermes, OpenClaw — captures sessions through the local host agent and recalls/writes memory through the five `memory::` tools, installed from the host agent; Sigma and Synapsis are tracked upstream.

**Architecture:** One shared POSIX hook client (`backplane-memory-hook <integration> <hook>`) forwards hook stdin to the host agent capture endpoint and never fails the agent. Claude Code and Codex get official plugin packages (manifest + hooks + MCP config + skill) installed into a Backplane-owned local marketplace; Cursor gets merged `~/.cursor/hooks.json` / `mcp.json` entries and a host adapter. Hermes and OpenClaw keep their plugins but drop the deleted partition/authorization protocol and call `memory::search|get|recent|remember|forget`. The resident "remember when worth it" instruction has one canonical text served in the host MCP `initialize` response and mirrored into each package.

**Tech Stack:** Elixir (host agent, memory contract, admin), POSIX sh + curl, JSON plugin manifests, Python 3.12 (Hermes), Node 24 ESM (OpenClaw).

**Spec:** `docs/superpowers/specs/2026-11-09-memory-simplification-design.md` (§6.4(a), §6.7, §6.8, §6.10, §8.8)

## Global Constraints

- Shared hook client: reads stdin JSON → POSTs to the local host agent capture endpoint → **a failure never affects the agent** (spec §6.8); shipped with the host agent release.
- Claude Code, Codex, Cursor: capture hooks + MCP pointing at host agent `/memory/:agent_id/mcp` + the §6.4(a) resident instruction (spec §6.8).
- Resident instruction (§6.4(a), user decision "方式 B"): only a standing instruction — after finishing work, if something is worth remembering, call `memory::remember` (with `session_id` when known); **no blocking Stop hook, no forced extra turn**.
- Cursor host-side adapter: `conversation_id`, `workspace_roots`, camelCase event names (spec §6.8).
- Hermes, OpenClaw: keep plugins, delete partition/authorization-negotiation parts, recall via the new tools (spec §6.8).
- Sigma, Synapsis: `internal request` issues in `gsmlg-opt/sigma` and `gsmlg-opt/Synapsis`; no code in their repos from this plan (spec §6.8, AGENTS.md upstream rules).
- `PluginInstaller` and the admin plugin catalog cover all five clients (spec §6.8).
- Claude Code hooks must not depend on a dev checkout (`mix memory.connect`) (spec §6.10).
- Installs never edit files outside the user's home; installs into a client's own config are reversible (`remove`) and keep a one-time backup of any file they merge into.
- Host agent defaults: HTTP `127.0.0.1:4222`; agent ids `claude-code`, `codex`, `cursor`, `hermes`, `openclaw`.
- Commits: Conventional Commits; never add "Generated with Claude Code" or a `Co-Authored-By: Claude` trailer. macOS dev: Postgres.app (`unset PGHOST`), never devenv. Explicitly format app files: the root `.formatter.exs` does not cover `apps/**` — run `mix format <files>` and check with `git diff --name-only <base>..HEAD -- 'apps/*.ex' 'apps/*.exs' | xargs mix format --check-formatted`.

## Review Focus

1. Host agent down / port closed / slow: the hook client must return within ~2 s with exit 0 and print nothing that the client treats as an error or block. (Task 1 test)
2. Hook stdin larger than the shell's argument limits or containing quotes/newlines/NUL-free binary-ish UTF-8 must be forwarded byte-for-byte (stdin streamed, never interpolated). (Task 1 test)
3. Re-running install over an existing install, or installing when the user already has their own entries in `~/.cursor/hooks.json` / `mcp.json`, must not duplicate or clobber the user's entries; `remove` restores exactly the user's own content. (Task 6 test)
4. A Hermes/OpenClaw plugin talking to an older host agent, or getting `gateway_unavailable` (503) from `/call`, must degrade (no recall context, writes retried/queued by the host) without raising into the agent. (Tasks 8, 9 tests)
5. Drift: the instruction text in packages must equal the canonical text served by MCP `initialize`. (Task 3 test)

---

## Shared contracts

**Hook client** — `integrations/memory/shared/bin/backplane-memory-hook` (POSIX sh, mode 0755):
`backplane-memory-hook <integration> <hook>`; URL base from `$BACKPLANE_HOST_AGENT_URL` else the base baked in at install (`__HOST_AGENT_URL__` placeholder replaced by the installer) else `http://127.0.0.1:4222`; `curl -sS --max-time 2 -H 'content-type: application/json' --data-binary @- "$base/capture/v1/hooks/$integration/$hook"`, all output discarded; always `exit 0`. For `cursor` + `beforeSubmitPrompt` it prints `{"continue":true}` to stdout (Cursor reads that hook's response); otherwise prints nothing.

**Host MCP** — `POST /memory/<agent_id>/mcp` (JSON-RPC; `initialize` gains `"instructions"`), direct calls `POST /memory/<agent_id>/call/<search|get|recent|remember|forget>` with the tool arguments as the JSON body → `200 {"ok":true,"result":…}` or `{"ok":false,"error":<string>}` with 503/504/404/403/500/400.

**Install target layout** (`<data>` = `~/.local/share/backplane`):
| client | installed to | client-side step |
|---|---|---|
| claude_code | `<data>/plugins/claude/` marketplace (`.claude-plugin/marketplace.json`, name `backplane-local`) containing `backplane-memory/` | `claude plugin marketplace add <data>/plugins/claude` then `claude plugin install backplane-memory@backplane-local` |
| codex | `<data>/plugins/codex/` marketplace (`.agents/plugins/marketplace.json`, same entry shape as `AgentPlugins.export_codex/3`) containing `plugins/backplane-memory/` | `codex plugin marketplace add <data>/plugins/codex` then enable `backplane-memory` |
| cursor | merges into `~/.cursor/hooks.json` and `~/.cursor/mcp.json`; backups `*.backplane-backup` | restart Cursor |
| hermes | `~/.hermes/plugins/backplane-memory` (existing) | — |
| openclaw | `~/.openclaw/extensions/backplane-memory` (existing) | — |
All installs also copy the hook client to `<data>/bin/backplane-memory-hook` (0755). Install results carry `next_steps: [String.t()]` with the client-side commands (the installer never runs other CLIs).

---

### Task 1: Shared hook client

**Files:**
- Create: `integrations/memory/shared/bin/backplane-memory-hook`
- Create: `apps/backplane_host_agent/test/backplane/host_agent/memory/hook_client_test.exs`

**Interfaces:** Produces the script contract above.

- [ ] **Step 1: Write failing tests** (start a `Plug.Cowboy`/Bandit test server on a random port that records requests; run the script with `System.cmd("sh", [script, integration, hook], env: [{"BACKPLANE_HOST_AGENT_URL", base}], into: …)` feeding stdin via a temp file + `sh -c 'script … < file'`):
  - posts body byte-for-byte to `/capture/v1/hooks/claude_code/PostToolUse` with `content-type: application/json`; a 300 KB payload with quotes, `$(…)`, backticks and newlines arrives intact (Review Focus 2);
  - closed port → exit 0 within 3 s, empty stdout; server that sleeps 10 s → exit 0 within 4 s (Review Focus 1);
  - `cursor beforeSubmitPrompt` → stdout `{"continue":true}`; `cursor stop` → empty stdout;
  - missing args → exit 0, no request.
- [ ] **Step 2: Run** `mix test apps/backplane_host_agent/test/backplane/host_agent/memory/hook_client_test.exs` — FAIL.
- [ ] **Step 3: Implement** the script (`set -u`, no `-e`; `command -v curl` absent → exit 0).
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(host_agent): add shared memory hook client`

### Task 2: Cursor capture adapter + hook inventory

**Files:**
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/hooks/cursor.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/hooks.ex` (`@adapters`, `availability/1`)
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/hooks/claude_code.ex` (add `supported_hooks/0`)
- Test: `apps/backplane_host_agent/test/backplane/host_agent/memory/cursor_hook_test.exs`, extend `hooks_inventory_test.exs`

**Interfaces:** `Hooks.Cursor.normalize(hook, source, config)` and `supported_hooks/0`, same contract as `Hooks.Codex`.

Cursor hooks → event types: `sessionStart`→`agent.session.started`, `beforeSubmitPrompt`→`agent.prompt.submitted`, `postToolUse`→`agent.tool.completed`, `afterShellExecution`→`agent.tool.completed`, `afterFileEdit`→`agent.tool.completed`, `afterAgentResponse`→`conversation.agent_message`, `stop`→`agent.session.stopped`, `sessionEnd`→`agent.session.ended`. `session_id` = `conversation_id` (required); project = first `workspace_roots` entry; `agent_id` default `"cursor"`; idempotency key `"cursor:<conversation_id>:<canonical_hook>:<digest(generation_id || source digest)>"`; `client_id`/`integration` `"cursor"`; payload `"source"` = the raw input; `tool_name` from `tool_name` or `"Shell"`/`"Edit"` for the two after-hooks. Claude Code `supported_hooks/0` returns `~w(SessionStart UserPromptSubmit PostToolUse PostToolUseFailure PreCompact SubagentStart SubagentStop Stop SessionEnd)`.

- [ ] **Step 1: Write failing tests**: each hook maps to its event type; missing `conversation_id` → `{:error, {:malformed, [:conversation_id]}}`; `workspace_roots: ["/w/a","/w/b"]` → project `/w/a`; camelCase, kebab and lower-case hook names resolve; `Hooks.availability("cursor")` supported; inventory counts for cursor (8) and claude_code (9). Also an end-to-end capture via the router (`POST /capture/v1/hooks/cursor/beforeSubmitPrompt`) like `capture_router_test.exs` → 202.
- [ ] **Step 2: Run** `mix test apps/backplane_host_agent/test/backplane/host_agent/memory/cursor_hook_test.exs apps/backplane_host_agent/test/backplane/host_agent/memory/hooks_inventory_test.exs` — FAIL.
- [ ] **Step 3: Implement**; add `"cursor"` to the gateway `EventValidator` only if an event type above is missing from `@canonical_types` (all are present today — verify).
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(host_agent): capture Cursor hooks`

### Task 3: Canonical resident instruction

**Files:**
- Modify: `apps/backplane_memory_contract/lib/backplane/memory_tool_contract.ex` (add `instructions/0`)
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory_router.ex` (`initialize` result gains `"instructions" => MemoryToolContract.instructions()`)
- Create: `integrations/memory/shared/INSTRUCTIONS.md` (exactly `instructions/0` + trailing newline)
- Test: `apps/backplane_memory_contract/test/…/memory_tool_contract_test.exs`, `memory_router_test.exs`, and `apps/backplane_host_agent/test/backplane/host_agent/memory/integration_packages_test.exs` (new; grows in Tasks 4–6)

**Interfaces:** `MemoryToolContract.instructions() :: String.t()`.

Exact text:
```
Backplane Memory is shared by all of the user's agents and hosts.
- Before you search a machine for a repo, service, path or past procedure, call memory::search (filters: host, kind, subject). Results show where each memory came from.
- When you finish a piece of work and learned something worth keeping — where something lives, how an operation is done, or what you did — call memory::remember once with kind fact, procedure, worklog or note, subjects like host:<name>, repo:<name>, service:<name>, path:<path>, and the current session_id when you know it. Most sessions need nothing remembered.
- If the user says something is outdated or should be forgotten, call memory::forget with a reason.
```

- [ ] **Step 1: Write failing tests**: `instructions/0` equals the text; host MCP `initialize` returns it; `integrations/memory/shared/INSTRUCTIONS.md` content == `instructions() <> "\n"` (Review Focus 5).
- [ ] **Step 2: Run** the three test files — FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(memory): serve resident memory instructions over host MCP`

### Task 4: Claude Code package + installer mode

**Files:**
- Create: `integrations/memory/claude_code/backplane-memory/.claude-plugin/plugin.json` (`name` `backplane-memory`, `version`, `description`)
- Create: `…/backplane-memory/hooks/hooks.json` — for each of the 9 Claude hooks a `{"type":"command","command":"__HOOK_CLIENT__ claude_code <Hook>"}` entry (PostToolUse/PostToolUseFailure with `"matcher":"*"`)
- Create: `…/backplane-memory/.mcp.json` — `{"mcpServers":{"backplane-memory":{"type":"http","url":"__HOST_AGENT_URL__/memory/claude-code/mcp"}}}`
- Create: `…/backplane-memory/skills/backplane-memory/SKILL.md` — frontmatter `name: backplane-memory`, `description: Use Backplane shared memory: search before exploring hosts/repos/services; remember durable facts, procedures and worklogs after finishing work.`; body = `INSTRUCTIONS.md`
- Create: `integrations/memory/claude_code/.claude-plugin/marketplace.json` — `{"name":"backplane-local","owner":{"name":"Backplane"},"plugins":[{"name":"backplane-memory","source":"./backplane-memory","description":…}]}`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/plugin_installer.ex` (runtime `claude_code`, mode `:marketplace`)
- Modify: `mix.exs` `copy_host_agent_integrations/1` (stamp `claude_code/backplane-memory/.claude-plugin/plugin.json` version)
- Test: `plugin_installer_test.exs`, `integration_packages_test.exs`

**Interfaces:**
- `PluginInstaller.install("memory", "claude_code", opts) :: {:ok, %{target_path:, next_steps: [String.t()], …}}`; `remove/3`, `status/3` likewise. `opts[:host_agent_url]` (default from host agent config `http://<http_bind>:<http_port>`), `opts[:data_dir]` (default `~/.local/share/backplane`), `opts[:home_dir]`.
- Render step (shared by Tasks 5–6): copy the package tree, replace `__HOOK_CLIENT__` with `<data>/bin/backplane-memory-hook` and `__HOST_AGENT_URL__` with the URL in every `.json`; copy the hook client to `<data>/bin/` (0755); stage-then-rename like the existing directory mode.

- [ ] **Step 1: Write failing tests**: package JSON files parse; `SKILL.md` body == `INSTRUCTIONS.md`; hooks.json lists exactly `Hooks.ClaudeCode.supported_hooks/0`; install into a tmp home/data → marketplace.json + rendered `.mcp.json` URL `http://127.0.0.1:4232/memory/claude-code/mcp` (opts URL) + hook commands use the absolute client path + client is executable; `next_steps` == the two `claude plugin …` commands with the marketplace path; reinstall idempotent; remove deletes `<data>/plugins/claude` but keeps `<data>/bin` if another client still installed.
- [ ] **Step 2: Run** `mix test apps/backplane_host_agent/test/backplane/host_agent/plugin_installer_test.exs apps/backplane_host_agent/test/backplane/host_agent/memory/integration_packages_test.exs` — FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(host_agent): package and install the Claude Code memory plugin`

### Task 5: Codex package + installer mode

**Files:**
- Create: `integrations/memory/codex/plugins/backplane-memory/.codex-plugin/plugin.json` (`name`, `version`, `description`), `…/hooks.json` (Codex hooks from `Hooks.Codex.supported_hooks/0` minus `PreToolUse`/`PermissionRequest`, command `__HOOK_CLIENT__ codex <Hook>`), `…/.mcp.json` (`backplane-memory` → `__HOST_AGENT_URL__/memory/codex/mcp`), `…/skills/backplane-memory/SKILL.md` (same as Task 4)
- Create: `integrations/memory/codex/.agents/plugins/marketplace.json` — `{"name":"backplane-local","plugins":[{"name":"backplane-memory","source":{"source":"local","path":"./plugins/backplane-memory"},"description":…}]}`
- Modify: `plugin_installer.ex` (runtime `codex`, mode `:marketplace`), `mix.exs` (stamp `.codex-plugin/plugin.json`)
- Test: as Task 4

Before implementing, check the installed `codex` CLI (`codex plugin --help`, `codex plugin marketplace --help`) for the exact marketplace/hooks/MCP file names and record what you found in the report; if they differ from the above, follow the CLI and note it.

- [ ] **Step 1–5** as Task 4 with `codex` names; `next_steps` = `codex plugin marketplace add <data>/plugins/codex` plus the enable command the CLI documents. Commit `feat(host_agent): package and install the Codex memory plugin`.

### Task 6: Cursor config merge + installer mode

**Files:**
- Create: `integrations/memory/cursor/hooks.json` (`{"version":1,"hooks":{<each Task 2 hook>:[{"command":"__HOOK_CLIENT__ cursor <hook>"}]}}`), `integrations/memory/cursor/mcp.json` (`{"mcpServers":{"backplane-memory":{"url":"__HOST_AGENT_URL__/memory/cursor/mcp"}}}`)
- Modify: `plugin_installer.ex` (runtime `cursor`, mode `:cursor_config`)
- Test: `plugin_installer_test.exs`

Merge rules: Backplane entries are identified by command containing `backplane-memory-hook` (hooks) and key `backplane-memory` (mcp). Install: back up each existing file once to `<file>.backplane-backup` (only if no backup exists), remove prior Backplane entries, append ours, keep every other key/entry and the user's order, write atomically. Remove: delete only Backplane entries; leave the file (and backup) otherwise untouched. Invalid existing JSON → `{:error, {:invalid_json, path}}`, nothing written. `next_steps`: `["Restart Cursor"]`.

- [ ] **Step 1: Write failing tests** (Review Focus 3): fresh install creates both files; install over user-owned hooks/mcp keeps them and adds ours; double install does not duplicate; remove restores the user's original JSON (decoded equality); invalid JSON → error, file unchanged; backup written once.
- [ ] **Step 2–4** run/implement/run (`plugin_installer_test.exs`).
- [ ] **Step 5: Commit** `feat(host_agent): install Cursor memory hooks and MCP config`

### Task 7: Admin catalog and host tools

**Files:**
- Modify: `apps/backplane_skills/lib/backplane/skills/agent_plugins.ex` (`packaged_plugins/0` runtimes = `claude_code codex cursor hermes openclaw`)
- Modify: `apps/backplane_admin/lib/backplane/admin/live/host_agents_live.ex` (`@memory_plugin_rows` for all five with target paths from the layout table; show `next_steps` from install results in the flash/row)
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/services/plugins.ex` (`runtime` enum = `PluginInstaller.runtimes("memory")`)
- Test: `host_agents_live_test.exs`, `services_test.exs`

- [ ] **Step 1: Write failing tests**: plugin tab lists five rows; install of `claude_code` shows the returned next steps; tool schema enumerates the five runtimes.
- [ ] **Step 2–4**; **Step 5: Commit** `feat(admin): list all memory plugin clients`

### Task 8: Hermes plugin on the new tools

**Files:** `integrations/memory/hermes/*` (`__init__.py`, `source.py`, `source_contract.py`, `rollout.py`, `delivery.py`, `capture.py`, `context.py`, `plugin.yaml`, `README.md`) and `integrations/memory/tests/test_hermes*.py`, `hermes_http_acceptance.py`

Target behavior:
- Delete: `memory_access_id` config/env, partition/binding/authority codes, `source_capabilities`/`source_status`/`list` calls, `rollout.py` if it only serves those.
- Recall: `prefetch`/`queue_prefetch` call `POST /memory/hermes/call/search` with `{"query": <turn text>, "limit": 8}` and render results with provenance (host, agent, kind, observed_at).
- Tools exposed to Hermes: `memory_search` → search, `memory_remember` → remember (passes `session_id`), `memory_forget` → forget; `memory_get`/`memory_recent` → get/recent.
- `on_memory_write` → remember (kind `note`, writer agent, `session_id`).
- `system_prompt_block` returns `INSTRUCTIONS.md` (read from `../shared/INSTRUCTIONS.md` relative to the plugin when present, else the bundled copy the installer places beside `__init__.py`).
- Capture hooks unchanged (`/capture/v1/hooks/hermes/<hook>`).
- Any non-2xx or transport error from `/call` → no recall context, a single warning log, no exception into Hermes (Review Focus 4).
- Installer (`plugin_installer.ex` hermes runtime): also copy `shared/INSTRUCTIONS.md` into the target.

- [ ] **Step 1: Write failing tests** (update the suite; delete tests of removed protocol): search request shape; remember carries `session_id`; 503 → empty context + no raise; system prompt == INSTRUCTIONS.md; no reference to `memory_access_id|partition|source_capabilities|recall` remains (`grep` assertion in a test).
- [ ] **Step 2: Run** `PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s integrations/memory/tests -p 'test_hermes*.py' -v` — FAIL.
- [ ] **Step 3–4** implement / PASS; also `mix test` the hermes hook and installer tests.
- [ ] **Step 5: Commit** `feat(memory): move the Hermes plugin to the global memory tools`

### Task 9: OpenClaw plugin on the new tools

**Files:** `integrations/memory/openclaw/*` and `integrations/memory/tests/test_openclaw.mjs`

Same target behavior as Task 8 with agent id `openclaw`: delete `memory_access_id`/`authorize()`/`source_*`/`rollout` access logic and their config-schema fields in `openclaw.plugin.json`; `before_prompt_build` → search; tools `backplane_memory_search|remember|forget|get|recent`; system context includes INSTRUCTIONS.md; capture via `/capture/v1/hooks/openclaw/<hook>` unchanged; 503/transport errors degrade silently with one warning (Review Focus 4). Keep `Backplane.OpenClawCaptureContract` unchanged.

- [ ] **Step 1: Write failing tests**; **Step 2: Run** `node --test integrations/memory/tests/test_openclaw*.mjs` — FAIL; **Step 3–4**; **Step 5: Commit** `feat(memory): move the OpenClaw plugin to the global memory tools`

### Task 10: CI, docs, packaging check

**Files:**
- Modify: `.github/workflows/memory-plugins.yml` (add `hook_client_test.exs`, `cursor_hook_test.exs`, `integration_packages_test.exs`, `plugin_installer_test.exs` to the adapter step; packaged-release step asserts `priv/integrations/memory/{shared/bin/backplane-memory-hook,claude_code,codex,cursor}` exist and the hook client is executable; remove the "OpenClaw live acceptance removed until Plan 5" comment)
- Modify: `test/ci_workflow_test.exs` only if it pins the changed workflow lines
- Modify: `docs/architecture/memory.md` (Plugins section: hook client, per-client install table, instruction source), `docs/deploy/host_agent.md` (install commands per client), integration READMEs
- [ ] **Step 1**: make the changes; **Step 2: Run** `mix run --no-start test/ci_workflow_test.exs`, `MIX_ENV=prod mix release host_agent --overwrite` then list the packaged files; **Step 3: Commit** `ci(memory): test and package all memory plugins`

### Task 11: Upstream issues + live verification (controller)

- [ ] Open `internal request` feature issues (label created if missing) in `gsmlg-opt/sigma` and `gsmlg-opt/Synapsis`: title `[internal] Backplane Memory backend via host agent`, requesting repo/branch `gsmlg-opt/backplane@main`, expected behavior (capture to `POST /capture/v1/hooks/<integration>/<hook>` with a new host adapter added here on request; recall/write via `/memory/<agent_id>/mcp` tools `memory::search|get|recent|remember|forget`; resident instruction text), severity `needed`. Record URLs in `docs/architecture/memory.md`.
- [ ] Live (spec §8.8), against the dev gateway + a throwaway dev host agent on port 4232, with each client's config isolated (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `HOME=<tmp>` for `cursor-agent` and Hermes) so the user's real configs and production host agent are untouched: for Claude Code, Codex, cursor-agent and Hermes — install via `host_agent::install_plugin`, run one short real session that reads/edits a file, confirm capture events + session close + distillation records + `memory::search` from the client returns them. OpenClaw (not installed locally): packaged tests only — state this in the report.
- [ ] Gate: compile `--warnings-as-errors`, credo `--strict`, dialyzer, explicit app-file format check, memory/host_agent/admin suites, Hermes/OpenClaw suites, `ci_workflow_test`.
