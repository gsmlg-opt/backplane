import json
import pathlib
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from google import genai
from google.genai import types

MODEL = "models/gemini-2.5-flash"
API_KEY = "backplane-sdk-contract-key"
RESPONSE = {"candidates": [{"content": {"parts": [{"text": "recording response"}], "role": "model"}, "finishReason": "STOP", "index": 0}], "modelVersion": "gemini-2.5-flash", "responseId": "recording-response-id", "usageMetadata": {"candidatesTokenCount": 2, "promptTokenCount": 3, "totalTokenCount": 5}}


class Handler(BaseHTTPRequestHandler):
    recordings = []

    def log_message(self, *_args):
        pass

    def _record(self):
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length).decode() if length else ""
        path, _, query = self.path.partition("?")
        self.recordings.append({"body": json.loads(body) if body else None, "method": self.command, "path": path, "query": f"?{query}" if query else ""})
        self.server.headers_seen.append(dict(self.headers))

    def _json(self, value):
        payload = json.dumps(value).encode()
        self.send_response(200); self.send_header("content-type", "application/json"); self.send_header("content-length", str(len(payload))); self.end_headers(); self.wfile.write(payload)

    def do_GET(self):
        self._record()
        self._json({"models": [{"name": MODEL, "displayName": "Gemini", "supportedGenerationMethods": ["generateContent"]}]} if self.path.endswith("/models") else {"name": MODEL, "displayName": "Gemini", "supportedGenerationMethods": ["generateContent"]})

    def do_POST(self):
        self._record()
        if ":streamGenerateContent" in self.path:
            chunks = [RESPONSE, {**RESPONSE, "usageMetadata": {"candidatesTokenCount": 3, "promptTokenCount": 3, "totalTokenCount": 6}}]
            payload = "".join(f"data: {json.dumps(chunk)}\n\n" for chunk in chunks).encode()
            self.send_response(200); self.send_header("content-type", "text/event-stream"); self.end_headers(); self.wfile.write(payload)
        elif ":countTokens" in self.path:
            self._json({"totalTokens": 3})
        else:
            self._json(RESPONSE)


class ContractTest(unittest.TestCase):
    def test_wire_contract(self):
        Handler.recordings = []
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler); server.headers_seen = []
        thread = threading.Thread(target=server.serve_forever); thread.start()
        try:
            client = genai.Client(api_key=API_KEY, http_options=types.HttpOptions(base_url=f"http://127.0.0.1:{server.server_port}/deploy", api_version="v1beta"))
            self.assertEqual(client.models.generate_content(model=MODEL, contents="sanitized generate prompt").text, "recording response")
            self.assertEqual(len(list(client.models.generate_content_stream(model=MODEL, contents="sanitized stream prompt"))), 2)
            self.assertEqual(client.models.count_tokens(model=MODEL, contents="sanitized count prompt").total_tokens, 3)
            self.assertEqual(next(iter(client.models.list())).name, MODEL)
            self.assertEqual(client.models.get(model=MODEL).name, MODEL)
            client.close()
        finally:
            server.shutdown(); thread.join(); server.server_close()
        (pathlib.Path(__file__).parents[1] / "fixtures/requests/python.captured.json").write_text(json.dumps(Handler.recordings, indent=2) + "\n")
        expected = json.loads((pathlib.Path(__file__).parents[1] / "fixtures/requests/python.json").read_text())
        self.assertEqual(Handler.recordings, expected)
        for headers in server.headers_seen:
            self.assertEqual(headers.get("x-goog-api-key"), API_KEY)
            self.assertTrue(headers.get("x-goog-api-client", "").startswith("google-genai-sdk/2.25.0 "))


if __name__ == "__main__":
    unittest.main()
