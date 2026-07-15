#!/usr/bin/env bash
# Claude Code hook: SubagentStart

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0
export AGENTMEMORY_SDK_CHILD=1

MEMORY_URL="${BACKPLANE_MEMORY_URL:-http://localhost:4220}"

BODY="$(python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError, UnicodeDecodeError):
    sys.exit(0)

session_id = data.get("session_id")
agent_id = data.get("agent_id")
if not isinstance(session_id, str) or not session_id or not isinstance(agent_id, str) or not agent_id:
    sys.exit(0)

agent_type = data.get("agent_type") if isinstance(data.get("agent_type"), str) else ""
transcript = data.get("agent_transcript_path")
payload = {"agent_id": agent_id, "agent_type": agent_type}
if isinstance(transcript, str) and transcript:
    payload["agent_transcript_path"] = transcript

body = {
    "session_id": session_id,
    "project": data.get("cwd") or data.get("project") or "",
    "agent_id": agent_id,
    "content": f"{agent_type} subagent started" if agent_type else "subagent started",
    "tool_name": "subagent",
    "event_type": "session.started",
    "idempotency_key": f"claude:subagent:started:{session_id}:{agent_id}",
    "payload": payload,
}

sys.stdout.write(json.dumps(body, ensure_ascii=False, separators=(",", ":")))
' 2>/dev/null || true)"

[ -n "$BODY" ] || exit 0

printf '%s' "$BODY" | curl -sf -m 2.0 -X POST "$MEMORY_URL/api/memory/observations" \
  -H "Content-Type: application/json" \
  --data-binary @- \
  >/dev/null 2>&1 || true

exit 0
