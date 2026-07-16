#!/usr/bin/env bash
# Claude Code hook: Stop

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

last_message = data.get("last_assistant_message")
if not isinstance(last_message, str):
    last_message = ""
body = {
    "session_id": session_id,
    "project": data.get("cwd") or data.get("project") or "",
    "content": last_message or "agent run completed",
    "tool_name": "stop",
    "event_type": "agent.run.completed",
    "payload": {"last_assistant_message": last_message},
}
agent_id = data.get("agent_id")
if isinstance(agent_id, str) and agent_id:
    body["agent_id"] = agent_id

send_json(sys.argv[2], "/api/memory/observations", body)
' "$HOOKS_DIR" "$MEMORY_URL" >/dev/null 2>&1 || true

exit 0
