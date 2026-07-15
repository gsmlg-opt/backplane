#!/usr/bin/env bash
# Claude Code hook: PostToolUse (Bash matcher, actual git commits only)

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0

MEMORY_URL="${BACKPLANE_MEMORY_URL:-http://localhost:4220}"

BODY="$(python3 -c '
import json
import re
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

tool_input = data.get("tool_input")
command = tool_input.get("command") if isinstance(tool_input, dict) else None
commit_pattern = r"(?:^|(?:&&|\|\||;|\n)\s*)git(?:\s+-C(?:\s+|=)\S+)*\s+commit(?:\s|$)"
if not isinstance(command, str) or re.search(commit_pattern, command.strip()) is None:
    sys.exit(0)

session_id = data.get("session_id")
tool_output = data.get("tool_response")
content = display(tool_output)
if not isinstance(session_id, str) or not session_id or not content:
    sys.exit(0)

payload = {"tool_input": tool_input, "tool_output": tool_output}
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
    "tool_name": "git_commit",
    "is_error": False,
    "event_type": "tool.call.completed",
    "payload": payload,
}
agent_id = data.get("agent_id")
if isinstance(agent_id, str) and agent_id:
    body["agent_id"] = agent_id
if isinstance(tool_use_id, str) and tool_use_id:
    body["idempotency_key"] = f"claude:git_commit:{session_id}:{tool_use_id}"

sys.stdout.write(json.dumps(body, ensure_ascii=False, separators=(",", ":")))
' 2>/dev/null || true)"

[ -n "$BODY" ] || exit 0

printf '%s' "$BODY" | curl -sf -m 2.0 -X POST "$MEMORY_URL/api/memory/observations" \
  -H "Content-Type: application/json" \
  --data-binary @- \
  >/dev/null 2>&1 || true

exit 0
