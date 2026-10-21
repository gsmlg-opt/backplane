#!/usr/bin/env python3
"""Probe paired local HTTP/MCP Memory errors on an owned synthetic dev stack.

Creates one scoped synthetic record, waits for canonical and owner-connection ACK,
checks malformed arguments, an unknown operation and conflicting retries, then
forgets only its record. No database, provider, lifecycle or configuration actions.
Use a fresh --case-id. This is an online L02 subset, never full L01-L18 acceptance.
"""

import argparse
import datetime
import importlib.util
import json
import os
import stat
import time
from pathlib import Path


def load_script(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


core = load_script("negative_parity_core", "memory_local_core_parity.py")
lifecycle = load_script("negative_parity_lifecycle", "memory_local_dev.py")
ROOT, CheckFailed, require = core.ROOT, core.CheckFailed, core.require
UNKNOWN = "negative_parity_unknown_operation"
INVALID_MESSAGES = {
    "content is required": "content_required",
    "unsupported memory type": "unsupported_type",
    "facets must contain dimension and value strings": "invalid_facets",
    "idempotency_key must be a nonempty string": "invalid_idempotency_key",
    "Invalid params for tools/call": "invalid_argument_shape",
}


def private_json(path):
    path = Path(path).absolute()
    info = path.lstat()
    require(path.resolve(strict=True) == path and stat.S_ISREG(info.st_mode)
            and info.st_uid == os.getuid() and not info.st_mode & 0o077
            and info.st_nlink == 1 and info.st_size <= 1_000_000, "private_input_required")
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW)) as stream:
        opened = os.fstat(stream.fileno())
        require((opened.st_dev, opened.st_ino) == (info.st_dev, info.st_ino), "input_identity_changed")
        return json.load(stream)


def error_meaning(interface, status, reply, request_id=None):
    """Decode only evidenced contract errors; never save raw error strings."""
    require(isinstance(reply, dict), "error_envelope_required")
    rpc_code = None
    if interface == "direct":
        require(status in (400, 404) and reply.get("ok") is False
                and "result" not in reply, "direct_error_required")
        message = reply.get("error")
        envelope = "http-error"
    else:
        require(status == 200 and reply.get("jsonrpc") == "2.0"
                and reply.get("id") == request_id, "mcp_error_envelope_required")
        if "error" in reply:
            require("result" not in reply and isinstance(reply["error"], dict), "mcp_error_envelope_required")
            rpc_code = reply["error"].get("code")
            require(type(rpc_code) is int and rpc_code in (-32602, -32000), "unexpected_rpc_error_code")
            message, envelope = reply["error"].get("message"), "jsonrpc-error"
        else:
            result = reply.get("result")
            require(isinstance(result, dict) and result.get("isError") is True, "mcp_tool_error_required")
            content = result.get("content")
            require(isinstance(content, list) and len(content) == 1 and isinstance(content[0], dict)
                    and content[0].get("type") == "text", "mcp_error_text_required")
            message, envelope = content[0].get("text"), "tool-error"
    require(isinstance(message, str), "error_message_required")
    if message in INVALID_MESSAGES:
        meaning, detail = "invalid_arguments", INVALID_MESSAGES[message]
    elif message == "idempotency_conflict":
        meaning, detail = "idempotency_conflict", "same_key_different_request"
    elif interface == "mcp" and message == "hub unreachable: unauthorized":
        # HostAgentChannel rejects unknown memory names before dispatch because
        # MemoryPermissions has no permission for an unregistered operation.
        # This is distinct from unknown_operation and must fail that parity pair.
        meaning, detail = "permission_denied", "scope_rejected_before_dispatch"
    elif message in ("unknown method: " + UNKNOWN,
                     "hub unreachable: Unknown tool: memory::" + UNKNOWN + ". Use tools/list to see available tools."):
        meaning, detail = "unknown_operation", "unknown_operation"
    else:
        raise CheckFailed("unrecognized_error_meaning")
    # Each transport has a specific envelope for these errors in MemoryRouter.
    if interface == "direct":
        require(status == (404 if meaning == "unknown_operation" else 400), "error_http_status_mismatch")
    elif meaning in ("unknown_operation", "permission_denied"):
        require(envelope == "tool-error", "unknown_operation_envelope_mismatch")
    else:
        require(envelope == "jsonrpc-error" and rpc_code == (-32602 if detail == "invalid_argument_shape" else -32000),
                "error_rpc_code_mismatch")
    return {"meaning": meaning, "detail": detail, "envelope": envelope,
            "http_status": status, "rpc_code": rpc_code}


def paired_errors(direct, mcp, meaning, details):
    require(direct["meaning"] == mcp["meaning"] == meaning, "paired_error_meaning_mismatch")
    require((direct["detail"], mcp["detail"]) == details, "paired_error_detail_mismatch")


def error_shape(reply):
    """Fixed envelope metadata for failures whose message is not allowlisted."""
    if not isinstance(reply, dict):
        return {"object": False}
    error, result = reply.get("error"), reply.get("result")
    shape = {"object": True, "has_rpc_error": isinstance(error, dict),
             "has_result": isinstance(result, dict)}
    if isinstance(error, dict):
        shape["rpc_code"] = error.get("code") if type(error.get("code")) is int else None
        message = error.get("message")
    elif isinstance(result, dict):
        shape["tool_error"] = result.get("isError") is True
        content = result.get("content")
        shape["content_count"] = len(content) if isinstance(content, list) else None
        message = content[0].get("text") if isinstance(content, list) and len(content) == 1 and isinstance(content[0], dict) else None
    else:
        shape["direct_error"] = reply.get("ok") is False
        message = error
    shape["message_is_string"] = isinstance(message, str)
    shape["message_length"] = len(message) if isinstance(message, str) else None
    return shape


class Effects(core.Effects):
    owns = staticmethod(lifecycle.owns)


class Runner(core.Runner):
    def __init__(self, fixture, case_id, state_dir=ROOT / ".devenv/memory-local", **options):
        options.setdefault("effects", Effects())
        options.setdefault("output", ROOT / ".devenv/memory-local-evidence" / ("negative-parity50-" + str(time.time_ns()) + ".json"))
        super().__init__(fixture, case_id, **options)
        self.state_dir, self.identities = Path(state_dir).absolute(), None
        self.parity_failures = []
        self.report["evidence_level"] = "online-owned-host-paired-negative-errors"

    def guard(self):
        state = private_json(self.state_dir / "state.json")
        require(state.get("owner") == lifecycle.OWNER and state.get("root") == str(ROOT)
                and state.get("uid") == os.getuid() and state.get("config") == self.config,
                "owned_fixture_state_required")
        require(state.get("urls") == lifecycle.endpoints(), "owned_loopback_urls_required")
        rows = state.get("processes")
        require(isinstance(rows, list) and len(rows) == 2
                and all(isinstance(row, dict) for row in rows)
                and {row.get("name") for row in rows} == {"gateway", "host"}, "owned_stack_required")
        identities = {}
        for row in rows:
            require(not row.get("stopped") and self.fx.owns(row), "owned_running_process_required")
            identities[row["name"]] = {key: row.get(key) for key in ("pid", "pgid", "birth", "uid")}
        require(self.identities in (None, identities), "owned_process_identity_changed")
        self.identities = identities

    def preflight(self):
        super().preflight()
        fixture = private_json(self.fixture)
        primary = fixture["hosts"][0]
        self.partition = primary["partition"]
        config = self.fixture.absolute().parent / "primary/host.yaml"
        require(primary.get("name") == "memory-local-" + self.run_id + "-primary"
                and primary.get("config") == str(config), "fixture_config_binding_required")
        private_json(self.state_dir / "state.json")
        # Check configuration ownership without reading or retaining its token.
        info = config.lstat()
        require(config.resolve(strict=True) == config and stat.S_ISREG(info.st_mode)
                and info.st_uid == os.getuid() and not info.st_mode & 0o077
                and info.st_nlink == 1, "private_fixture_config_required")
        self.config = str(config)
        self.guard()
        self.agent = "memory-local-" + self.run_id + "-negative-parity-" + self.case_id
        self.marker = "MEMORY-LOCAL-" + self.run_id + " NEGATIVE-PARITY-" + self.case_id + ":"
        self.content = self.marker + " Synthetic original: retain bounded OTP workers."
        self.arguments = {"content": self.content, "agent_id": self.agent, "scope": self.scope,
                          "type": "semantic", "idempotency_key": self.agent + ":remember"}
        self.changed_content = self.marker + " Synthetic conflicting request: use unbounded workers."
        self.report.update(marker=self.marker)
        self.record("preflight", fixture_and_process_ownership_verified=True)

    def request(self, *args, **kwargs):
        self.guard()
        return super().request(*args, **kwargs)

    def negative(self, interface, method, arguments):
        self.guard()
        self.sequence += 1
        request_id = self.sequence
        if interface == "direct":
            path, body = f"/memory/{self.agent}/call/{method}", arguments
        else:
            path = f"/memory/{self.agent}/mcp"
            body = {"jsonrpc": "2.0", "id": request_id, "method": "tools/call",
                    "params": {"name": "memory::" + method, "arguments": arguments}}
        try:
            status, reply = self.fx.post(self.host_url, path, body, min(20, self.remaining()))
        except Exception:
            self.record("negative_transport", interface=interface, transport_failed=True)
            raise CheckFailed("negative_http_transport_failed") from None
        self.remaining()
        self.record("negative_http", interface=interface, tool_name="memory::" + method,
                    http_status=status if type(status) is int else None, error_shape=error_shape(reply))
        decoded = error_meaning(interface, status, reply, request_id)
        self.record("negative_error", interface=interface, tool_name="memory::" + method, **decoded)
        return decoded

    def pair(self, name, method, arguments, meaning, details):
        direct = self.negative("direct", method, arguments)
        mcp = self.negative("mcp", method, arguments)
        try:
            paired_errors(direct, mcp, meaning, details)
            parity, failure = True, None
        except CheckFailed as error:
            parity, failure = False, str(error)
            self.parity_failures.append(failure)
        self.record("paired_error", case=name, direct=direct, mcp=mcp, parity=parity,
                    expected_meaning=meaning, failure=failure)

    def owner_ack(self, op, cleanup=False):
        reply = self.request("/memory/diagnostics", {
            "partition": {key: self.partition[key] for key in ("memory_space_id", "scope", "namespace")},
            "command_ids": [self.local_id], "event_ids": [], "mirror_ids": [],
        }, "diagnostics", "targeted", cleanup)
        result = reply.get("result", {})
        require(reply.get("ok") is True and result.get("observation_source") == "owner_connection",
                "owner_diagnostics_required")
        commands = result.get("commands", {})
        outbox, memories = commands.get("outbox"), commands.get("memories")
        require(isinstance(outbox, list) and isinstance(memories, list), "owner_commands_required")
        selected = [row for row in outbox if isinstance(row, dict) and row.get("op") == op
                    and row.get("memory_id") == self.local_id]
        require(len(selected) <= 1, "duplicate_owned_command")
        matching = [row for row in memories if isinstance(row, dict) and row.get("id") == self.local_id]
        require(len(matching) <= 1, "duplicate_owned_memory")
        if not selected or selected[0].get("state") != "done":
            return False
        row = selected[0]
        require(row.get("ack_canonical_id") == self.canonical_id
                and type(row.get("ack_revision")) is int and row["ack_revision"] > 0
                and len(matching) == 1 and matching[0].get("remote_id") == self.canonical_id
                and matching[0].get("deleted") is (op == "forget"), "owner_ack_mismatch")
        self.record("owner_ack", op=op, local_id=self.local_id, canonical_id=self.canonical_id,
                    ack_revision=row["ack_revision"], observation_source="owner_connection")
        return True

    def wait_ack(self, op, cleanup=False):
        while not self.owner_ack(op, cleanup):
            self.pause(cleanup)

    def unchanged(self):
        self.settle()
        self.wait_ack("remember")
        self.record("unchanged_original", canonical_id=self.canonical_id,
                    exact_content_and_identity_preserved=True, both_online_lists_unique=True)

    def cleanup(self):
        self.cleanup_deadline = min(self.started + self.timeout, self.fx.now() + self.cleanup_timeout)
        if self.local_id is None:
            receipt = self.call("mcp", "remember", self.arguments, cleanup=True)
            require(core.valid_uuid(receipt.get("id")), "cleanup_owned_identity_required")
            self.local_id = receipt["id"]
        super().cleanup()
        self.wait_ack("forget", cleanup=True)
        self.report["cleanup"]["owner_forget_ack"] = True

    def scenario(self):
        tools = self.mcp("tools/list", {}).get("tools")
        require(isinstance(tools, list) and all(isinstance(tool, dict) for tool in tools)
                and "memory::" + UNKNOWN not in {tool.get("name") for tool in tools}, "unknown_probe_must_be_undiscovered")
        self.baseline = self.inventory("direct")
        require(self.baseline == self.inventory("mcp"), "baseline_list_parity_mismatch")
        for interface in ("direct", "mcp"):
            _, rows = self.listing(interface, {"q": self.marker})
            require(not rows, "fresh_case_required")
        self.write_attempted = True
        receipt = self.call("direct", "remember", self.arguments)
        require(core.valid_uuid(receipt.get("id")), "remember_identity_required")
        self.local_id = receipt["id"]
        self.unchanged()
        invalid = (
            ("nonobject_arguments", [], ("content_required", "invalid_argument_shape")),
            ("content_type", {**self.arguments, "content": 42}, ("content_required", "content_required")),
            ("unsupported_type", {**self.arguments, "type": "negative_parity_invalid"}, ("unsupported_type", "unsupported_type")),
            ("facets_shape", {**self.arguments, "facets": {}}, ("invalid_facets", "invalid_facets")),
            ("facets_item_type", {**self.arguments, "facets": [{"dimension": "project", "value": 42}]}, ("invalid_facets", "invalid_facets")),
            ("idempotency_key_type", {**self.arguments, "idempotency_key": 42}, ("invalid_idempotency_key", "invalid_idempotency_key")),
        )
        for name, arguments, details in invalid:
            self.pair(name, "remember", arguments, "invalid_arguments", details)
        self.pair("unknown_operation", UNKNOWN, {}, "unknown_operation", ("unknown_operation", "unknown_operation"))
        self.pair("same_key_different_content", "remember", {**self.arguments, "content": self.changed_content},
                  "idempotency_conflict", ("same_key_different_request", "same_key_different_request"))
        self.unchanged()
        repeated = self.call("mcp", "remember", self.arguments)
        require(repeated.get("id") == self.local_id and repeated.get("canonical_id") == self.canonical_id
                and repeated.get("sync_state") == "synced" and repeated.get("authority") == "canonical"
                and repeated.get("consistency") == "canonical", "original_exact_retry_not_canonical")
        self.report["paired_negative_cases_checked"] = len(invalid) + 2
        self.report["paired_negative_cases_passed"] = len(invalid) + 2 - len(self.parity_failures)
        require(not self.parity_failures, "paired_negative_parity_failed")

    def save(self):
        self.report["elapsed_seconds"] = round(self.fx.now() - self.started, 3)
        self.report["recorded_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        require(self.output.parent.resolve(strict=True) == self.output.parent.absolute()
                and self.output.parent.stat().st_uid == os.getuid(), "owned_report_directory_required")
        with os.fdopen(os.open(self.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "w") as stream:
            json.dump(self.report, stream, indent=2)
            stream.write("\n")

    def run(self):
        try:
            self.preflight()
            self.scenario()
            self.report["status"] = "passed-negative-parity-subset"
        except (Exception, KeyboardInterrupt) as error:
            self.report["error"] = str(error) if isinstance(error, CheckFailed) else "negative_parity_probe_failed"
        finally:
            if self.write_attempted:
                try:
                    self.cleanup()
                except (Exception, KeyboardInterrupt) as error:
                    self.report["status"] = "failed"
                    self.report["cleanup"] = {"status": "failed", "error": str(error) if isinstance(error, CheckFailed)
                                              else "cleanup_failed", "retained_marker_requires_inspection": True}
            self.save()
        return self.report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, default=ROOT / ".devenv/memory-local-fixtures/oct20-a/fixture.json")
    parser.add_argument("--case-id", required=True)
    parser.add_argument("--state-dir", type=Path, default=ROOT / ".devenv/memory-local")
    parser.add_argument("--host-url", default="http://127.0.0.1:4222")
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--cleanup-timeout", type=float, default=40)
    parser.add_argument("--output", type=Path)
    args = vars(parser.parse_args())
    if args["output"] is None:
        del args["output"]
    runner = Runner(**args)
    try:
        report = runner.run()
    except Exception:
        print("negative_parity_report_write_failed")
        return 2
    print(runner.output)
    return 0 if report["status"] == "passed-negative-parity-subset" else 1


if __name__ == "__main__":
    raise SystemExit(main())
