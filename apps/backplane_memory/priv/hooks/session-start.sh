#!/usr/bin/env bash
# install with: chmod +x session-start.sh
# Claude Code hook: PreToolUse / SessionStart
# Posts session-start event to backplane memory API.

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0

MEMORY_URL="${BACKPLANE_MEMORY_URL:-http://localhost:4220}"

INPUT="$(cat)"

SESSION_ID="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('session_id',''))" "$INPUT" 2>/dev/null || true)"
PROJECT="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('cwd','') or d.get('project',''))" "$INPUT" 2>/dev/null || true)"

if [ -n "$SESSION_ID" ]; then
  curl -sf -m 2.0 -X POST "$MEMORY_URL/api/memory/session/start" \
    -H "Content-Type: application/json" \
    -d "{\"session_id\":\"$SESSION_ID\",\"project\":\"$PROJECT\"}" \
    >/dev/null 2>&1 || true
fi

exit 0
