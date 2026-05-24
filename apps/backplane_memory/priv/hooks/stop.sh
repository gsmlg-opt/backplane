#!/usr/bin/env bash
# install with: chmod +x stop.sh
# Claude Code hook: Stop (agent stop / turn complete)
# Records a stop observation for the session.

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0

MEMORY_URL="${BACKPLANE_MEMORY_URL:-http://localhost:4220}"

INPUT="$(cat)"

SESSION_ID="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('session_id',''))" "$INPUT" 2>/dev/null || true)"
REASON="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('stop_reason','') or 'stop')" "$INPUT" 2>/dev/null || true)"

if [ -n "$SESSION_ID" ]; then
  PAYLOAD="$(python3 -c "import sys,json; print(json.dumps({'session_id':sys.argv[1],'content':sys.argv[2],'tool_name':'stop'}))" "$SESSION_ID" "$REASON" 2>/dev/null || true)"
  if [ -n "$PAYLOAD" ]; then
    curl -sf -m 2.0 -X POST "$MEMORY_URL/api/memory/observations" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      >/dev/null 2>&1 || true
  fi
fi

exit 0
