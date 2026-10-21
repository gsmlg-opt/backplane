#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["playwright==1.56.0"]
# ///
"""Local shared-access acceptance helpers; integration runner is not yet qualified.

Uses actual Admin controls and host direct/MCP APIs, without SQL authority writes.
Denial checks deliberately reject transport and validation failures as evidence.
"""

import argparse
import datetime
import importlib.util
import json
import os
import re
import subprocess
import time
import urllib.parse
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class CheckFailed(RuntimeError):
    """Fixed nonsecret failure code suitable for retained reports."""


def require(condition, code):
    if not condition:
        raise CheckFailed(code)


def rpc_result(reply, request_id):
    require(isinstance(reply, dict) and reply.get("jsonrpc") == "2.0"
            and reply.get("id") == request_id, "rpc_identity_mismatch")
    require("error" not in reply and isinstance(reply.get("result"), dict), "rpc_result_required")
    return reply["result"]


def tool_text(result):
    content = result.get("content")
    require(isinstance(content, list) and len(content) == 1
            and isinstance(content[0], dict) and content[0].get("type") == "text"
            and isinstance(content[0].get("text"), str), "single_tool_text_required")
    return content[0]["text"]


def decode_reply(interface, status, reply, request_id=None):
    require(status == 200, "operation_http_success_required")
    if interface == "direct":
        require(isinstance(reply, dict) and reply.get("ok") is True
                and "error" not in reply and isinstance(reply.get("result"), dict), "direct_success_required")
        return reply["result"]
    require(interface == "mcp", "unknown_interface")
    result = rpc_result(reply, request_id)
    require(result.get("isError") is False, "tool_success_required")
    try:
        payload = json.loads(tool_text(result))
    except (ValueError, TypeError):
        raise CheckFailed("tool_json_required") from None
    require(isinstance(payload, dict), "tool_object_required")
    return payload


def assert_denied(interface, status, reply, protected_marker, request_id=None):
    require(isinstance(protected_marker, str) and bool(protected_marker), "protected_marker_required")
    require(protected_marker not in json.dumps(reply, sort_keys=True), "denial_disclosed_content")
    if interface == "direct":
        require(status in (400, 401, 403) and isinstance(reply, dict)
                and reply.get("ok") is False and set(reply) == {"ok", "error"}, "direct_denial_required")
        message = reply.get("error")
    else:
        require(interface == "mcp" and status == 200, "mcp_denial_required")
        require(isinstance(reply, dict) and reply.get("jsonrpc") == "2.0"
                and reply.get("id") == request_id, "rpc_identity_mismatch")
        if "error" in reply:
            require(set(reply) == {"jsonrpc", "id", "error"} and isinstance(reply["error"], dict)
                    and set(reply["error"]) == {"code", "message"}
                    and reply["error"].get("code") == -32000, "rpc_denial_required")
            message = reply["error"].get("message")
        else:
            result = rpc_result(reply, request_id)
            require(set(reply) == {"jsonrpc", "id", "result"}
                    and set(result) == {"isError", "content"}
                    and result.get("isError") is True, "tool_denial_required")
            message = tool_text(result)
    # Exact known permanent outcomes only. Never infer authority from HTTP 503,
    # malformed-argument errors, free text, or a timed-out channel.
    messages = {code: code for code in ("unauthorized", "authority_changed", "partition_mismatch")}
    messages.update({"hub unreachable: " + code: code for code in tuple(messages)})
    require(isinstance(message, str) and message in messages, "permanent_denial_required")
    return messages[message]


def shared_receipt(result):
    require(isinstance(result, dict) and set(result) == {
        "command_id", "status", "canonical_id", "revision", "authority", "consistency"
    } and len(json.dumps(result)) <= 1024, "bounded_shared_receipt_required")
    def valid_uuid(value):
        try:
            return isinstance(value, str) and str(uuid.UUID(value)) == value
        except ValueError:
            return False
    require(valid_uuid(result["command_id"]), "receipt_command_identity_required")
    if result["status"] == "committed":
        require(valid_uuid(result["canonical_id"]) and type(result["revision"]) is int
                and result["revision"] > 0 and result["authority"] == "canonical"
                and result["consistency"] == "canonical", "committed_receipt_required")
    else:
        require(result["status"] == "pending" and result["canonical_id"] is None
                and result["revision"] is None and result["authority"] == "provisional"
                and result["consistency"] == "pending_canonical_ack", "pending_receipt_required")
    return result


def access_row(rows, host_id):
    require(isinstance(rows, list) and isinstance(host_id, str) and bool(host_id), "access_rows_required")
    matches = [row for row in rows if isinstance(row, list) and len(row) == 8
               and host_id in row[0].splitlines()]
    require(len(matches) == 1, "unique_exact_recipient_required")
    row = matches[0]
    try:
        version = int(row[5])
        lease = int(row[4].removesuffix("s"))
    except (ValueError, TypeError):
        raise CheckFailed("invalid_access_row") from None
    require(version > 0 and 0 <= lease <= 300 and row[2] in ("active", "revoked"), "invalid_access_row")
    return {"access_id": row[1], "status": row[2], "capabilities": sorted(filter(None,
            (value.strip() for value in row[3].split(",")))), "lease": lease,
            "version": version, "reason": row[6]}


class AdminAccess:
    """Browser-only grants with displayed CAS version and exact partition checks."""

    def __init__(self, page, partition, recipient, admin_url="http://127.0.0.1:4221"):
        parsed = urllib.parse.urlsplit(admin_url)
        require(parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost", "::1")
                and parsed.port == 4221 and not parsed.username and not parsed.password
                and parsed.path in ("", "/") and not parsed.query and not parsed.fragment,
                "local_admin_required")
        self.page, self.partition, self.recipient = page, partition, recipient
        self.url = admin_url.rstrip("/") + "/memory/memories?" + urllib.parse.urlencode(partition)

    def open(self):
        response = self.page.goto(self.url, wait_until="networkidle", timeout=30000)
        require(response is not None and response.status == 200, "admin_http_success_required")
        self.page.locator("[data-phx-main].phx-connected").wait_for(timeout=15000)
        target = self.page.locator("#memory-access-target").inner_text()
        require(all(str(self.partition[key]) in target for key in ("memory_space_id", "scope", "namespace")),
                "admin_partition_mismatch")
        self.page.locator("#memory-access-form").wait_for(timeout=15000)

    def rows(self):
        return self.page.locator("#memory-access-table tbody tr").evaluate_all(
            "rows => rows.map(row => Array.from(row.querySelectorAll('td'), td => td.innerText.trim()))")

    def current(self):
        return access_row(self.rows(), self.recipient)

    def edit(self, expected):
        current = self.current()
        require(expected is not None and current == expected, "operator_changed_test_grant")
        self.page.locator("#memory-access-edit-" + current["access_id"]).click()
        self.page.wait_for_function("version => document.querySelector('#memory-access-version').value === String(version)",
                                    arg=current["version"], timeout=10000)
        return current

    def guard_submission(self, expected):
        if expected is None:
            require(not any(self.recipient in row[0].splitlines() for row in self.rows()),
                    "grant_already_exists")
            version = 0
        else:
            require(self.current() == expected, "operator_changed_test_grant")
            version = expected["version"]
        require(self.page.locator("#memory-access-version").input_value() == str(version),
                "editor_authority_version_changed")

    def save(self, capabilities, reason, lease=0, creating=False, expected=None):
        require(set(capabilities) <= {"read", "deliver", "remember", "forget"}
                and isinstance(reason, str) and 0 < len(reason) <= 512, "bounded_policy_required")
        if creating:
            require(not any(self.recipient in row[0].splitlines() for row in self.rows()), "grant_already_exists")
            self.page.locator("#memory-access-recipient").select_option(self.recipient)
            previous = None
        else:
            previous = self.edit(expected)
        for capability in ("read", "deliver", "remember", "forget"):
            self.page.locator("#memory-access-" + capability).set_checked(capability in capabilities)
        self.page.locator("#memory-access-lease").fill(str(lease))
        self.page.locator("#memory-access-reason").fill(reason)
        self.guard_submission(previous)
        self.page.locator("#memory-access-save").click()
        return self.wait_policy(capabilities, reason, lease, "active", previous)

    def revoke(self, reason, expected):
        previous = self.edit(expected)
        require(previous["status"] == "active", "active_grant_required")
        self.page.locator("#memory-access-reason").fill(reason)
        self.guard_submission(previous)
        self.page.locator("#memory-access-revoke").click()
        return self.wait_policy(previous["capabilities"], reason, previous["lease"], "revoked", previous)

    def wait_policy(self, capabilities, reason, lease, status, previous):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.page.locator("#memory-access-error").count():
                raise CheckFailed("admin_policy_rejected")
            rows = self.rows()
            if not any(self.recipient in row[0].splitlines() for row in rows):
                self.page.wait_for_timeout(100)
                continue
            current = access_row(rows, self.recipient)
            if (current["capabilities"] == sorted(capabilities) and current["lease"] == lease
                    and current["status"] == status and current["reason"] == reason):
                require(previous is None or (current["access_id"] == previous["access_id"]
                        and current["version"] > previous["version"]), "authority_version_not_advanced")
                return current
            self.page.wait_for_timeout(100)
        raise CheckFailed("admin_policy_not_observed")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


class HostAPI:
    def __init__(self, port, agent, observations, deadline):
        require(port in (4222, 4223), "fixture_host_port_required")
        self.base, self.agent = "http://127.0.0.1:" + str(port), agent
        self.observations, self.deadline, self.sequence = observations, deadline, 0
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def post(self, path, body):
        remaining = self.deadline - time.monotonic()
        require(remaining > 0, "driver_deadline")
        request = urllib.request.Request(self.base + path, data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"}, method="POST")
        started = time.monotonic()
        try:
            try:
                response = self.opener.open(request, timeout=min(20, remaining))
            except urllib.error.HTTPError as error:
                response = error
            with response:
                raw = response.read(1_000_001)
                require(len(raw) <= 1_000_000, "http_response_bound")
                status, reply = response.code, json.loads(raw)
        except CheckFailed:
            raise
        except Exception:
            raise CheckFailed("host_transport_or_json_failure") from None
        self.observations.append({"port": int(self.base.rsplit(":", 1)[1]), "path": path,
                                  "http_status": status, "elapsed_ms": round((time.monotonic() - started) * 1000)})
        return status, reply

    def raw(self, interface, method, arguments):
        self.sequence += 1
        request_id = self.sequence
        if interface == "direct":
            status, reply = self.post(f"/memory/{self.agent}/call/{method}", arguments)
        else:
            require(interface == "mcp", "unknown_interface")
            status, reply = self.post(f"/memory/{self.agent}/mcp", {
                "jsonrpc": "2.0", "id": request_id, "method": "tools/call",
                "params": {"name": "memory::" + method, "arguments": arguments}})
        return status, reply, request_id

    def call(self, interface, method, arguments):
        status, reply, request_id = self.raw(interface, method, arguments)
        return decode_reply(interface, status, reply, request_id)

    def denied(self, interface, method, arguments, marker):
        status, reply, request_id = self.raw(interface, method, arguments)
        return assert_denied(interface, status, reply, marker, request_id)

    def discover(self):
        for method, params in (("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                               "clientInfo": {"name": "local-shared-access", "version": "1"}}),
                               ("tools/list", {})):
            self.sequence += 1
            status, reply = self.post(f"/memory/{self.agent}/mcp", {
                "jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params})
            require(status == 200, "discovery_http_success_required")
            result = rpc_result(reply, self.sequence)
            if method == "tools/list":
                tools = {tool["name"]: tool for tool in result.get("tools", [])}
                for name in ("recall", "list", "stats", "remember", "forget"):
                    schema = tools.get("memory::" + name, {}).get("inputSchema", {})
                    selector = schema.get("properties", {}).get("memory_access_id", {})
                    require(selector.get("type") == "string" and "memory_access_id" not in schema.get("required", []),
                            "shared_selector_not_discovered")


def listed(result):
    require(result.get("mode") == "online" and result.get("stale") is False
            and result.get("authority") in ("canonical", "canonical_with_provisional"), "online_canonical_list_required")
    rows = result.get("items", result.get("results"))
    require(isinstance(rows, list) and len(rows) < 100 and all(isinstance(row, dict) for row in rows),
            "bounded_list_required")
    ids = [row.get("id") for row in rows]
    require(all(isinstance(value, str) for value in ids) and len(ids) == len(set(ids)), "unique_memory_ids_required")
    return rows


class OnlineMatrix:
    """Online independent-capability subset. Outage/mirror/races remain separate gates."""

    def __init__(self, fixture, case_id, output, timeout):
        require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,39}", case_id) is not None, "case_id_invalid")
        require(120 <= timeout <= 900, "bounded_timeout_required")
        self.fixture = json.loads(Path(fixture).read_text())
        self.run_id = self.fixture["run_id"]
        require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}", self.run_id) is not None, "fixture_run_id_invalid")
        self.hosts = self.fixture["hosts"][:2]
        require(len(self.hosts) == 2, "two_hosts_required")
        for host in self.hosts:
            partition = host["partition"]
            require(str(uuid.UUID(host["host_id"])) == partition["host_id"]
                    and partition["client_id"] == "host:" + host["host_id"]
                    and partition["namespace"] == "private", "fixture_host_identity_mismatch")
        require(self.hosts[0]["host_id"] != self.hosts[1]["host_id"] and
                self.hosts[0]["partition"]["memory_space_id"] != self.hosts[1]["partition"]["memory_space_id"],
                "distinct_host_spaces_required")
        self.marker = "MEMORY-LOCAL-" + self.run_id + "-SHARED-" + case_id
        self.agent = "memory-local-" + self.run_id
        self.deadline = time.monotonic() + timeout
        self.report = {"run_id": self.run_id, "case_id": case_id, "status": "failed",
                       "evidence_level": "local-online-capability-matrix", "complete_L13": False,
                       "complete_L18": False, "complete_L01_L18": False, "observations": [], "policies": [],
                       "source_provenance_verified": False,
                       "limits": "No source-provenance proof, outage/lease/mirror/restart/race qualification or full retained-data inventory in this subset."}
        self.output = Path(output) if output else ROOT / ".devenv/memory-local-evidence" / self.run_id / ("shared-" + str(time.time_ns()))
        self.output.mkdir(mode=0o700, parents=True, exist_ok=False)
        self.a, self.b = [HostAPI(port, self.agent, self.report["observations"], self.deadline) for port in (4222, 4223)]
        self.admin, self.access, self.mutation_attempted = None, None, False
        self.owned_contents, self.created_ids = set(), set()

    def own_rows(self):
        deadline = min(self.deadline, time.monotonic() + 30)
        while time.monotonic() < deadline:
            result = self.a.call("direct", "list", {"q": self.marker + ":", "limit": 100})
            rows = [row for row in listed(result) if isinstance(row.get("content"), str)
                    and row["content"].startswith(self.marker + ":")]
            require(type(result.get("pending_operations")) is int, "pending_count_required")
            if result["pending_operations"] == 0:
                self.created_ids.update(row["id"] for row in rows
                                        if row["content"] in self.owned_contents)
                return rows
            time.sleep(0.2)
        raise CheckFailed("owner_private_commands_not_settled")

    def wait_rows(self, marker, present):
        deadline = min(self.deadline, time.monotonic() + 60)
        while time.monotonic() < deadline:
            rows = [row for row in self.own_rows() if marker in row.get("content", "")]
            if bool(rows) == present:
                require(not present or len(rows) == 1, "duplicate_canonical_effect")
                return rows
            time.sleep(0.2)
        raise CheckFailed("canonical_effect_not_observed")

    def policy(self, capabilities, phase, creating=False):
        if self.access is not None:
            require(self.admin.current() == self.access, "operator_changed_test_grant")
            if (self.access["status"] == "active" and self.access["capabilities"] == sorted(capabilities)
                    and self.access["lease"] == 0):
                self.report["policies"].append({"phase": phase, "unchanged": True, **self.access})
                return
        self.mutation_attempted = True
        self.access = self.admin.save(capabilities, self.marker + ":" + phase,
                                      creating=creating, expected=self.access)
        self.report["policies"].append({"phase": phase, **self.access})
        self.admin.page.screenshot(path=str(self.output / (phase + ".png")), full_page=True)
        # Observe the actual owner generation instead of assuming a push arrived.
        deadline = min(self.deadline, time.monotonic() + 20)
        while time.monotonic() < deadline:
            status, reply = self.b.post("/memory/diagnostics", {"memory_access_id": self.access["access_id"],
                                                             "command_ids": [], "mirror_ids": []})
            if status == 200:
                result = decode_reply("direct", status, reply)
                authority = result.get("access", {})
                if (result.get("observation_source") == "authority_owner"
                        and authority.get("access_id") == self.access["access_id"]
                        and authority.get("authority_version") == self.access["version"]
                        and sorted(authority.get("capabilities", [])) == sorted(capabilities)
                        and authority.get("status") in ("active", "needs_sync")):
                    self.report["observations"].append({"phase": phase, "host_authority": authority})
                    return
            elif status not in (403, 503):
                raise CheckFailed("authority_diagnostics_failed")
            time.sleep(0.2)
        raise CheckFailed("host_authority_not_observed")

    def selected(self, arguments):
        return {**arguments, "memory_access_id": self.access["access_id"]}

    def probe(self, capabilities, phase, sentinel_id):
        for interface in ("direct", "mcp"):
            arguments = self.selected({"q": self.marker + ":sentinel", "limit": 100})
            if "read" in capabilities:
                rows = listed(self.b.call(interface, "list", arguments))
                require([row["id"] for row in rows] == [sentinel_id], "shared_canonical_read_mismatch")
                self.b.call(interface, "stats", self.selected({}))
            else:
                self.b.denied(interface, "list", arguments, self.marker)
                self.b.denied(interface, "stats", self.selected({}), self.marker)
            if "remember" not in capabilities:
                self.b.denied(interface, "remember", self.selected({"agent_id": self.agent,
                    "content": self.marker + ":denied:" + phase, "type": "semantic",
                    "idempotency_key": self.marker + ":denied:" + phase}), self.marker)
            if "forget" not in capabilities:
                self.b.denied(interface, "forget", self.selected({"id": sentinel_id}), self.marker)
            # The default remains B even after a shared grant is installed.
            require(not listed(self.b.call(interface, "list", {"q": self.marker + ":", "limit": 100})),
                    "omitted_selector_changed_default")
        require(not any(":denied:" in row.get("content", "") for row in self.own_rows()), "denied_write_became_canonical")

    def write_shared(self, phase):
        marker = self.marker + ":" + phase
        self.owned_contents.add(marker)
        arguments = self.selected({"content": marker, "type": "semantic", "agent_id": self.agent,
                                   "idempotency_key": marker})
        receipts = [shared_receipt(self.b.call(interface, "remember", arguments))
                    for interface in ("direct", "mcp")]
        require(receipts[0].get("command_id") is not None
                and receipts[0].get("command_id") == receipts[1].get("command_id"),
                "shared_duplicate_command_identity_changed")
        self.report["observations"].append({"phase": phase, "command_id": receipts[0]["command_id"],
                                           "duplicate_identity_preserved": True})
        return self.wait_rows(marker, True)[0]["id"]

    def delete_shared(self, canonical_id, marker):
        arguments = self.selected({"id": canonical_id,
                                   "idempotency_key": f"{marker}:forget:{canonical_id}"})
        receipts = [shared_receipt(self.b.call(interface, "forget", arguments))
                    for interface in ("direct", "mcp")]
        require(receipts[0].get("command_id") is not None
                and receipts[0].get("command_id") == receipts[1].get("command_id"),
                "shared_duplicate_command_identity_changed")
        self.wait_rows(marker, False)

    def run_matrix(self):
        require(not self.own_rows(), "case_records_already_exist")
        self.a.discover()
        self.b.discover()
        self.owned_contents.add(self.marker + ":sentinel")
        self.a.call("direct", "remember", {"agent_id": self.agent, "type": "semantic",
                    "content": self.marker + ":sentinel", "idempotency_key": self.marker + ":sentinel"})
        sentinel = self.wait_rows(self.marker + ":sentinel", True)[0]["id"]
        self.report["sentinel_id"] = sentinel
        for interface in ("direct", "mcp"):
            require(not listed(self.b.call(interface, "list", {"q": self.marker + ":", "limit": 100})), "initial_isolation_failed")
        self.policy(["read"], "read-only", creating=self.access is None)
        self.probe(["read"], "read-only", sentinel)
        self.policy(["remember"], "remember-only")
        self.probe(["remember"], "remember-only", sentinel)
        written = self.write_shared("remember-only-write")
        self.policy(["forget"], "forget-only")
        self.probe(["forget"], "forget-only", sentinel)
        self.delete_shared(written, self.marker + ":remember-only-write")
        self.policy(["read", "deliver", "remember"], "read-deliver-remember")
        self.probe(["read", "deliver", "remember"], "read-deliver-remember", sentinel)
        written = self.write_shared("combined-write")
        self.policy(["read", "deliver", "forget"], "read-deliver-forget")
        self.probe(["read", "deliver", "forget"], "read-deliver-forget", sentinel)
        self.delete_shared(written, self.marker + ":combined-write")
        self.policy(["read", "deliver", "remember", "forget"], "all-four")
        self.probe(["read", "deliver", "remember", "forget"], "all-four", sentinel)
        written = self.write_shared("all-four-write")
        self.delete_shared(written, self.marker + ":all-four-write")
        require([row["id"] for row in self.own_rows()] == [sentinel], "unexpected_canonical_effect")
        self.report["status"] = "passed-subset"

    def cleanup(self):
        self.deadline = time.monotonic() + 90
        self.a.deadline = self.b.deadline = self.deadline
        if self.mutation_attempted:
            current = self.admin.current()
            require(current["reason"].startswith(self.marker + ":"), "cleanup_grant_ownership_lost")
            if self.access is not None:
                require(current == self.access, "cleanup_grant_version_changed")
            self.access = current
            self.policy(["read", "deliver", "remember", "forget"], "cleanup-authority")
            for row in self.cleanup_rows():
                shared_receipt(self.b.call("direct", "forget", self.selected({"id": row["id"]})))
            self.wait_rows(self.marker, False)
            self.access = self.admin.revoke(self.marker + ":cleanup-revoke", expected=self.access)
            self.report["cleanup"] = {"status": "passed", "grant": self.access, "own_records_absent": True}
        else:
            for row in self.cleanup_rows():
                self.a.call("direct", "forget", {"id": row["id"]})
            self.wait_rows(self.marker, False)
            self.report["cleanup"] = {"status": "passed", "own_records_absent": True}

    def cleanup_rows(self):
        rows = self.own_rows()
        require(all(row["id"] in self.created_ids and row["content"] in self.owned_contents
                    and row["content"].startswith(self.marker + ":") for row in rows),
                "cleanup_record_ownership_lost")
        return rows

    def preflight(self, primary_state, secondary_state):
        spec = importlib.util.spec_from_file_location("shared_lifecycle", ROOT / "scripts/memory_local_dev.py")
        lifecycle = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(lifecycle)
        for state_dir, port, host in ((primary_state, 4222, self.hosts[0]), (secondary_state, 4223, self.hosts[1])):
            state = lifecycle.status(state_dir)
            require(state.get("urls", {}).get("host") == "http://127.0.0.1:" + str(port) + "/"
                    and all(state.get("http_ready", {}).values())
                    and state.get("processes") and all(row.get("running") for row in state["processes"]), "owned_ready_stack_required")
            recorded = lifecycle.read_state(Path(state_dir).resolve())
            require(Path(recorded["config"]).resolve() == Path(host["config"]).resolve(), "owned_host_config_mismatch")

    def execute(self, primary_state, secondary_state):
        try:
            self.preflight(primary_state, secondary_state)
            partition = self.hosts[0]["partition"]
            selection = {"memory_space_id": partition["memory_space_id"], "host": partition["host_id"],
                         "client": partition["client_id"], "scope": partition["scope"], "namespace": partition["namespace"]}
            from playwright.sync_api import sync_playwright
            with sync_playwright() as playwright:
                browser = playwright.chromium.launch(channel="chrome", headless=True)
                try:
                    page = browser.new_page(viewport={"width": 1440, "height": 1000})
                    self.admin = AdminAccess(page, selection, self.hosts[1]["host_id"])
                    self.admin.open()
                    if any(self.hosts[1]["host_id"] in row[0].splitlines() for row in self.admin.rows()):
                        previous = self.admin.current()
                        require(previous["status"] == "revoked" and previous["reason"].startswith(
                            "MEMORY-LOCAL-" + self.run_id + "-SHARED-"), "preexisting_shared_grant_requires_separate_case")
                        self.access = previous
                    try:
                        self.run_matrix()
                    except Exception as error:
                        self.report["work_failure"] = str(error) if isinstance(error, CheckFailed) else type(error).__name__
                        raise
                    finally:
                        try:
                            self.cleanup()
                        except Exception as error:
                            self.report["cleanup"] = {"status": "failed", "failure": str(error) if isinstance(error, CheckFailed)
                                                      else type(error).__name__}
                            raise
                finally:
                    browser.close()
        except CheckFailed as error:
            self.report["status"] = "failed"
            self.report["failure"] = str(error)
        except Exception as error:
            self.report["status"] = "failed"
            self.report["failure"] = type(error).__name__
        self.report["recorded_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.report["revision"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        report_path = self.output / "report.json"
        with report_path.open("x") as stream:
            os.chmod(report_path, 0o600)
            json.dump(self.report, stream, indent=2)
        for path in self.output.glob("*.png"):
            os.chmod(path, 0o600)
        return report_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--case-id", required=True)
    parser.add_argument("--primary-state", type=Path, default=ROOT / ".devenv/memory-local")
    parser.add_argument("--secondary-state", type=Path, default=ROOT / ".devenv/memory-local-isolated")
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    run = OnlineMatrix(args.fixture, args.case_id, args.output, args.timeout)
    path = run.execute(args.primary_state, args.secondary_state)
    print(path)
    return 0 if run.report["status"] == "passed-subset" and "failure" not in run.report else 1


if __name__ == "__main__":
    raise SystemExit(main())
