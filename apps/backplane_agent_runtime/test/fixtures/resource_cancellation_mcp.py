import json
import sys

log = sys.argv[1]
pending = []
for line in sys.stdin:
    request = json.loads(line)
    with open(log, "a", encoding="utf-8") as output:
        output.write(json.dumps(request) + "\n")
    method = request.get("method")
    if "id" not in request:
        continue
    if method == "initialize":
        result = {"protocolVersion": "2025-11-25", "capabilities": {"resources": {}},
                  "serverInfo": {"name": "resource-cancellation", "version": "1"}}
    elif method in ("resources/list", "resources/templates/list", "resources/read"):
        params = request.get("params", {})
        if params.get("uri") == "mem://release":
            for held in pending:
                print(json.dumps({"jsonrpc": "2.0", "id": held, "result": {"contents": []}}), flush=True)
            pending.clear()
        if params.get("uri") == "mem://survivor-pending":
            pending.append(request["id"])
            continue
        if params.get("cursor") == "pending" or params.get("uri") == "mem://pending":
            continue
        key = {"resources/list": "resources", "resources/templates/list": "resourceTemplates",
               "resources/read": "contents"}[method]
        result = {key: []}
    else:
        result = {}
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
