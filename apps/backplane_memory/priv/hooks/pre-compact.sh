#!/usr/bin/env bash
# install with: chmod +x pre-compact.sh
# Claude Code hook: PreCompact
# Records a summary observation before context compaction.

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0

MEMORY_URL="${BACKPLANE_MEMORY_URL:-http://localhost:4220}"

INPUT="$(cat)"

SESSION_ID="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('session_id',''))" "$INPUT" 2>/dev/null || true)"
SUMMARY="$(python3 -c "
import sys,json
d=json.loads(sys.argv[1])
print(d.get('summary','') or d.get('context','') or 'context compaction')
" "$INPUT" 2>/dev/null || true)"

if [ -n "$SESSION_ID" ]; then
  CONTENT="${SUMMARY:-context compaction triggered}"
  PAYLOAD="$(python3 -c "import sys,json; print(json.dumps({'session_id':sys.argv[1],'content':sys.argv[2],'tool_name':'pre_compact'}))" "$SESSION_ID" "$CONTENT" 2>/dev/null || true)"
  if [ -n "$PAYLOAD" ]; then
    curl -sf -m 2.0 -X POST "$MEMORY_URL/api/memory/observations" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      >/dev/null 2>&1 || true
  fi
fi

exit 0
