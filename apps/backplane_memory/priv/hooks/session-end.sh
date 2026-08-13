#!/usr/bin/env bash
# Claude Code hook: SessionEnd

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0

CAPTURE_URL="${BACKPLANE_HOST_AGENT_URL:-http://127.0.0.1:4222}"
HOOKS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

HOOKS_DIR="$HOOKS_DIR" CAPTURE_URL="$CAPTURE_URL" python3 -c '
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
data["session_id"] = session_id

try:
    send_json(os.environ["CAPTURE_URL"], "/capture/v1/hooks/claude_code/SessionEnd", data)
finally:
    cleanup(digest, session_id)
' >/dev/null 2>&1 || true

exit 0
