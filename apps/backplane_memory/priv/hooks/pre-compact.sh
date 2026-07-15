#!/usr/bin/env bash
# Claude Code hook: PreCompact

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0

MEMORY_URL="${BACKPLANE_MEMORY_URL:-http://localhost:4220}"

BODY="$(python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError, UnicodeDecodeError):
    sys.exit(0)

session_id = data.get("session_id")
if not isinstance(session_id, str) or not session_id:
    sys.exit(0)

trigger = data.get("trigger") if isinstance(data.get("trigger"), str) else ""
instructions = data.get("custom_instructions")
if not isinstance(instructions, str):
    instructions = ""
content = instructions or trigger or "context compaction"

body = {
    "session_id": session_id,
    "project": data.get("cwd") or data.get("project") or "",
    "content": content,
    "tool_name": "pre_compact",
    "event_type": "legacy.observation",
    "payload": {
        "trigger": trigger,
        "custom_instructions": instructions,
    },
}
agent_id = data.get("agent_id")
if isinstance(agent_id, str) and agent_id:
    body["agent_id"] = agent_id

sys.stdout.write(json.dumps(body, ensure_ascii=False, separators=(",", ":")))
' 2>/dev/null || true)"

[ -n "$BODY" ] || exit 0

printf '%s' "$BODY" | curl -sf -m 2.0 -X POST "$MEMORY_URL/api/memory/observations" \
  -H "Content-Type: application/json" \
  --data-binary @- \
  >/dev/null 2>&1 || true

exit 0
