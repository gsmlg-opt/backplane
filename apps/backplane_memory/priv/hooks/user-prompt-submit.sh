#!/usr/bin/env bash
# Claude Code hook: UserPromptSubmit

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
prompt = data.get("prompt")
if session_id is None or not isinstance(prompt, str) or not prompt:
    sys.exit(0)

body = {
    "session_id": session_id,
    "project": data.get("cwd") or data.get("project") or "",
    "content": prompt,
    "tool_name": "user_prompt",
    "event_type": "conversation.user_message",
    "payload": {"prompt": prompt},
}
agent_id = data.get("agent_id")
if isinstance(agent_id, str) and agent_id:
    body["agent_id"] = agent_id

send_json(sys.argv[2], "/api/memory/observations", body)
' "$HOOKS_DIR" "$MEMORY_URL" >/dev/null 2>&1 || true

exit 0
