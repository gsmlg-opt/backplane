#!/usr/bin/env bash
# Claude Code hook: PreCompact

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0

HOOKS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MEMORY_URL="${BACKPLANE_MEMORY_URL:-http://localhost:4220}"

python3 -c '
import json
import sys

sys.path.insert(0, sys.argv[1])
from activation_session import resolve, send_json

try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError, UnicodeDecodeError):
    sys.exit(0)

session_id = resolve(data.get("session_id"))
if session_id is None:
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

send_json(sys.argv[2], "/api/memory/observations", body)
' "$HOOKS_DIR" "$MEMORY_URL" >/dev/null 2>&1 || true

exit 0
