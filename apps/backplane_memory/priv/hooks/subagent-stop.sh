#!/usr/bin/env bash
# Claude Code hook: SubagentStop

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
agent_id = data.get("agent_id")
if session_id is None or not isinstance(agent_id, str) or not agent_id:
    sys.exit(0)

agent_type = data.get("agent_type") if isinstance(data.get("agent_type"), str) else ""
transcript = data.get("agent_transcript_path")
last_message = data.get("last_assistant_message")
if not isinstance(last_message, str):
    last_message = ""

payload = {
    "agent_id": agent_id,
    "agent_type": agent_type,
    "last_assistant_message": last_message,
}
if isinstance(transcript, str) and transcript:
    payload["agent_transcript_path"] = transcript

body = {
    "session_id": session_id,
    "project": data.get("cwd") or data.get("project") or "",
    "agent_id": agent_id,
    "content": last_message or (f"{agent_type} subagent ended" if agent_type else "subagent ended"),
    "tool_name": "subagent",
    "event_type": "session.ended",
    "idempotency_key": f"claude:subagent:ended:{session_id}:{agent_id}",
    "payload": payload,
}

send_json(sys.argv[2], "/api/memory/observations", body)
' "$HOOKS_DIR" "$MEMORY_URL" >/dev/null 2>&1 || true

exit 0
