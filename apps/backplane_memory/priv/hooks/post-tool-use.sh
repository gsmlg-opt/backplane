#!/usr/bin/env bash
# Claude Code hook: PostToolUse

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0

MEMORY_URL="${BACKPLANE_MEMORY_URL:-http://localhost:4220}"
HOOKS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

python3 -c '
import json
import sys
sys.path.insert(0, sys.argv[1])
from activation_session import resolve, send_json

def display(value):
    if isinstance(value, str):
        return value
    if value is None:
        return ""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError, UnicodeDecodeError):
    sys.exit(0)

session_id = resolve(data.get("session_id"))
tool_name = data.get("tool_name")
tool_output = data.get("tool_response")
content = display(tool_output)
if session_id is None or not isinstance(tool_name, str) or not tool_name or not content:
    sys.exit(0)

payload = {
    "tool_input": data.get("tool_input", {}),
    "tool_output": tool_output,
}
tool_use_id = data.get("tool_use_id")
if isinstance(tool_use_id, str) and tool_use_id:
    payload["tool_use_id"] = tool_use_id

duration_ms = data.get("duration_ms")
if isinstance(duration_ms, (int, float)) and not isinstance(duration_ms, bool):
    payload["duration_ms"] = duration_ms

body = {
    "session_id": session_id,
    "project": data.get("cwd") or data.get("project") or "",
    "content": content,
    "tool_name": tool_name,
    "is_error": False,
    "event_type": "tool.call.completed",
    "payload": payload,
}
agent_id = data.get("agent_id")
if isinstance(agent_id, str) and agent_id:
    body["agent_id"] = agent_id
if isinstance(tool_use_id, str) and tool_use_id:
    body["idempotency_key"] = f"claude:tool:completed:{session_id}:{tool_use_id}"

send_json(sys.argv[2], "/api/memory/observations", body)
' "$HOOKS_DIR" "$MEMORY_URL" >/dev/null 2>&1 || true

exit 0
