#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["playwright==1.56.0"]
# ///
"""Bounded local shared-Memory fault runner, requiring a prepared owned relay topology.

Importing this module performs no service, browser, relay or database operations.
Explicit invocation uses real Admin controls, direct/MCP APIs and the supported host
lifecycle harness. Unit results never qualify live L13/L18. The parent prepares the
relay/configuration and supplies a successful online-matrix report before execution.
"""

import argparse
import datetime
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.parse
import uuid


def _sibling(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


online = _sibling("memory_local_shared_access")
relay = _sibling("memory_local_transport_relay")
pending = _sibling("memory_local_pending_restart")
lifecycle = _sibling("memory_local_dev")
inventory = _sibling("memory_local_canonical_inventory")
CheckFailed, require = online.CheckFailed, online.require

CAPABILITIES = {"read", "deliver", "remember", "forget"}
COMMAND_STATES = {"pending", "retry_wait", "inflight", "done", "dead_letter"}
COMMAND_FIELDS = {"command_id", "authority_version", "state", "ack_canonical_id", "ack_revision", "has_error"}


def _uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except ValueError:
        return False


def _ids(values):
    return (isinstance(values, list) and len(values) <= 32
            and all(_uuid(value) for value in values) and len(set(values)) == len(values))


def _command_row(row):
    require(isinstance(row, dict) and set(row) == COMMAND_FIELDS, "content_free_command_required")
    require(_uuid(row["command_id"]) and type(row["authority_version"]) is int
            and row["authority_version"] > 0 and isinstance(row["state"], str) and row["state"] in COMMAND_STATES
            and type(row["has_error"]) is int and row["has_error"] in (0, 1), "command_metadata_required")
    if row["state"] == "done":
        require(_uuid(row["ack_canonical_id"]) and type(row["ack_revision"]) is int
                and row["ack_revision"] > 0 and row["has_error"] == 0, "committed_command_required")
    else:
        require(row["ack_canonical_id"] is None and row["ack_revision"] is None,
                "uncommitted_command_required")
        if row["state"] == "dead_letter":
            require(row["has_error"] == 1, "rejected_command_required")


def owner_diagnostic(reply, policy, command_ids, mirror_ids, mirror_status):
    """Validate a targeted content-free owner snapshot, including current mirror IDs."""
    require(isinstance(reply, dict) and set(reply) == {"observation_source", "access", "commands", "mirror"}
            and reply["observation_source"] == "authority_owner", "authority_owner_snapshot_required")
    require(_ids(command_ids) and _ids(mirror_ids) and len(command_ids) + len(mirror_ids) <= 32,
            "bounded_diagnostic_ids_required")
    require(isinstance(policy, dict) and {"access_id", "version", "capabilities", "lease"} <= set(policy),
            "diagnostic_policy_required")
    caps, lease = policy["capabilities"], policy["lease"]
    require(_uuid(policy["access_id"]) and type(policy["version"]) is int and policy["version"] > 0
            and isinstance(caps, list) and all(isinstance(cap, str) for cap in caps)
            and len(set(caps)) == len(caps) and set(caps) <= CAPABILITIES
            and ("deliver" not in caps or "read" in caps)
            and type(lease) is int and 0 <= lease <= 300
            and (lease == 0 or {"read", "deliver"} <= set(caps)), "diagnostic_policy_required")
    access = reply["access"]
    require(isinstance(access, dict) and set(access) == {
        "access_id", "authority_version", "capabilities", "status", "fence_reason",
        "offline_read_lease_seconds", "lease_remaining_ms"}, "content_free_access_required")
    require(access["access_id"] == policy["access_id"]
            and type(access["authority_version"]) is int and access["authority_version"] == policy["version"]
            and isinstance(access["capabilities"], list)
            and all(isinstance(cap, str) for cap in access["capabilities"])
            and sorted(access["capabilities"]) == sorted(caps)
            and type(access["offline_read_lease_seconds"]) is int
            and access["offline_read_lease_seconds"] == lease
            and type(access["lease_remaining_ms"]) is int and 0 <= access["lease_remaining_ms"] <= lease * 1000,
            "current_owner_authority_required")
    require(access["fence_reason"] in (None, "not_negotiated", "unauthorized", "authority_changed",
            "connection_rejected", "credential_policy", "invalid_protocol", "protocol_mismatch", "partition_mismatch"),
            "content_free_fence_required")
    commands = reply["commands"]
    require(isinstance(commands, dict) and set(commands) == {"counts", "rows"}
            and isinstance(commands["counts"], dict) and set(commands["counts"]) <= COMMAND_STATES
            and all(type(count) is int and count >= 0 for count in commands["counts"].values())
            and isinstance(commands["rows"], list) and len(commands["rows"]) <= len(command_ids),
            "bounded_command_diagnostics_required")
    for row in commands["rows"]:
        _command_row(row)
    require(len({row["command_id"] for row in commands["rows"]}) == len(commands["rows"])
            and all(row["command_id"] in command_ids for row in commands["rows"]),
            "requested_commands_only")
    mirror = reply["mirror"]
    require(mirror_status in ("complete", "incomplete", "closed") and isinstance(mirror, dict)
            and mirror.get("status") == mirror_status, "expected_mirror_status_required")
    if mirror_status == "complete":
        require(access["status"] == "active" and access["fence_reason"] is None
                and {"read", "deliver"} <= set(caps) and mirror_ids
                and set(mirror) == {"status", "partition", "active_target_ids"}, "readable_mirror_required")
        partition = mirror["partition"]
        require(isinstance(partition, dict) and set(partition) == {
            "applied_revision", "active_generation", "snapshot_id", "snapshot_revision", "sync_status"}
            and type(partition["applied_revision"]) is int and partition["applied_revision"] >= 0
            and _uuid(partition["active_generation"]) and partition["snapshot_id"] is None
            and partition["snapshot_revision"] is None and partition["sync_status"] == "ready",
            "current_complete_generation_required")
        require(_ids(mirror["active_target_ids"]) and set(mirror["active_target_ids"]) == set(mirror_ids),
                "populated_requested_mirror_required")
    else:
        require(set(mirror) == {"status"}, "hidden_mirror_required")
        require(access["status"] == "closed" if mirror_status == "closed"
                else access["status"] in ("active", "needs_sync"), "owner_status_mismatch")
        if mirror_status == "closed":
            require(access["lease_remaining_ms"] == 0, "closed_lease_required")
    return reply


def lease_observation(started, finished, authority_sent, lease, result, canonical_id):
    """Bound an entire offline read by the authority request's monotonic send time."""
    require(all(type(value) in (int, float) and math.isfinite(value)
                for value in (started, finished, authority_sent))
            and type(lease) is int and 0 < lease <= 300
            and authority_sent <= started <= finished < authority_sent + lease,
            "offline_lease_window_required")
    require(isinstance(result, dict) and result.get("mode") == "offline" and result.get("stale") is True
            and result.get("source") == "edge_mirror" and result.get("authority") == "canonical"
            and result.get("consistency") == "bounded_stale", "bounded_stale_mirror_required")
    observation = recall_observation(result)
    require(_uuid(canonical_id) and observation["valid_ids"]
            and canonical_id in observation["ids"], "offline_canonical_identity_required")
    return result


def denial_message(interface, status, reply, marker, request_id=None):
    """Extract a strictly shaped denial without classifying its authority meaning."""
    require(isinstance(marker, str) and bool(marker), "protected_marker_required")
    if interface == "direct":
        require(isinstance(reply, dict) and set(reply) == {"ok", "error"}
                and reply.get("ok") is False and status in (400, 401, 403, 503), "direct_denial_required")
        message = reply["error"]
    else:
        require(interface == "mcp" and status == 200 and isinstance(reply, dict)
                and reply.get("jsonrpc") == "2.0" and type(reply.get("id")) is type(request_id)
                and reply.get("id") == request_id, "rpc_identity_mismatch")
        if "error" in reply:
            error = reply["error"]
            require(set(reply) == {"jsonrpc", "id", "error"} and isinstance(error, dict)
                    and set(error) == {"code", "message"} and error["code"] == -32000,
                    "rpc_denial_required")
            message = error["message"]
        else:
            result = online.rpc_result(reply, request_id)
            require(set(reply) == {"jsonrpc", "id", "result"} and set(result) == {"isError", "content"}
                    and result["isError"] is True, "tool_denial_required")
            message = online.tool_text(result)
            require(set(result["content"][0]) == {"type", "text"}, "content_free_denial_required")
    require(marker not in str(reply), "denial_disclosed_content")
    require(isinstance(message, str), "denial_text_required")
    return message


def offline_denial(interface, status, reply, marker, request_id=None, *, cold=False, owner_closed=False):
    """Accept expiry, or cold transport unavailability paired with positive owner closure."""
    message = denial_message(interface, status, reply, marker, request_id)
    if interface == "direct" and status == 503 and cold is True and owner_closed is True:
        require(message == "canonical memory is unavailable", "cold_transport_denial_required")
        return "transport_unavailable_with_owner_closed"
    require(status != 503, "offline_denial_required")
    require(message in ("access_lease_expired", "hub unreachable: access_lease_expired"),
            "lease_expiry_denial_required")
    return "access_lease_expired"


def command_outcome(diagnostic, command_id, version, state):
    require(_uuid(command_id) and type(version) is int and version > 0
            and isinstance(state, str) and state in COMMAND_STATES,
            "command_expectation_required")
    require(isinstance(diagnostic, dict) and isinstance(diagnostic.get("commands"), dict)
            and isinstance(diagnostic["commands"].get("rows"), list)
            and len(diagnostic["commands"]["rows"]) <= 32, "command_diagnostics_required")
    rows = diagnostic["commands"]["rows"]
    for row in rows:
        _command_row(row)
    matches = [row for row in rows if row["command_id"] == command_id]
    require(len(matches) == 1 and matches[0]["authority_version"] == version and matches[0]["state"] == state,
            "exact_command_outcome_required")
    return matches[0]


def control_state(reply, mode):
    require(mode in ("online", "offline") and isinstance(reply, dict)
            and set(reply) == {"mode", "connections", "listen_port", "upstream_port"}
            and reply["mode"] == mode and type(reply["connections"]) is int
            and 0 <= reply["connections"] <= 128
            and type(reply["listen_port"]) is int and reply["listen_port"] == 4224
            and type(reply["upstream_port"]) is int and reply["upstream_port"] == 4220
            and (mode != "offline" or reply["connections"] == 0), "owned_relay_state_required")
    return reply


def relay_request_sync(path, action):
    """Run the existing relay CLI outside Playwright's running event loop."""
    require(action in ("status", "online", "offline"), "relay_mode_required")
    path = relay.control_parent(path)
    try:
        process = subprocess.run([sys.executable, str(Path(relay.__file__).resolve()),
            action, "--control", str(path)], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise CheckFailed("relay_control_cli_failed") from None
    require(process.returncode == 0, "relay_control_cli_failed")
    require(isinstance(process.stdout, str) and len(process.stdout) <= 1024,
            "relay_control_response_invalid")
    try:
        result = json.loads(process.stdout)
    except ValueError:
        raise CheckFailed("relay_control_response_invalid") from None
    require(isinstance(result, dict), "relay_control_response_invalid")
    return result


def cleanup_plan(rows, created_ids, owned_contents):
    """Select only recorded canonical IDs still carrying exact owned fixture content."""
    require(isinstance(rows, list) and len(rows) <= 10000
            and all(isinstance(row, dict) and isinstance(row.get("id"), str)
                    and isinstance(row.get("content"), str) for row in rows), "cleanup_rows_required")
    require(len({row["id"] for row in rows}) == len(rows), "unique_cleanup_ids_required")
    selected = [row for row in rows if row["id"] in created_ids]
    require(all(row["content"] in owned_contents for row in selected), "cleanup_record_ownership_lost")
    return [row["id"] for row in selected]


def _memory_row_id(row):
    if not isinstance(row, dict):
        return None
    identities = [row[key] for key in ("id", "canonical_id") if key in row]
    if not identities or not all(_uuid(value) for value in identities) or len(set(identities)) != 1:
        return None
    return identities[0]


def list_observation(result):
    """Retain bounded metadata even when a list fails its acceptance assertions."""
    enums = {"mode": {"online", "offline"},
             "authority": {"canonical", "canonical_with_provisional", "provisional"},
             "source": {"canonical", "edge_mirror", "acknowledged_commands", "provisional_commands"},
             "consistency": {"canonical", "read_your_writes", "bounded_stale", "provisional_only"}}
    observation = {key: result.get(key) if isinstance(result.get(key), str)
                   and result[key] in allowed else None for key, allowed in enums.items()}
    observation["invalid_fields"] = [key for key in enums if key in result and observation[key] is None]
    for key in ("stale", "pending_operations"):
        value = result.get(key)
        valid = type(value) is bool if key == "stale" else type(value) is int and 0 <= value <= 1_000_000
        observation[key] = value if valid else None
        if not valid:
            observation["invalid_fields"].append(key)
    rows = result.get("items", result.get("results"))
    valid_rows = (isinstance(rows, list) and len(rows) < 100
                  and all(_memory_row_id(row) is not None for row in rows))
    ids = [_memory_row_id(row) for row in rows] if valid_rows else []
    observation.update(row_count=len(rows) if isinstance(rows, list) and len(rows) < 100 else None,
                       ids=ids, valid_ids=valid_rows and len(ids) == len(set(ids)))
    if "items" in result and "results" in result:
        other = result["results"]
        observation["valid_ids"] = observation["valid_ids"] and (
            isinstance(other, list) and len(other) < 100
            and all(_memory_row_id(row) is not None for row in other)
            and [_memory_row_id(row) for row in other] == ids)
    return observation


def recall_observation(result):
    """Normalize recall identity aliases without retaining content or ambiguous IDs."""
    observation = list_observation(result)
    arrays = [result[key] for key in ("hits", "results", "items") if key in result]
    rows = arrays[0] if arrays else None
    valid_rows = (isinstance(rows, list) and len(rows) <= 100
                  and all(_memory_row_id(row) is not None for row in rows))
    ids = [_memory_row_id(row) for row in rows] if valid_rows else []
    valid_ids = valid_rows and len(ids) == len(set(ids))
    for other in arrays[1:]:
        valid_ids = valid_ids and (isinstance(other, list) and len(other) <= 100
            and all(_memory_row_id(row) is not None for row in other)
            and [_memory_row_id(row) for row in other] == ids)
    observation.update(row_count=len(rows) if isinstance(rows, list) and len(rows) <= 100 else None,
                       ids=ids, valid_ids=valid_ids)
    return observation


def private_mirror_observation(reply, canonical_id):
    """Validate the existing private owner diagnostics, excluding unrequested data."""
    require(isinstance(reply, dict) and set(reply) == {
        "observation_source", "commands", "capture", "mirror", "tombstones"}
        and reply["observation_source"] == "owner_connection"
        and reply["commands"] == {"outbox": [], "memories": []}
        and reply["capture"] == {"rows": [], "expected": 0, "missing_or_compacted": 0},
        "private_owner_diagnostics_required")
    mirror = reply["mirror"]
    require(isinstance(mirror, dict) and set(mirror) == {"partition", "active_target_ids"}
            and _ids(mirror["active_target_ids"])
            and set(mirror["active_target_ids"]) <= {canonical_id}, "private_mirror_identity_required")
    partition = mirror["partition"]
    if partition is not None:
        require(isinstance(partition, dict) and set(partition) == {
            "applied_revision", "active_generation", "snapshot_id", "snapshot_revision", "sync_status"}
            and type(partition["applied_revision"]) is int and partition["applied_revision"] >= 0
            and (partition["active_generation"] == "0" or _uuid(partition["active_generation"]))
            and (partition["snapshot_id"] is None or _uuid(partition["snapshot_id"]))
            and (partition["snapshot_revision"] is None or
                 type(partition["snapshot_revision"]) is int and partition["snapshot_revision"] >= 0)
            and partition["sync_status"] in (None, "ready", "snapshot_required"),
            "private_mirror_generation_required")
    else:
        require(not mirror["active_target_ids"], "private_mirror_generation_required")
    return {"observation_source": "owner_connection", "mirror": mirror}


class OfflineMatrix(online.OnlineMatrix):
    """Additional fault subset; intentionally never reports full L13 or L18."""

    def __init__(self, args=None):
        self.control_armed = False
        if args is None:
            return  # Pure adapter tests construct only the foundation.
        super().__init__(args.fixture, args.case_id, args.output, args.timeout)
        self.args = args
        self.owned_private, self.owned_private_contents, self.queued = {}, set(), []
        self.files, self.expected_states = {}, {}
        self.host_restart_attempted = False
        self.scenario_started = False
        self.report["fault_active"] = False
        self.report.update(evidence_level="local-shared-offline-subset", checks={}, owner_observations=[],
            evidence_artifacts="report-only; no screenshots captured by this runner",
            limits="No credential replacement, delayed-packet/race/crash qualification, complete source-provenance proof or retained second L18 workflow.")
        self.report_fd = os.open(self.output / "report.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)

    def save_report(self):
        raw = (json.dumps(self.report, indent=2) + "\n").encode()
        os.lseek(self.report_fd, 0, os.SEEK_SET)
        os.ftruncate(self.report_fd, 0)
        with os.fdopen(os.dup(self.report_fd), "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())

    def checked(self, phase, **metadata):
        self.report["checks"][phase] = metadata or True
        self.save_report()

    def remaining(self):
        require(time.monotonic() < self.deadline, "driver_deadline")
        return self.deadline - time.monotonic()

    def poll(self, operation, code, seconds=30):
        deadline = min(self.deadline, time.monotonic() + seconds)
        while time.monotonic() < deadline:
            result = operation()
            if result is not None:
                return result
            time.sleep(0.2)
        raise CheckFailed(code)

    def preflight(self):
        """Validate prepared identities; do not edit configuration or start/adopt a relay."""
        require(type(self.args.lease) is int and 5 <= self.args.lease <= 15, "short_lease_required")
        root = online.ROOT / ".devenv/memory-local-fixtures"
        fixture_path = Path(self.args.fixture).absolute()
        require(root in fixture_path.parents, "local_fixture_required")
        require(json.loads(pending.private_read(fixture_path)) == self.fixture, "fixture_changed")
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=online.ROOT, text=True).strip()
        qualified = json.loads(pending.private_read(self.args.online_report))
        require(qualified.get("status") == "passed-subset" and qualified.get("run_id") == self.run_id
                and qualified.get("revision") == revision and qualified.get("cleanup", {}).get("status") == "passed",
                "passing_current_online_matrix_required")
        stores = []
        for index, host in enumerate(self.hosts):
            config = Path(host["config"]).absolute()
            raw = pending.private_read(config)
            values = pending.scalars(raw)
            expected = {("agent", "host_id"): host["host_id"], ("agent", "http_bind"): "127.0.0.1",
                ("agent", "http_port"): str(4222 + index), ("memory", "enabled"): "true",
                ("memory", "bound_scope"): host["partition"]["scope"],
                ("memory", "host_sync_v2", "enabled"): "true", ("capture", "enabled"): "true"}
            require(all(values.get(key) == value for key, value in expected.items()), "fixture_configuration_mismatch")
            hub = urllib.parse.urlsplit(values.get(("agent", "hub_url"), ""))
            require(hub.scheme == "http" and hub.hostname in ("127.0.0.1", "localhost")
                    and hub.port == (4220 if index == 0 else 4224) and not hub.username and not hub.password
                    and hub.path in ("", "/") and not hub.query and not hub.fragment, "prepared_relay_only_b_required")
            paths = [config] + [Path(values.get(key, "")) for key in (
                ("memory", "db_path"), ("capture", "db_path"), ("memory", "host_sync_v2", "db_path"))]
            for path in paths:
                require(path.is_absolute() and fixture_path.parent in path.parents, "fixture_store_path_required")
                info = pending.private_file(path)
                self.files[path] = (info.st_dev, info.st_ino)
            stores.extend(paths[1:])
            self.files[config] += (hashlib.sha256(raw).hexdigest(),)
        require(len(stores) == 6 and len({self.files[path][:2] for path in stores}) == 6,
                "six_distinct_host_stores_required")
        require(len(self.files) == 8 and len({value[:2] for value in self.files.values()}) == 8,
                "distinct_configuration_and_store_files_required")
        require(Path(self.args.primary_state).resolve() != Path(self.args.secondary_state).resolve(),
                "distinct_owned_states_required")
        for state_dir in (self.args.primary_state, self.args.secondary_state):
            state = lifecycle.read_state(Path(state_dir).resolve())
            self.expected_states[Path(state_dir).resolve()] = state
        self.check_topology()
        path = relay.control_parent(Path(self.args.control).absolute())
        identity = relay.socket_identity(path)
        state = relay_request_sync(path, "status")
        require(state.get("connections", 0) > 0, "connected_prepared_relay_required")
        self.arm_control(path, identity, relay.socket_identity(path), state)
        claim = fixture_path.parent / ("shared-offline-case-" + self.args.case_id + ".json")
        fd = os.open(claim, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump({"case_id": self.args.case_id, "run_id": self.run_id}, stream)
        self.baseline = inventory.snapshot(self.fixture, self.args.socket)
        self.report["revision"] = revision
        self.checked("preflight", owned_topology=True, online_gate=True, canonical_rows=len(self.baseline))

    def check_topology(self, require_ready=True):
        if not require_ready:
            return self.check_topology_identity()

        def ready():
            self.check_topology_identity()
            observation = {}
            for index, state_dir in enumerate(self.expected_states):
                result = lifecycle.status(state_dir)
                flags = result.get("http_ready")
                fields = ("public", "admin", "host") if index == 0 else ("host",)
                observation["primary" if index == 0 else "secondary"] = {
                    field: flags.get(field) if isinstance(flags, dict) and type(flags.get(field)) is bool else None
                    for field in fields}
                if not (isinstance(flags, dict) and set(flags) == set(fields)
                        and all(type(value) is bool for value in flags.values())):
                    self.record_probe("topology_readiness_observations", observation)
                    raise CheckFailed("owned_stack_readiness_invalid")
            all_ready = bool(observation) and all(all(flags.values()) for flags in observation.values())
            if not all_ready:
                self.report["last_topology_not_ready"] = observation
            self.record_probe("topology_readiness_observations", observation)
            self.check_topology_identity()
            return True if all_ready else None

        self.poll(ready, "owned_stack_not_ready")

    def check_topology_identity(self):
        for path, expected in self.files.items():
            info = pending.private_file(path)
            require((info.st_dev, info.st_ino) == expected[:2], "fixture_file_identity_changed")
            if len(expected) == 3:
                require(hashlib.sha256(pending.private_read(path)).hexdigest() == expected[2], "fixture_config_changed")
        for index, (state_dir, expected) in enumerate(self.expected_states.items()):
            current = lifecycle.read_state(state_dir)
            require(current["run_id"] == expected["run_id"] and current["processes"] == expected["processes"]
                    and Path(current["config"]).resolve() == Path(self.hosts[index]["config"]).resolve(),
                    "owned_stack_identity_changed")
            expected_names = {"host", "gateway"} if index == 0 else {"host"}
            require({record["name"] for record in current["processes"]} == expected_names
                    and all(lifecycle.owns(record) for record in current["processes"]), "owned_stack_required")
            urls = lifecycle.endpoints(4222 + index)
            if index == 1:
                urls = {"host": urls["host"]}
            require(current["urls"] == urls, "owned_stack_urls_mismatch")

    def restart_host(self):
        self.check_topology()
        self.host_restart_attempted = True
        state_dir = Path(self.args.secondary_state).resolve()
        lifecycle.service(state_dir, "host", "restart", min(120, self.remaining()))
        current = lifecycle.read_state(state_dir)
        previous = self.expected_states[state_dir]
        require(current["run_id"] == previous["run_id"] and current["config"] == previous["config"],
                "restarted_host_identity_changed")
        self.expected_states[state_dir] = current
        self.check_topology()

    def restore_host(self):
        # This runner never changes config bytes or switches configurations. A
        # failed supported restart is left for parent diagnosis, never adopted.
        self.check_topology()
        def connected():
            self.check_topology()
            status, body = self.b.post("/memory/" + self.agent + "/call/list",
                                       {"q": self.marker + ":", "limit": 100})
            if status == 503:
                require(body == {"ok": False, "error": "canonical memory is unavailable"},
                        "restored_host_permanent_or_malformed_failure")
                return None
            result = online.decode_reply("direct", status, body)
            observation = list_observation(result)
            self.record_probe("restore_observations", observation)
            require(not observation["invalid_fields"] and observation["valid_ids"]
                    and observation["mode"] in ("online", "offline")
                    and observation["authority"] in ("canonical", "canonical_with_provisional", "provisional")
                    and observation["consistency"] is not None
                    and observation["stale"] is (observation["mode"] == "offline"),
                    "restored_host_list_malformed")
            if observation["mode"] == "offline":
                require(observation["source"] in ("edge_mirror", "acknowledged_commands", "provisional_commands")
                        and observation["consistency"] in ("bounded_stale", "provisional_only"),
                        "restored_host_list_malformed")
                return None
            pending_count = observation["pending_operations"]
            require(observation["authority"] == ("canonical_with_provisional" if pending_count else "canonical")
                    and observation["consistency"] == ("read_your_writes" if pending_count else "canonical"),
                    "restored_host_list_malformed")
            return True if pending_count == 0 else None
        self.poll(connected, "restored_host_not_connected", 60)

    def record_probe(self, name, observation):
        observations = self.report.setdefault(name, [])
        observations.append(observation)
        del observations[:-8]
        self.save_report()

    def wait_private_mirror(self):
        partition = {key: self.hosts[1]["partition"][key]
                     for key in ("memory_space_id", "scope", "namespace")}
        require(_uuid(self.private_sentinel), "private_sentinel_identity_required")
        def populated():
            self.check_topology()
            http, body = self.b.post("/memory/diagnostics", {"partition": partition,
                "command_ids": [], "event_ids": [], "mirror_ids": [self.private_sentinel]})
            result = online.decode_reply("direct", http, body)
            observation = private_mirror_observation(result, self.private_sentinel)
            self.record_probe("private_mirror_observations", observation)
            mirror = observation["mirror"]
            state = mirror["partition"]
            if (state is not None and state["sync_status"] == "ready"
                    and state["snapshot_id"] is None and state["snapshot_revision"] is None
                    and mirror["active_target_ids"] == [self.private_sentinel]):
                return observation
            return None
        return self.poll(populated, "private_sentinel_mirror_not_ready")

    def policy(self, capabilities, phase, lease=0, observe=True):
        if self.access is not None:
            require(self.admin.current() == self.access, "operator_changed_test_grant")
        self.mutation_attempted = True
        self.access = self.admin.save(capabilities, self.marker + ":" + phase, lease=lease,
                                     creating=self.access is None, expected=self.access)
        self.report["policies"].append({"phase": phase, **self.access})
        if observe:
            self.wait_owner("complete" if "deliver" in capabilities else "incomplete")

    def revoke(self, phase):
        require(self.admin.current() == self.access, "operator_changed_test_grant")
        self.access = self.admin.revoke(self.marker + ":" + phase, expected=self.access)
        self.report["policies"].append({"phase": phase, **self.access})

    def diagnostic(self, policy, status):
        command_ids = [item["command_id"] for item in self.queued]
        http, body = self.b.post("/memory/diagnostics", {"memory_access_id": policy["access_id"],
            "command_ids": command_ids, "mirror_ids": [self.sentinel]})
        require(http == 200, "owner_diagnostics_unavailable")
        result = online.decode_reply("direct", http, body)
        result = owner_diagnostic(result, policy, command_ids, [self.sentinel], status)
        self.record_owner(result)
        return result

    def record_owner(self, diagnostic):
        observations = self.report.setdefault("owner_observations", [])
        require(len(observations) < 16, "owner_observation_limit")
        observations.append(diagnostic)

    def wait_owner(self, status, policy=None, rejected=False):
        policy = self.access if policy is None else policy
        def observe():
            http, body = self.b.post("/memory/diagnostics", {"memory_access_id": policy["access_id"],
                "command_ids": [item["command_id"] for item in self.queued], "mirror_ids": [self.sentinel]})
            require(http == 200, "owner_diagnostics_unavailable")
            reply = online.decode_reply("direct", http, body)
            access = reply.get("access", {})
            require(access.get("access_id") == policy["access_id"]
                    and type(access.get("authority_version")) is int, "owner_identity_mismatch")
            if access["authority_version"] < policy["version"]:
                return None
            actual_status = reply.get("mirror", {}).get("status")
            owner_diagnostic(reply, policy, [item["command_id"] for item in self.queued], [self.sentinel], actual_status)
            if actual_status != status:
                return None
            if rejected:
                for item in self.queued:
                    rows = [row for row in reply["commands"]["rows"] if row["command_id"] == item["command_id"]]
                    if not rows or rows[0]["state"] in ("pending", "retry_wait", "inflight"):
                        return None
                    command_outcome(reply, item["command_id"], item["version"], "dead_letter")
            self.record_owner(reply)
            return reply
        return self.poll(observe, "current_owner_mirror_or_rejection_not_observed")

    def read(self, interface, selected=True):
        arguments = {"query": self.marker + ":sentinel", "limit": 100}
        if selected:
            arguments = self.selected(arguments)
        sent = time.monotonic()
        result = self.b.call(interface, "recall", arguments)
        received = time.monotonic()
        observation = recall_observation(result)
        self.record_probe("recall_observations", {"interface": interface, **observation})
        require(observation["valid_ids"] and self.sentinel in observation["ids"],
                "shared_recall_identity_required")
        return sent, received, result

    def deny_read(self, interface, code, *, cold=False):
        status, reply, request_id = self.b.raw(interface, "recall", self.selected({
            "query": self.marker + ":sentinel", "limit": 100}))
        if code == "access_lease_expired":
            return offline_denial(interface, status, reply, self.marker, request_id)
        message = denial_message(interface, status, reply, self.marker, request_id)
        if cold and message in ("unauthorized", "hub unreachable: unauthorized"):
            return "owner_closed_unauthorized"
        if cold:
            return offline_denial(interface, status, reply, self.marker, request_id, cold=True, owner_closed=True)
        require(message in (code, "hub unreachable: " + code) and status != 503, "expected_read_closure_required")
        return code

    def seed(self):
        require(not self.own_rows(), "fresh_case_required")
        content = self.marker + ":sentinel"
        self.owned_contents.add(content)
        self.a.call("direct", "remember", {"content": content, "type": "semantic", "idempotency_key": content})
        self.sentinel = self.wait_rows(content, True)[0]["id"]
        private = self.marker + ":private"
        before = self.b.call("direct", "list", {"q": private, "limit": 100})
        require(not online.listed(before), "fresh_private_case_required")
        self.owned_private_contents.add(private)
        self.b.call("direct", "remember", {"content": private, "type": "semantic", "idempotency_key": private})
        def private_row():
            result = self.b.call("direct", "list", {"q": private, "limit": 100})
            rows = [row for row in online.listed(result) if row.get("content") == private]
            if result.get("pending_operations") == 0 and len(rows) == 1:
                self.owned_private[rows[0]["id"]] = private
                return rows[0]["id"]
            return None
        self.private_sentinel = self.poll(private_row, "private_sentinel_not_settled")
        self.wait_private_mirror()
        self.checked("seed", canonical_id=self.sentinel, private_canonical_id=self.private_sentinel)
        self.a.discover()
        self.b.discover()

    def private_fallback(self):
        failures = []
        for interface in ("direct", "mcp"):
            status, reply, request_id = self.b.raw(interface, "list", {"q": self.marker + ":private", "limit": 100})
            observation = {"interface": interface, "http_status": status, "request_id": request_id,
                "rpc_identity_matches": None if interface == "direct" else (
                    isinstance(reply, dict) and type(reply.get("id")) is type(request_id)
                    and reply.get("id") == request_id)}
            try:
                require(interface != "mcp" or observation["rpc_identity_matches"] is True,
                        "rpc_identity_mismatch")
                result = online.decode_reply(interface, status, reply, request_id)
            except CheckFailed as error:
                observation["decode_failure"] = self.failure_code(error)
                failures.append(error)
            else:
                observation.update(list_observation(result))
                if not (not observation["invalid_fields"] and observation["valid_ids"]
                        and observation["mode"] == "offline" and observation["stale"] is True
                        and observation["authority"] == "canonical" and observation["source"] == "edge_mirror"
                        and observation["consistency"] == "bounded_stale" and observation["pending_operations"] == 0
                        and observation["ids"] == [self.private_sentinel]):
                    failures.append(CheckFailed("private_omitted_selector_fallback_required"))
            self.record_probe("private_fallback_observations", observation)
        if failures:
            raise failures[0]

    def queue_pair(self, phase):
        content = self.marker + ":" + phase
        self.owned_contents.add(content)
        arguments = {"remember": {"content": content, "type": "semantic", "idempotency_key": content + ":remember"},
                     "forget": {"id": self.sentinel, "idempotency_key": content + ":forget"}}
        pair = []
        for interface, operation in (("direct", "remember"), ("mcp", "forget")):
            receipt = online.shared_receipt(self.b.call(interface, operation, self.selected(arguments[operation])))
            require(receipt["status"] == "pending", "offline_pending_receipt_required")
            item = {"command_id": receipt["command_id"], "version": self.access["version"], "op": operation}
            require(item["command_id"] not in {row["command_id"] for row in self.queued}, "unique_command_required")
            self.queued.append(item)
            pair.append(item)
        self.checked(phase, commands=pair)

    def canonical_unchanged(self):
        rows = self.own_rows()
        require([row["id"] for row in rows] == [self.sentinel], "rejected_commands_changed_canonical_data")

    def run_matrix(self):
        self.scenario_started = True
        self.seed()
        self.policy(list(CAPABILITIES), "initial-delivery")
        for interface in ("direct", "mcp"):
            _, _, result = self.read(interface)
            require(result.get("mode") == "online" and result.get("stale") is False, "online_shared_read_required")
        self.checked("online_recall_populated_mirror")
        for interface in ("direct", "mcp"):
            status, reply, request_id = self.b.raw(interface, "recall", self.selected({
                "query": self.marker, "namespace": "private"}))
            require(denial_message(interface, status, reply, self.marker, request_id) == "invalid_request",
                    "raw_authority_validation_required")
        self.checked("raw_authority_rejection", classification="validation_not_authorization")

        self.policy(["remember"], "remove-read")
        for interface in ("direct", "mcp"):
            self.b.denied(interface, "recall", self.selected({"query": self.marker}), self.marker)
        self.checked("missing_read_denial")

        self.policy(["read"], "remove-delivery")
        self.control("offline")
        for interface in ("direct", "mcp"):
            self.deny_read(interface, "no_committed_mirror")
        self.checked("no_delivery_hides_mirror")
        self.control("online")
        self.policy(list(CAPABILITIES), "zero-lease-delivery")
        self.wait_private_mirror()
        self.control("offline")
        for interface in ("direct", "mcp"):
            self.deny_read(interface, "access_lease_expired")
        self.private_fallback()
        self.queue_pair("withdrawn-intent")
        self.policy(["read", "deliver"], "withdraw-mutations", observe=False)
        self.control("online")
        self.wait_owner("complete", rejected=True)
        self.canonical_unchanged()
        self.checked("zero_lease_private_fallback_and_capability_withdrawal")

        self.policy(list(CAPABILITIES), "short-lease", lease=self.args.lease)
        authority_sent = min(self.read(interface)[0] for interface in ("direct", "mcp"))
        old_policy = self.access.copy()
        self.control("offline")
        cut_at = time.monotonic()
        windows = []
        for interface in ("direct", "mcp"):
            start, end, result = self.read(interface)
            lease_observation(start, end, authority_sent, self.args.lease, result, self.sentinel)
            windows.append({"interface": interface, "authority_sent_monotonic": authority_sent,
                "read_started_monotonic": start, "read_finished_monotonic": end,
                "deadline_monotonic": authority_sent + self.args.lease, "canonical_id": self.sentinel})
        self.checked("bounded_stale_lease", lease_seconds=self.args.lease, windows=windows)
        self.queue_pair("revoked-intent")
        self.revoke("disconnected-revoke")
        require(self.access["access_id"] == old_policy["access_id"]
                and self.access["version"] > old_policy["version"], "same_access_newer_revoke_required")
        expiry = cut_at + self.args.lease + 0.2
        while time.monotonic() < expiry:
            self.remaining()
            time.sleep(max(0, min(0.2, expiry - time.monotonic())))
        for interface in ("direct", "mcp"):
            self.deny_read(interface, "access_lease_expired")
        self.checked("disconnected_revocation_lease_expiry", lease_seconds=self.args.lease,
                     measured_cut_to_expiry_seconds=time.monotonic() - cut_at)
        self.restart_host()
        self.diagnostic(old_policy, "closed")
        for interface in ("direct", "mcp"):
            self.deny_read(interface, "unauthorized", cold=True)
        self.checked("cold_start_closes_shared_reads")
        self.policy(list(CAPABILITIES), "newer-regrant", observe=False)
        require(self.access["access_id"] == old_policy["access_id"]
                and self.access["version"] > old_policy["version"], "same_access_newer_regrant_required")
        self.control("online")
        self.wait_owner("complete", rejected=True)
        self.canonical_unchanged()
        for interface in ("direct", "mcp"):
            _, _, result = self.read(interface)
            require(result.get("mode") == "online" and result.get("stale") is False, "fresh_regrant_read_required")
        self.checked("newer_regrant_fresh_mirror_old_intents_rejected")
        self.report["status"] = "passed-subset"

    def exact_rows(self):
        return self.own_rows()

    def discover_private_rows(self):
        if not getattr(self, "owned_private_contents", set()):
            return
        def settled():
            result = self.b.call("direct", "list", {"q": self.marker + ":", "limit": 100})
            rows = online.listed(result)
            if result.get("pending_operations") != 0:
                return None
            for row in rows:
                if row.get("content") in self.owned_private_contents:
                    self.owned_private[row["id"]] = row["content"]
            return True
        self.poll(settled, "cleanup_private_intent_not_settled", 60)

    def wait_absent(self):
        def absent():
            shared = [row for row in self.own_rows() if row.get("content") in self.owned_contents]
            result = self.b.call("direct", "list", {"q": self.marker + ":", "limit": 100})
            private = [row for row in online.listed(result) if row["id"] in self.owned_private]
            return True if not shared and not private and result.get("pending_operations") == 0 else None
        self.poll(absent, "cleanup_owned_records_remain", 60)

    def arm_control(self, path, expected_identity, observed_identity, status):
        """Accept parent-owned preflight observations without contacting the relay."""
        path = Path(path)
        require(path.is_absolute() and ".." not in path.parts
                and isinstance(expected_identity, tuple) and len(expected_identity) == 3
                and all(type(value) is int and value >= 0 for value in expected_identity)
                and expected_identity[2] == os.getuid() and observed_identity == expected_identity,
                "owned_relay_preflight_required")
        control_state(status, "online")
        self.control_path, self.control_identity = path, expected_identity
        self.control_armed = True

    def control(self, mode):
        require(getattr(self, "control_armed", False) is True, "relay_preflight_required")
        require(mode in ("online", "offline"), "relay_mode_required")
        require(relay.socket_identity(self.control_path) == self.control_identity, "relay_ownership_changed")
        result = control_state(relay_request_sync(self.control_path, mode), mode)
        require(relay.socket_identity(self.control_path) == self.control_identity, "relay_ownership_changed")
        if hasattr(self, "report"):
            self.report["fault_active"] = mode == "offline"
        return result

    def cleanup(self):
        # Restore transport and the supported host configuration before checking
        # policy. An operator's intervening edit must never be overwritten.
        self.control("online")
        self.restore_host()
        if self.mutation_attempted:
            require(self.admin.current() == self.access, "cleanup_grant_version_changed")
        self.discover_private_rows()
        ids = cleanup_plan(self.exact_rows(), self.created_ids, self.owned_contents)
        for canonical_id in ids:
            self.a.call("direct", "forget", {"id": canonical_id})
        for canonical_id in self.owned_private:
            self.b.call("direct", "forget", {"id": canonical_id})
        self.wait_absent()
        if self.mutation_attempted and self.access.get("status") != "revoked":
            self.access = self.admin.revoke(self.marker + ":cleanup-revoke", expected=self.access)
        self.report["cleanup"] = {"status": "passed", "own_records_absent": True}

    def with_browser(self):
        from playwright.sync_api import sync_playwright
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(channel="chrome", headless=True)
            try:
                page = browser.new_page(viewport={"width": 1440, "height": 1000})
                partition = self.hosts[0]["partition"]
                selection = {"memory_space_id": partition["memory_space_id"], "host": partition["host_id"],
                    "client": partition["client_id"], "scope": partition["scope"], "namespace": partition["namespace"]}
                self.admin = online.AdminAccess(page, selection, self.hosts[1]["host_id"])
                self.admin.open()
                if any(self.hosts[1]["host_id"] in row[0].splitlines() for row in self.admin.rows()):
                    previous = self.admin.current()
                    require(previous["status"] == "revoked" and previous["reason"].startswith(
                        "MEMORY-LOCAL-" + self.run_id + "-SHARED-"), "preexisting_grant_not_owned")
                    self.access = previous
                self.run_and_cleanup()
            finally:
                browser.close()

    @staticmethod
    def failure_code(error):
        fixed_classes = (CheckFailed, pending.CheckFailed, relay.RelayError, inventory.InventoryFailed)
        if type(error) in fixed_classes and re.fullmatch(r"[a-z][a-z0-9_]{0,95}", str(error)):
            return str(error)
        return type(error).__name__

    def run_and_cleanup(self):
        try:
            self.run_matrix()
        except Exception as error:
            self.report["work_failure"] = self.failure_code(error)
            raise
        finally:
            if self.scenario_started:
                # Recovery has its own bounded budget even after a work deadline.
                self.deadline = time.monotonic() + 180
                self.a.deadline = self.b.deadline = self.deadline
                try:
                    self.cleanup()
                except Exception as error:
                    self.report["cleanup"] = {"status": "failed", "failure": self.failure_code(error)}
                    raise

    def execute(self):
        try:
            self.preflight()
            self.with_browser()
            after = inventory.snapshot(self.fixture, self.args.socket)
            preservation = inventory.compare(self.baseline, after)
            self.report["preservation"] = preservation
            require(preservation["status"] == "passed", "historical_canonical_data_changed")
            self.check_topology()
            self.report["recorded_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        except Exception as error:
            self.report["status"] = "failed"
            self.report["failure"] = self.failure_code(error)
            self.report["recorded_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        finally:
            self.save_report()
            os.close(self.report_fd)
        return self.output / "report.json"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--case-id", required=True)
    parser.add_argument("--control", required=True, type=Path)
    parser.add_argument("--primary-state", required=True, type=Path)
    parser.add_argument("--secondary-state", required=True, type=Path)
    parser.add_argument("--online-report", required=True, type=Path)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--lease", type=int, default=15)
    parser.add_argument("--timeout", type=int, default=900)
    run = OfflineMatrix(parser.parse_args(argv))
    print(run.execute())
    return 0 if (run.report["status"] == "passed-subset"
                 and run.report.get("cleanup", {}).get("status") == "passed"
                 and run.report.get("preservation", {}).get("status") == "passed"
                 and run.report.get("fault_active") is False) else 1


if __name__ == "__main__":
    raise SystemExit(main())
