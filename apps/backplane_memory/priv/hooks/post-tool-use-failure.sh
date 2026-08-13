#!/usr/bin/env bash
# Claude Code hook: PostToolUseFailure

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0

CAPTURE_URL="${BACKPLANE_HOST_AGENT_URL:-http://127.0.0.1:4222}"
HOOKS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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
tool_name = data.get("tool_name")
error = data.get("error")
if session_id is None or not isinstance(tool_name, str) or not tool_name or error is None:
    sys.exit(0)

data["session_id"] = session_id
send_json(sys.argv[2], "/capture/v1/hooks/claude_code/PostToolUseFailure", data)
' "$HOOKS_DIR" "$CAPTURE_URL" >/dev/null 2>&1 || true

exit 0
