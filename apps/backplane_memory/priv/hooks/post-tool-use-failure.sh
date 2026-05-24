#!/usr/bin/env bash
# install with: chmod +x post-tool-use-failure.sh
# Claude Code hook: PostToolUse (failure / error output)
# Records failed tool result as an observation marked is_error=true.

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0

MEMORY_URL="${BACKPLANE_MEMORY_URL:-http://localhost:4220}"

INPUT="$(cat)"

SESSION_ID="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('session_id',''))" "$INPUT" 2>/dev/null || true)"
TOOL_NAME="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('tool_name',''))" "$INPUT" 2>/dev/null || true)"
CONTENT="$(python3 -c "
import sys,json
d=json.loads(sys.argv[1])
out=d.get('error','') or d.get('tool_response','') or d.get('output','')
if isinstance(out,(dict,list)): out=json.dumps(out)
print(str(out)[:2000])
" "$INPUT" 2>/dev/null || true)"

if [ -n "$SESSION_ID" ] && [ -n "$CONTENT" ]; then
  PAYLOAD="$(python3 -c "import sys,json; print(json.dumps({'session_id':sys.argv[1],'content':sys.argv[2],'tool_name':sys.argv[3],'is_error':True}))" "$SESSION_ID" "$CONTENT" "$TOOL_NAME" 2>/dev/null || true)"
  if [ -n "$PAYLOAD" ]; then
    curl -sf -m 2.0 -X POST "$MEMORY_URL/api/memory/observations" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      >/dev/null 2>&1 || true
  fi
fi

exit 0
