#!/usr/bin/env python3
"""Exercise synthetic Memory fixtures through the running host HTTP API.

This records individual observations; it never promotes this API subset into
passing browser, provider, outage, or complete L01-L18 acceptance.
"""

import argparse
import datetime
import json
import math
import os
import re
import socket
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class Acceptance:
    def __init__(self, fixture, host_url, timeout, sessions=4):
        self.fixture_path = fixture
        self.fixture = json.loads(fixture.read_text())
        self.run_id = self.fixture["run_id"]
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}", self.run_id):
            raise ValueError("invalid fixture run ID")
        parsed = urllib.parse.urlparse(host_url)
        if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
            raise ValueError("host API must use local HTTP")
        self.host_url = host_url.rstrip("/")
        self.timeout = timeout
        if not 1 <= sessions <= 8:
            raise ValueError("capture sessions must be between 1 and 8")
        self.capture_sessions = sessions
        self.agent = "memory-local-" + self.run_id
        self.session = "memory-local-" + self.run_id + "-session"
        self.project = "/synthetic/backplane-memory/" + self.run_id
        self.marker = "MEMORY-LOCAL-" + self.run_id
        self.scope = self.fixture["hosts"][0]["partition"]["scope"]
        self.output = ROOT / ".devenv/memory-local-evidence" / self.run_id
        self.output.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.observations = []
        self.sequence = 0

    def post(self, path, body):
        started = time.monotonic()
        request = urllib.request.Request(
            self.host_url + path, data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"}, method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                status, raw = response.status, response.read(4_000_001)
        except urllib.error.HTTPError as error:
            status, raw = error.code, error.read(4_000_001)
        if len(raw) > 4_000_000:
            raise RuntimeError("response exceeded bounded evidence size")
        reply = json.loads(raw)
        self.sequence += 1
        record = {"sequence": self.sequence, "path": path, "request": body,
                  "status": status, "response": reply,
                  "elapsed_ms": round((time.monotonic() - started) * 1000)}
        self.observations.append(record)
        if status not in (200, 202):
            raise RuntimeError(f"HTTP {status} for {path}; inspect evidence")
        return reply

    def direct(self, method, args):
        reply = self.post(f"/memory/{self.agent}/call/{method}", args)
        if reply.get("ok") is not True or not isinstance(reply.get("result"), dict):
            raise RuntimeError(f"direct {method} did not return success")
        return reply["result"]

    def mcp(self, method, params):
        reply = self.post(f"/memory/{self.agent}/mcp", {
            "jsonrpc": "2.0", "id": self.sequence + 1, "method": method, "params": params,
        })
        if "error" in reply or "result" not in reply:
            raise RuntimeError(f"MCP {method} failed")
        return reply["result"]

    def tool(self, name, args):
        result = self.mcp("tools/call", {"name": "memory::" + name, "arguments": args})
        if result.get("isError") is not False:
            raise RuntimeError(f"MCP tool {name} did not return success")
        text = [part["text"] for part in result.get("content", []) if part.get("type") == "text"]
        if len(text) != 1:
            raise RuntimeError("expected exactly one structured JSON text response")
        return json.loads(text[0])

    def discover(self):
        initialized = self.mcp("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "memory-local-acceptance", "version": "1"},
        })
        if initialized.get("protocolVersion") != "2025-11-25":
            raise RuntimeError("unexpected negotiated protocol")
        tools = self.mcp("tools/list", {}).get("tools", [])
        names = {tool["name"] for tool in tools}
        required = {"memory::" + method for method in ("remember", "recall", "list", "stats", "forget")}
        if not required.issubset(names):
            raise RuntimeError("core tools missing from discovery")

    def provider(self):
        token = (self.fixture_path.parent / "resource-token").read_text().strip()
        if not token:
            raise RuntimeError("fixture resource bearer is empty")

        def request(path, body, authenticated):
            headers = {"Content-Type": "application/json", "x-backplane-memory-capture": "skip"}
            if authenticated:
                headers["Authorization"] = "Bearer " + token
            req = urllib.request.Request("http://127.0.0.1:4220" + path,
                                         data=json.dumps(body).encode(), headers=headers, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=90) as reply:
                    status, raw = reply.status, reply.read(1_000_001)
            except urllib.error.HTTPError as error:
                status, raw = error.code, error.read(1_000_001)
            if len(raw) > 1_000_000:
                raise RuntimeError("gateway provider response exceeded bound")
            return status, json.loads(raw)

        chat = {"model": self.fixture["models"][0], "messages": [
            {"role": "user", "content": "Return a JSON object with ok set to true."}],
            "response_format": {"type": "json_object"}, "max_tokens": 100}
        denied, _ = request("/v1/chat/completions", chat, False)
        self.observations.append({"path": "/v1/chat/completions", "authenticated": False, "status": denied})
        if denied != 401:
            raise RuntimeError("gateway did not require the normal resource bearer")
        status, reply = request("/v1/chat/completions", chat, True)
        content = reply.get("choices", [{}])[0].get("message", {}).get("content")
        self.observations.append({"path": "/v1/chat/completions", "authenticated": True,
                                  "status": status, "model": reply.get("model"), "content": content})
        if status != 200 or not isinstance(content, str) or json.loads(content).get("ok") is not True:
            raise RuntimeError("authenticated gateway structured chat failed")
        status, reply = request("/v1/embeddings", {"model": self.fixture["models"][1],
                                                  "input": [self.marker + " bounded OTP workers"],
                                                  "dimensions": 2560}, True)
        data = reply.get("data", [])
        vector = data[0].get("embedding", []) if len(data) == 1 else []
        self.observations.append({"path": "/v1/embeddings", "authenticated": True, "status": status,
                                  "model": reply.get("model"), "items": len(data), "dimensions": len(vector)})
        if status != 200 or len(vector) != 2560 or not all(type(value) in (int, float) for value in vector):
            raise RuntimeError("authenticated gateway embedding failed dimension validation")
        return {"authenticated_chat": True, "authenticated_embedding_dimensions": len(vector),
                "unauthenticated_status": denied}

    def write(self):
        args = {"content": f"{self.marker}: The synthetic project prefers bounded OTP workers and PostgreSQL canonical storage.",
                "type": "semantic", "scope": self.scope,
                "idempotency_key": self.run_id + ":explicit-preference",
                "facets": [{"dimension": "project", "value": self.project}]}
        direct = self.direct("remember", args)
        mcp = self.tool("remember", args)
        if not direct.get("id") or direct.get("id") != mcp.get("id"):
            raise RuntimeError("direct/MCP idempotent identities differ")
        return direct

    def host_first(self):
        """Run beside lifecycle start; require acceptance while the public port is closed."""
        deadline = time.monotonic() + self.timeout
        host = urllib.parse.urlparse(self.host_url)
        while True:
            try:
                with socket.create_connection((host.hostname, host.port), timeout=0.2):
                    break
            except OSError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("host-first readiness wait expired")
                time.sleep(0.05)
        def gateway_reachable():
            try:
                with socket.create_connection(("127.0.0.1", 4220), timeout=0.2):
                    return True
            except OSError:
                return False
        if gateway_reachable():
            raise RuntimeError("host-first probe missed the pre-gateway interval")
        result = self.write()
        if gateway_reachable():
            raise RuntimeError("gateway became reachable during host-first probe; retry cold-start scenario")
        if result.get("authority") != "provisional" or result.get("sync_state") != "pending":
            raise RuntimeError("pre-gateway write did not report durable provisional acceptance")
        if result.get("canonical_id") or result.get("memory_space_id") or result.get("revision"):
            raise RuntimeError("unresolved host-first acceptance claimed canonical identity or revision")
        return {"gateway_reachable_before_and_after": False, "acceptance": result}

    def capture(self):
        facts = [
            "The project prefers bounded OTP workers instead of unbounded background tasks.",
            "PostgreSQL is the sole canonical long-term memory authority.",
            "The host stores provisional commands durably before acknowledging them.",
            "Command, capture spool, and edge mirror use separate database files.",
            "The Atlas service owns the Beacon deployment; Atlas depends on Beacon health checks.",
            "Public resource bearer credentials are separate from host channel credentials.",
            "The local administration endpoint is restricted to trusted operators.",
            "A failed upload caused missing facts; retrying the durable spool restored all events.",
            "We verified the repair by checking canonical event IDs and duplicate-free replay.",
            "For repeatable recovery, inspect pending commands, restore connectivity, then verify canonical acknowledgment.",
            "We completed synthetic deployment verification and retained the successful evidence links.",
            "The unresolved follow-up is documenting the Beacon certificate rotation owner.",
        ]
        for session_index in range(self.capture_sessions):
            session = self.session if session_index == 0 else self.session + f"-{session_index + 1}"
            # Four independent sessions support the extractor's ten-root eligibility.
            selected = facts[session_index * 3:session_index * 3 + 3] or facts
            hooks = [("SessionStart", {"source": "startup"})]
            hooks += [("UserPromptSubmit", {"prompt": self.marker + ": " + fact}) for fact in selected]
            hooks += [("PostToolUse", {"tool_name": "exec_command", "is_error": True,
                                      "tool_input": {"cmd": "synthetic verify"},
                                      "tool_response": {"exit_code": 1, "output": "synthetic missing acknowledgment"}}),
                      ("PostToolUse", {"tool_name": "exec_command", "is_error": False,
                                      "tool_input": {"cmd": "synthetic retry then verify"},
                                      "tool_response": {"exit_code": 0, "output": "synthetic canonical acknowledgment verified"}}),
                      ("Stop", {"message": self.marker + ": Verified the session's work. " + " ".join(selected)}),
                      ("SessionEnd", {"reason": "completed"})]
            # Fixed timestamps and source IDs make repeated delivery the same logical events.
            timestamp = self.fixture["prepared_at"]
            for index, (hook, extra) in enumerate(hooks):
                body = {"hook_event_name": hook, "session_id": session, "agent_id": self.agent,
                        "cwd": self.project, "scope": self.scope, "occurred_at": timestamp,
                        "source_event_id": f"{self.run_id}:capture:{session_index}:{index}", **extra}
                reply = self.post(f"/capture/v1/hooks/codex/{hook}", body)
                duplicate = self.post(f"/capture/v1/hooks/codex/{hook}", body)
                if reply.get("ok") is not True or duplicate.get("status") != "duplicate" or reply.get("event_id") != duplicate.get("event_id"):
                    raise RuntimeError("capture duplicate delivery contract failed")

    def inspect(self):
        deadline = time.monotonic() + self.timeout
        while True:
            result = self.direct("list", {"q": self.marker, "scope": self.scope, "limit": 50})
            rows = result.get("results", [])
            canonical = [row for row in rows if self.marker in row.get("content", "") and
                         row.get("authority", "canonical") == "canonical"]
            if canonical and result.get("mode") == "online" and result.get("pending_operations") == 0:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("canonical settlement wait expired; inspect last list response")
            time.sleep(1)
        recall = self.direct("recall", {"query": self.marker + " bounded workers", "scope": self.scope, "limit": 10})
        if not any(self.marker in row.get("content", "") for row in recall.get("results", [])):
            raise RuntimeError("recall did not return the synthetic preference")
        self.tool("list", {"q": self.marker, "scope": self.scope, "limit": 50})
        self.tool("recall", {"query": self.marker + " bounded workers", "scope": self.scope, "limit": 10})
        return {"canonical_ids": [row["id"] for row in canonical], "recall_observed": True}

    def recall(self):
        """Check four online Recall V2 cases against discovered fixture knowledge."""
        detail = {"expected_ids": [], "cases": [], "comparisons": [],
                  "separate_checks": ["browser trace agreement", "database embedding model provenance"]}
        self.recall_detail = detail

        def inventory():
            result = self.direct("list", {"scope": self.scope, "q": "bounded OTP", "limit": 50})
            if result.get("mode") != "online":
                raise RuntimeError("recall_online_required: fixture list must be online")
            rows = [(row["id"], row["content"]) for row in result.get("items", [])
                    if isinstance(row, dict) and isinstance(row.get("id"), str)
                    and row.get("scope") == self.scope and isinstance(row.get("content"), str)
                    and "bounded otp" in row["content"].lower() and "worker" in row["content"].lower()]
            if not rows:
                raise RuntimeError("recall_fixture_knowledge_missing: no matching-scope bounded OTP worker record")
            return sorted(set(rows))

        before = inventory()
        expected = {row[0] for row in before}
        detail["expected_ids"] = sorted(expected)
        partition = self.fixture["hosts"][0]["partition"]
        selection = {"memory_space_id": partition["memory_space_id"], "host": partition["host_id"],
                     "client": partition["client_id"], "scope": partition["scope"], "namespace": partition["namespace"]}
        queries = {"exact": "bounded OTP workers",
                   "paraphrase": "Which worker design does this project favor over limitless background execution?"}
        for interface in ("direct", "mcp"):
            for name, query in queries.items():
                arguments = {"query": query, "limit": 10, "token_budget": 2048}
                started = time.monotonic()
                result = self.direct("recall", arguments) if interface == "direct" else self.tool("recall", arguments)
                elapsed = (time.monotonic() - started) * 1000
                ids = sorted({row["id"] for row in result.get("results", [])
                              if isinstance(row, dict) and isinstance(row.get("id"), str)})
                trace = result.get("recall_run_id")
                vector = result.get("channels", {}).get("vector", {})
                used = result.get("used_tokens")
                case = {"interface": interface, "case": name, "query": query, "trace": trace,
                        "result_ids": ids, "expected_ids": sorted(expected), "meaningful_hit": bool(expected.intersection(ids)),
                        "mode": result.get("mode"), "used_tokens": used, "token_budget": result.get("token_budget"),
                        "elapsed_ms": elapsed, "vector": vector,
                        "ui_url": "http://127.0.0.1:4221/memory/recall/" + str(trace) + "?" + urllib.parse.urlencode(selection)}
                detail["cases"].append(case)
                if case["mode"] != "online":
                    raise RuntimeError("recall_online_required: recall used an offline path")
                try:
                    if not isinstance(trace, str) or str(uuid.UUID(trace)) != trace:
                        raise ValueError("noncanonical UUID")
                except (ValueError, AttributeError):
                    raise RuntimeError("recall_v2_trace_required: missing or invalid Recall V2 trace UUID") from None
                if not isinstance(vector, dict) or vector.get("status") != "ok":
                    raise RuntimeError("recall_vector_required: vector channel did not complete successfully")
                if not case["meaningful_hit"]:
                    raise RuntimeError("recall_expected_knowledge_missing: no discovered preference selected")
                if type(used) is not int or not 0 < used <= 2048 or type(result.get("token_budget")) is not int or result["token_budget"] != 2048:
                    raise RuntimeError("recall_token_budget: positive usage within requested 2048 tokens required")
                if not math.isfinite(elapsed) or not 0 <= elapsed < 15000:
                    raise RuntimeError("recall_latency_budget: finite elapsed time below 15000 ms required")

        after = inventory()
        detail["expected_ids_after"] = sorted({row[0] for row in after})
        detail["fixture_inventory_stable"] = before == after
        detail["stability_basis"] = "matching-scope bounded OTP worker inventory before and after four cases"
        for name in queries:
            selected = [row["result_ids"] for row in detail["cases"] if row["case"] == name]
            compared = detail["fixture_inventory_stable"]
            matches = selected[0] == selected[1] if compared else None
            detail["comparisons"].append({"case": name, "compared": compared, "selected_identities_match": matches})
            if compared and not matches:
                raise RuntimeError("recall_direct_mcp_identity_mismatch: stable fixture selected different identities")
        return detail

    def save(self, phase, status, error=None, detail=None):
        report = {"run_id": self.run_id, "phase": phase, "status": status,
                  "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                  "evidence_level": "live-host-http-subset", "runtime_hook_integration": "adapter-only",
                  "complete_L01_L18": False, "error": error, "detail": detail,
                  "observations": self.observations}
        path = self.output / f"api-{phase}-{time.time_ns()}.json"
        with path.open("x") as stream:
            os.chmod(path, 0o600)
            json.dump(report, stream, indent=2)
        print(str(path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["provider", "discover", "write", "host-first", "capture", "inspect", "recall", "workload"])
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--host-url", default="http://127.0.0.1:4222")
    parser.add_argument("--timeout", default=90, type=float)
    parser.add_argument("--sessions", default=4, type=int)
    args = parser.parse_args()
    run = Acceptance(args.fixture, args.host_url, args.timeout, args.sessions)
    try:
        if args.phase == "workload":
            run.discover()
            run.write()
            run.capture()
            detail = run.inspect()
        else:
            detail = getattr(run, args.phase.replace("-", "_"))()
        run.save(args.phase, "passed-subset", detail=detail)
        return 0
    except (RuntimeError, ValueError, OSError, urllib.error.URLError) as error:
        run.save(args.phase, "failed", error=str(error), detail=getattr(run, "recall_detail", None))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
