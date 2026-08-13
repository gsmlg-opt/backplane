#!/usr/bin/env bash
# Claude Code hook: SessionStart

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0

CAPTURE_URL="${BACKPLANE_HOST_AGENT_URL:-http://127.0.0.1:4222}"
HOOKS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

HOOKS_DIR="$HOOKS_DIR" CAPTURE_URL="$CAPTURE_URL" python3 -c '
import json
import os
import sys

sys.path.insert(0, os.environ["HOOKS_DIR"])

from activation_session import establish, request_json

try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError, UnicodeDecodeError):
    sys.exit(0)

session_id = establish(data.get("session_id"), data.get("source"))
if session_id is None:
    sys.exit(0)

data["session_id"] = session_id
response = request_json(
    os.environ["CAPTURE_URL"],
    "/capture/v1/hooks/claude_code/SessionStart",
    data,
)

if isinstance(response, dict):
    lifecycle = response.get("lifecycle_context")
    if isinstance(lifecycle, dict):
        context = lifecycle.get("context")
        if isinstance(context, str) and context.strip():
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart",
                    "additionalContext": context,
                }
            }, ensure_ascii=False, separators=(",", ":")))
' 2>/dev/null || true

exit 0
