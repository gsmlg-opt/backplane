"""Local modern MCP fixture; no subscriptions or scheduler effects."""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log_path = sys.argv[1]
pending = {}
lock = threading.Lock()
page = {
    "events": [
        {"name": "changed", "title": "Changed 汉字", "description": "first",
         "schema": {"type": "object", "properties": {"path": {"type": "string"}}},
         "_meta": {"fixture/order": 1}},
        {"name": "deleted", "description": "second", "schema": {"type": "object"}},
    ],
    "nextCursor": "opaque/+next=汉字",
    "_meta": {"fixture/page": [2, True, None]},
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        wire = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with lock:
            with open(log_path, "a", encoding="utf-8") as output:
                output.write(json.dumps(wire) + "\n")
        method = wire.get("method")
        params = wire.get("params", {})
        if method == "notifications/cancelled":
            with lock:
                event = pending.get(params.get("requestId"))
            if event:
                event.set()
        if "id" not in wire:
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if method == "server/discover":
            result = {"resultType": "complete", "supportedVersions": ["2026-07-28"],
                      "capabilities": {"events": {}, "resources": {}},
                      "ttlMs": 0, "cacheScope": "private"}
        else:
            if params.get("cursor") == "pending" or params.get("uri") == "mem://survivor-pending":
                event = threading.Event()
                with lock:
                    pending[wire["id"]] = event
                event.wait(20)
            if params.get("uri") == "mem://release":
                with lock:
                    for event in pending.values():
                        event.set()
            result = page if method == "events/list" else {"contents": []}
        response = json.dumps({"jsonrpc": "2.0", "id": wire["id"], "result": result}).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=lambda: (sys.stdin.readline(), server.shutdown()), daemon=True).start()
print(server.server_port, flush=True)
server.serve_forever()
server.server_close()
