#!/usr/bin/env bash
# Claude Code hook: PostToolUseFailure

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0

MEMORY_URL="${BACKPLANE_MEMORY_URL:-http://localhost:4220}"

BODY="$(python3 -c '
import json
import sys

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

session_id = data.get("session_id")
tool_name = data.get("tool_name")
error = data.get("error")
content = display(error)
if not isinstance(session_id, str) or not session_id or not isinstance(tool_name, str) or not tool_name or not content:
    sys.exit(0)

payload = {
    "tool_input": data.get("tool_input", {}),
    "tool_output": {
        "error": error,
        "is_interrupt": bool(data.get("is_interrupt", False)),
    },
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
    "is_error": True,
    "event_type": "tool.call.failed",
    "payload": payload,
}
agent_id = data.get("agent_id")
if isinstance(agent_id, str) and agent_id:
    body["agent_id"] = agent_id
if isinstance(tool_use_id, str) and tool_use_id:
    body["idempotency_key"] = f"claude:tool:failed:{session_id}:{tool_use_id}"

sys.stdout.write(json.dumps(body, ensure_ascii=False, separators=(",", ":")))
' 2>/dev/null || true)"

[ -n "$BODY" ] || exit 0

printf '%s' "$BODY" | curl -sf -m 2.0 -X POST "$MEMORY_URL/api/memory/observations" \
  -H "Content-Type: application/json" \
  --data-binary @- \
  >/dev/null 2>&1 || true

exit 0
