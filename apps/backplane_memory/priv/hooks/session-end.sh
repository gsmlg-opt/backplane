#!/usr/bin/env bash
# Claude Code hook: SessionEnd

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0

MEMORY_URL="${BACKPLANE_MEMORY_URL:-http://localhost:4220}"
HOOKS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

HOOKS_DIR="$HOOKS_DIR" MEMORY_URL="$MEMORY_URL" python3 -c '
import json
import os
import sys

sys.path.insert(0, os.environ["HOOKS_DIR"])

from activation_session import cleanup, prepare_end, send_json

try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError, UnicodeDecodeError):
    sys.exit(0)

prepared = prepare_end(data.get("session_id"))
if prepared is None:
    sys.exit(0)

digest, session_id = prepared
project = data.get("cwd") or data.get("project") or ""
body = {"session_id": session_id, "project": project}
agent_id = data.get("agent_id")
if isinstance(agent_id, str) and agent_id:
    body["agent_id"] = agent_id

try:
    send_json(os.environ["MEMORY_URL"], "/api/memory/session/end", body)
finally:
    cleanup(digest, session_id)
' >/dev/null 2>&1 || true

exit 0
