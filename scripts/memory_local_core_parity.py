#!/usr/bin/env python3
"""Check an online direct/MCP core subset on the prepared local fixture.

Creates one uniquely marked synthetic memory, observes normal settlement, uses
two configured-provider recalls, then forgets only that memory. No lifecycle,
configuration, database, or worker operations. Offline parity and full L02/L12
acceptance remain separate. Use a fresh --case-id for every invocation.
"""

import argparse
import datetime
import json
import math
import os
import re
import stat
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class CheckFailed(RuntimeError):
    """Fixed nonsecret failure codes only."""


def require(condition, code):
    if not condition:
        raise CheckFailed(code)


def valid_uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except (ValueError, TypeError, AttributeError):
        return False


def safe_receipt(result):
    """Keep identity/consistency evidence without response content or raw errors."""
    if not isinstance(result, dict):
        return {}
    safe = {}
    for key in ("id", "canonical_id"):
        if valid_uuid(result.get(key)):
            safe[key] = result[key]
        elif key in result:
            safe[key + "_valid"] = False
    enums = {"sync_state": ("pending", "synced", "failed"),
             "authority": ("canonical", "provisional", "canonical_with_provisional"),
             "consistency": ("canonical", "pending_canonical_ack", "read_your_writes", "bounded_stale", "provisional_only")}
    for key, allowed in enums.items():
        if isinstance(result.get(key), str) and result[key] in allowed:
            safe[key] = result[key]
    if type(result.get("revision")) is int or result.get("revision") is None:
        safe["revision"] = result.get("revision")
    return safe


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


class Effects:
    now = staticmethod(time.monotonic)
    sleep = staticmethod(time.sleep)

    def revision(self):
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                       text=True, timeout=2).strip()

    def post(self, base, path, body, timeout):
        request = urllib.request.Request(base + path, data=json.dumps(body, sort_keys=True).encode(),
                                         headers={"Content-Type": "application/json"}, method="POST")
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        try:
            response = opener.open(request, timeout=timeout)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read(1_000_001)
            require(len(raw) <= 1_000_000, "http_response_bound")
            return response.code, json.loads(raw)


class Runner:
    def __init__(self, fixture, case_id, host_url="http://127.0.0.1:4222", timeout=180,
                 cleanup_timeout=40, effects=None, output=None):
        self.fixture, self.case_id, self.host_url = Path(fixture), case_id, host_url
        self.timeout, self.cleanup_timeout, self.fx = timeout, cleanup_timeout, effects or Effects()
        self.output = Path(output) if output else ROOT / ".devenv/memory-local-evidence" / ("core-parity31-" + str(time.time_ns()) + ".json")
        self.started = self.fx.now()
        self.sequence, self.write_attempted, self.deleted = 0, False, False
        self.local_id, self.canonical_id, self.forget_started = None, None, False
        self.report = {"status": "failed", "evidence_level": "online-host-http-subset",
                       "complete_L02": False, "complete_L04": False, "complete_L12": False,
                       "complete_L01_L18": False, "observations": [], "cleanup": {"status": "not-needed"}}

    def remaining(self, cleanup=False):
        deadline = self.cleanup_deadline if cleanup else self.started + self.timeout - self.cleanup_timeout
        remaining = deadline - self.fx.now()
        require(remaining > 0, "cleanup_deadline" if cleanup else "work_deadline")
        return remaining

    def pause(self, cleanup=False):
        self.fx.sleep(min(1, self.remaining(cleanup)))

    def record(self, phase, **safe):
        self.report["observations"].append({"phase": phase, **safe})

    def preflight(self):
        require(type(self.timeout) in (int, float) and math.isfinite(self.timeout)
                and 10 <= self.timeout <= 300 and type(self.cleanup_timeout) in (int, float)
                and math.isfinite(self.cleanup_timeout) and 3 <= self.cleanup_timeout < self.timeout,
                "bounded_timeout_required")
        require(isinstance(self.case_id, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,39}", self.case_id), "case_id_invalid")
        parsed = urllib.parse.urlsplit(self.host_url)
        require(parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost", "::1")
                and parsed.port == 4222 and parsed.username is None and parsed.password is None
                and parsed.path in ("", "/") and not parsed.query and not parsed.fragment,
                "fixture_loopback_endpoint_required")
        self.host_url = self.host_url.rstrip("/")
        info = self.fixture.lstat()
        require(stat.S_ISREG(info.st_mode) and not self.fixture.is_symlink()
                and info.st_uid == os.getuid() and not info.st_mode & 0o077
                and info.st_size <= 1_000_000, "private_fixture_required")
        with os.fdopen(os.open(self.fixture, os.O_RDONLY | os.O_NOFOLLOW)) as stream:
            opened = os.fstat(stream.fileno())
            require((info.st_dev, info.st_ino) == (opened.st_dev, opened.st_ino), "fixture_identity_changed")
            fixture = json.load(stream)
        run_id = fixture.get("run_id")
        require(isinstance(run_id, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}", run_id), "fixture_run_id_invalid")
        primary = fixture["hosts"][0]
        partition = primary["partition"]
        require(all(valid_uuid(partition.get(key)) for key in ("memory_space_id", "host_id"))
                and primary.get("host_id") == partition["host_id"]
                and partition.get("client_id") == "host:" + partition["host_id"]
                and partition.get("scope") == "memory_local_" + run_id + "_primary"
                and partition.get("namespace") == "private", "fixture_partition_required")
        self.scope, self.run_id = partition["scope"], run_id
        self.agent = "memory-local-" + run_id + "-core-parity-" + self.case_id
        self.marker = "MEMORY-LOCAL-" + run_id + " CORE-PARITY-" + self.case_id
        self.content = self.marker + ": Use bounded OTP workers with canonical PostgreSQL storage for the synthetic Sapphire deployment."
        self.facets = [{"dimension": "project", "value": "/synthetic/backplane-memory/" + run_id + "/core-parity/" + self.case_id}]
        self.arguments = {"content": self.content, "agent_id": self.agent, "scope": self.scope,
                          "type": "procedural", "facets": self.facets,
                          "idempotency_key": self.agent + ":remember"}
        revision = self.fx.revision()
        require(isinstance(revision, str) and re.fullmatch(r"[0-9a-f]{40}", revision), "source_revision_required")
        require(not self.output.exists() and not self.output.is_symlink(), "fresh_output_required")
        self.report.update(run_id=run_id, case_id=self.case_id, marker=self.marker, revision=revision,
                           partition={key: partition[key] for key in ("memory_space_id", "host_id", "client_id", "scope", "namespace")},
                           source_state="uncommitted task checkout")

    def request(self, path, body, interface, method, cleanup=False):
        self.sequence += 1
        tool_name = body.get("params", {}).get("name") if method == "tools/call" else ("memory::" + method if interface == "direct" else None)
        started = self.fx.now()
        try:
            status, reply = self.fx.post(self.host_url, path, body, min(20, self.remaining(cleanup)))
        except CheckFailed:
            raise
        except Exception:
            self.record("http", interface=interface, method=method, tool_name=tool_name, cleanup=cleanup, transport_failed=True)
            raise CheckFailed("http_transport_failed") from None
        self.record("http", interface=interface, method=method, tool_name=tool_name, cleanup=cleanup, http_status=status if type(status) is int else None,
                    elapsed_ms=round((self.fx.now() - started) * 1000))
        self.remaining(cleanup)
        require(status in (200, 202) and isinstance(reply, dict), "http_success_required")
        return reply

    def mcp(self, method, params, cleanup=False):
        request_id = self.sequence + 1
        reply = self.request(f"/memory/{self.agent}/mcp", {
            "jsonrpc": "2.0", "id": request_id, "method": method, "params": params,
        }, "mcp", method, cleanup)
        require(reply.get("jsonrpc") == "2.0" and reply.get("id") == request_id
                and "error" not in reply and isinstance(reply.get("result"), dict), "mcp_success_required")
        return reply["result"]

    def call(self, interface, method, arguments, cleanup=False):
        if interface == "direct":
            reply = self.request(f"/memory/{self.agent}/call/{method}", arguments, interface, method, cleanup)
            require(reply.get("ok") is True and isinstance(reply.get("result"), dict), "direct_" + method + "_rejected")
            value = reply["result"]
            self.record("tool_receipt", interface=interface, tool_name="memory::" + method, cleanup=cleanup, receipt=safe_receipt(value))
            return value
        result = self.mcp("tools/call", {"name": "memory::" + method, "arguments": arguments}, cleanup)
        require(result.get("isError") is False, "mcp_" + method + "_rejected")
        parts = result.get("content", [])
        require(isinstance(parts, list) and len(parts) == 1 and isinstance(parts[0], dict)
                and parts[0].get("type") == "text" and isinstance(parts[0].get("text"), str), "mcp_json_text_required")
        value = json.loads(parts[0]["text"])
        require(isinstance(value, dict), "mcp_object_required")
        self.record("tool_receipt", interface=interface, tool_name="memory::" + method, cleanup=cleanup, receipt=safe_receipt(value))
        return value

    def discover(self):
        initialized = self.mcp("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                              "clientInfo": {"name": "memory-local-core-parity", "version": "1"}})
        require(initialized.get("protocolVersion") == "2025-11-25", "discovery_protocol_mismatch")
        tools = self.mcp("tools/list", {}).get("tools")
        require(isinstance(tools, list) and all(isinstance(tool, dict) for tool in tools), "discovery_tools_required")
        indexed = {tool.get("name"): tool for tool in tools}
        require(len(indexed) == len(tools), "discovery_duplicate_tool")
        fields = {
            "remember": {"content": "string", "agent_id": "string", "type": "string", "scope": "string", "idempotency_key": "string", "facets": "array"},
            "recall": {"query": "string", "limit": "integer", "token_budget": "integer"},
            "list": {"scope": "string", "q": "string", "agent_id": "string", "limit": "integer"},
            "stats": {}, "forget": {"id": "string"}, "facet_query": {"facets": "array", "limit": "integer"},
        }
        required = {"remember": ["content", "agent_id"], "recall": ["query"], "forget": ["id"], "facet_query": ["facets"]}
        for name, properties in fields.items():
            tool = indexed.get("memory::" + name, {})
            schema = tool.get("inputSchema", {})
            require(schema.get("type") == "object" and all(schema.get("properties", {}).get(key, {}).get("type") == kind
                    for key, kind in properties.items()) and sorted(schema.get("required", [])) == sorted(required.get(name, [])),
                    "discovery_schema_mismatch")
            if name in ("remember", "recall"):
                require(schema.get("additionalProperties") is False, "discovery_schema_mismatch")
            metadata = tool.get("_meta", {}).get("backplane", {})
            require(metadata == {"permission": "memory.write" if name in ("remember", "forget") else "memory.read",
                                 "authority": "canonical", "consistency": "canonical_or_bounded_stale", "availability": "online_or_offline"},
                    "discovery_metadata_mismatch")
        facet_items = indexed["memory::remember"]["inputSchema"]["properties"]["facets"].get("items", {})
        require(facet_items.get("type") == "object" and sorted(facet_items.get("required", [])) == ["dimension", "value"]
                and all(facet_items.get("properties", {}).get(key, {}).get("type") == "string" for key in ("dimension", "value")),
                "discovery_schema_mismatch")
        self.record("discovery", core_schemas_checked=True, canonical_facet_query=True)

    def online(self, result):
        require(result.get("mode") == "online" and result.get("stale") is False
                and result.get("authority") in ("canonical", "canonical_with_provisional")
                and type(result.get("pending_operations")) is int and result["pending_operations"] >= 0
                and result.get("overlay_truncated") is False, "online_read_required")

    def listing(self, interface, arguments=None, cleanup=False):
        result = self.call(interface, "list", {"scope": self.scope, "limit": 100, **(arguments or {})}, cleanup)
        self.online(result)
        rows = result.get("items", result.get("results"))
        require(isinstance(rows, list) and len(rows) < 100 and all(isinstance(row, dict) and valid_uuid(row.get("id")) for row in rows), "bounded_list_required")
        ids = [row["id"] for row in rows]
        require(len(set(ids)) == len(ids), "duplicate_list_identity")
        return result, rows

    def inventory(self, interface, cleanup=False):
        result, rows = self.listing(interface, {"q": "MEMORY-LOCAL-" + self.run_id}, cleanup)
        require(all(row.get("scope") == self.scope for row in rows), "list_partition_mismatch")
        return {row["id"] for row in rows}

    def owned_row(self, rows):
        require(len(rows) == 1 and rows[0].get("content") == self.content
                and rows[0].get("scope") == self.scope, "unique_owned_record_required")
        return rows[0]

    def settle(self, cleanup=False):
        while True:
            direct, rows = self.listing("direct", {"q": self.marker}, cleanup)
            other, mcp_rows = self.listing("mcp", {"q": self.marker}, cleanup)
            if direct["pending_operations"] == 0 and other["pending_operations"] == 0 and rows and mcp_rows:
                row, other_row = self.owned_row(rows), self.owned_row(mcp_rows)
                require(row["id"] == other_row["id"], "list_identity_mismatch")
                require(self.canonical_id in (None, row["id"]), "canonical_identity_changed")
                self.canonical_id = row["id"]
                self.report["canonical_id"] = self.canonical_id
                return row, other_row
            self.pause(cleanup)

    def fields(self, rows):
        for row in rows:
            require(row.get("memory_type") == "procedural", "accepted_type_lost")
            if "agent_id" in row:
                require(row["agent_id"] == self.agent, "accepted_agent_lost")
            if "facets" in row:
                require(row["facets"] == self.facets, "accepted_facets_lost")
        for interface in ("direct", "mcp"):
            for agent, expected in ((self.agent, [self.canonical_id]), (self.agent + "-other", [])):
                _, selected = self.listing(interface, {"q": self.marker, "agent_id": agent})
                require([row["id"] for row in selected] == expected, "accepted_agent_lost")
            for facets, expected in ((self.facets, [self.canonical_id]),
                                     ([{"dimension": "project", "value": self.facets[0]["value"] + "-other"}], [])):
                result = self.call(interface, "facet_query", {"facets": facets, "limit": 10})
                require("mode" not in result or result["mode"] == "online", "online_read_required")
                selected = result.get("results")
                require(isinstance(selected, list) and all(isinstance(row, dict) for row in selected)
                        and [row.get("id") for row in selected] == expected, "accepted_facets_lost")
        self.record("accepted_fields", memory_type="procedural", agent_proof="positive-and-negative-list-filters",
                    facet_proof="positive-and-negative-canonical-facet-query", row_agent_exposed=all("agent_id" in row for row in rows),
                    row_facets_exposed=all("facets" in row for row in rows))

    def stats(self, interface):
        result = self.call(interface, "stats", {})
        self.online(result)
        rows = result.get("stats")
        require(isinstance(rows, list) and all(isinstance(row, dict) and row.get("memory_type") in
                ("working", "episodic", "semantic", "procedural") and type(row.get("count")) is int and row["count"] >= 0 for row in rows),
                "stats_shape_required")
        counts = {row["memory_type"]: row["count"] for row in rows}
        require(len(counts) == len(rows), "stats_shape_required")
        return counts

    def recall(self):
        arguments = {"query": self.content, "scope": self.scope, "limit": 10, "token_budget": 2048}
        for interface in ("direct", "mcp"):
            result = self.call(interface, "recall", arguments)
            self.online(result)
            require(result.get("channels", {}).get("vector", {}).get("status") == "ok", "configured_vector_required")
            require(valid_uuid(result.get("recall_run_id")), "recall_trace_required")
            require(type(result.get("used_tokens")) is int and 0 < result["used_tokens"] <= 2048
                    and result.get("token_budget") == 2048, "recall_token_budget_required")
            rows = result.get("results")
            require(isinstance(rows, list) and sum(isinstance(row, dict) and row.get("id") == self.canonical_id for row in rows) == 1,
                    "recall_expected_identity_missing")
            self.record("recall", interface=interface, expected_identity_present=True, vector_status="ok",
                        recall_run_id=result["recall_run_id"], used_tokens=result["used_tokens"])

    def require_forget_receipt(self, receipt):
        require(receipt.get("id") in ({self.canonical_id, self.local_id} - {None})
                and receipt.get("canonical_id") == self.canonical_id
                and receipt.get("sync_state") in ("pending", "synced"), "forget_receipt_required")
        if receipt["sync_state"] == "pending":
            require(receipt.get("authority") == "provisional"
                    and receipt.get("consistency") == "pending_canonical_ack"
                    and receipt.get("revision") is None, "forget_pending_receipt_required")
        else:
            require(receipt.get("authority") == "canonical" and receipt.get("consistency") == "canonical"
                    and type(receipt.get("revision")) is int and receipt["revision"] > 0,
                    "canonical_forget_ack_required")

    def forget(self, cleanup=False):
        if not self.forget_started:
            self.forget_started = True
            first = self.call("direct", "forget", {"id": self.canonical_id}, cleanup)
            self.require_forget_receipt(first)
        while True:
            repeated = self.call("mcp", "forget", {"id": self.canonical_id}, cleanup)
            self.require_forget_receipt(repeated)
            _, direct_rows = self.listing("direct", {"q": self.marker}, cleanup)
            _, mcp_rows = self.listing("mcp", {"q": self.marker}, cleanup)
            if repeated["sync_state"] == "synced":
                require(repeated.get("authority") == "canonical" and repeated.get("consistency") == "canonical"
                        and type(repeated.get("revision")) is int and repeated["revision"] > 0, "canonical_forget_ack_required")
                require(not direct_rows and not mcp_rows, "forgotten_record_still_visible")
                self.deleted = True
                self.report["online_canonical_forget"] = True
                self.record("forget", canonical_id=self.canonical_id, repeated_contract="synced-canonical-receipt",
                            revision=repeated["revision"], both_online_lists_absent=True)
                return
            self.pause(cleanup)

    def preserve_baseline(self, cleanup=False):
        for interface in ("direct", "mcp"):
            require(self.baseline <= self.inventory(interface, cleanup), "preexisting_fixture_record_missing")
        self.record("preservation", baseline_count=len(self.baseline), preexisting_fixture_ids_preserved=True)

    def cleanup(self):
        self.cleanup_deadline = min(self.started + self.timeout, self.fx.now() + self.cleanup_timeout)
        if not self.deleted:
            if not self.forget_started:
                self.settle(cleanup=True)
            self.forget(cleanup=True)
        self.preserve_baseline(cleanup=True)
        self.report["cleanup"] = {"status": "passed", "only_owned_marker_forgotten": True}

    def run(self):
        try:
            self.preflight()
            self.discover()
            self.baseline = self.inventory("direct")
            require(self.baseline == self.inventory("mcp"), "baseline_list_parity_mismatch")
            for interface in ("direct", "mcp"):
                _, rows = self.listing(interface, {"q": self.marker})
                require(not rows, "fresh_case_required")
            self.write_attempted = True
            first = self.call("direct", "remember", self.arguments)
            require(valid_uuid(first.get("id")), "remember_identity_required")
            self.local_id = first["id"]
            repeated = self.call("mcp", "remember", self.arguments)
            require(repeated.get("id") == first["id"], "remember_identity_mismatch")
            for receipt in (first, repeated):
                state = (receipt.get("sync_state"), receipt.get("authority"), receipt.get("consistency"))
                require(state in (("pending", "provisional", "pending_canonical_ack"),
                                  ("synced", "canonical", "canonical")), "remember_receipt_required")
                if receipt["sync_state"] == "synced":
                    require(valid_uuid(receipt.get("canonical_id"))
                            and type(receipt.get("revision")) is int and receipt["revision"] > 0,
                            "remember_receipt_required")
                if receipt.get("canonical_id") is not None:
                    require(valid_uuid(receipt["canonical_id"]), "canonical_identity_required")
                    require(self.canonical_id in (None, receipt["canonical_id"]), "canonical_identity_changed")
                    self.canonical_id = receipt["canonical_id"]
            self.record("remember", local_id=first["id"], exact_retry_same_identity=True,
                        initial_sync_state=first["sync_state"], retry_sync_state=repeated["sync_state"],
                        initial_authority=first["authority"], retry_authority=repeated["authority"],
                        initial_consistency=first["consistency"], retry_consistency=repeated["consistency"])
            self.fields(self.settle())
            self.record("settlement", canonical_id=self.canonical_id,
                        proof="unique-content-and-scope-online-without-pending-overlay")
            require(self.inventory("direct") == self.inventory("mcp"), "list_parity_mismatch")
            direct_stats = self.stats("direct")
            require(direct_stats == self.stats("mcp") == self.stats("direct"), "stats_parity_mismatch")
            self.record("read_parity", list_identities_match=True, stats=direct_stats)
            self.recall()
            self.forget()
            self.preserve_baseline()
            self.report["status"] = "passed-subset"
        except CheckFailed as error:
            self.report["error"] = str(error)
        except KeyboardInterrupt:
            self.report["error"] = "interrupted"
        except Exception:
            self.report["error"] = "unexpected_error"
        finally:
            if self.write_attempted:
                self.record("cleanup_start", sequence=self.sequence)
                try:
                    self.cleanup()
                except Exception as error:
                    self.report["status"] = "failed"
                    self.report["cleanup"] = {"status": "failed", "error": str(error) if isinstance(error, CheckFailed) else "cleanup_failed",
                                              "retained_marker_requires_inspection": True}
                finally:
                    self.record("cleanup_end", sequence=self.sequence, cleanup_status=self.report["cleanup"]["status"])
            self.report["elapsed_seconds"] = round(self.fx.now() - self.started, 3)
            self.report["recorded_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            self.output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            with os.fdopen(os.open(self.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "w") as stream:
                json.dump(self.report, stream, indent=2)
                stream.write("\n")
        return self.report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--case-id", required=True)
    parser.add_argument("--host-url", default="http://127.0.0.1:4222")
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--cleanup-timeout", type=float, default=40)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    runner = Runner(**vars(args))
    try:
        report = runner.run()
    except Exception:
        print("core_parity_report_write_failed")
        return 2
    print(runner.output)
    return 0 if report["status"] == "passed-subset" else 1


if __name__ == "__main__":
    raise SystemExit(main())
