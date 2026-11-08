# Final review cleanup report

1. Host-agent sample YAML (config.ex): removed bound_scope, tombstone_relearn, host_sync, import_profiles. Test: config_test.exs sample assertions (refute).
2. Removed "Last worker negotiation" blocks (host_agents_live.ex), valid_negotiation?/safe_negotiation/memory_negotiation (agent_manage.ex). Tests: agent_manage_test, host_agents_live_test updated.
3. AGENTS.md: /api/memory/* row deleted.
4. host-agent.local.yaml.example: stripped bound_scope/tombstone_relearn/host_sync, added superseded comment.
5. dispatch.ex: resources/list and templates return [], resources/read returns not_found; memory_service probing removed. Tests: dispatch_test (new "resources have no providers"), modern_mcp_test, modern_server_test fixtures removed.
6. Audit @contract_operations trimmed to the written set: memory.config.set, projection.repair, session.abandoned, session.lifecycle_transition (remember/forget are not written by any caller, so omitted).
7. Ingest: event "scope" no longer filtered/stored; V1 upcaster drops "scope" (and atom) instead of source_scope aliases. Tests: ingest_test, upcaster_v1_test assert scope absent.
8. host_agent_channel.ex: removed host_agent.import -> claude_code_import branch (memory_events now requires host_agent.capture). The import scope is still used for memory.write tools.
9. ServiceRegistration: Logger.warning with reason once per failure streak (failing flag). Test: capture_log single-warning test.
10. Records.Search: whole-query ILIKE pattern needs >=2 chars; non-binary subject raises ArgumentError("invalid subject"). Tests added in records_test.exs.
11. docs/architecture/memory.md: line on client = host id.
12. app.html.heex: removed /memory/streams label and memory_navigation assign (and unused Layouts.left_nav_groups/2); removed never-failing refute in host_agent_channel_test.

Noted, not changed: host_agent memory/spool/turso.ex still references claude_code_import (host side, out of scope of finding 8).

## Gate
compile --warnings-as-errors (MIX_ENV=test, umbrella root): pass. format: pass. credo --strict: no issues.
Tests: memory 339/0, host_agent 333/0, skills 199/0, system 475/0, admin 359/0, api 225/0, mcp 668 with 1 failure (known UpstreamTest env failure), contract 3/0.
