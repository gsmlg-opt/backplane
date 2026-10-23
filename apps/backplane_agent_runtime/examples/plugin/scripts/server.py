"""Small real stdio MCP server used by the portable plugin example."""
import json
import os
import sys
from pathlib import Path

for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request.get("method")
    response = {"jsonrpc": "2.0", "id": request["id"]}
    if method == "initialize":
        response["result"] = {
            "protocolVersion": request["params"]["protocolVersion"],
            "serverInfo": {"name": "backplane-plugin-example", "version": "1.0.0"},
            "capabilities": {"tools": {}},
        }
    elif method == "tools/list":
        response["result"] = {"tools": [{
            "name": "echo", "description": "Echo with the installed release marker.",
            "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
            "annotations": {"readOnlyHint": True, "idempotentHint": True},
        }]}
    elif method == "tools/call":
        marker = Path(os.environ["MARKER"]).read_text().strip()
        response["result"] = {"content": [{"type": "text", "text": marker + ": " + request["params"]["arguments"]["text"]}]}
    else:
        response["error"] = {"code": -32601, "message": "Method not found"}
    print(json.dumps(response), flush=True)
