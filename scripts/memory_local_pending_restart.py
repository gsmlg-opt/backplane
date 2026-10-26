#!/usr/bin/env python3
"""Check durable pending command/capture survival using an owned host-only restart.

Explicit invocation temporarily changes two primary-fixture intervals, then restores
the exact YAML bytes and normal host operation. This is a restart subset, not full
L11/L12/L18 or interrupted-snapshot qualification. Never stops the gateway.
"""

import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("memory_local_recovery", Path(__file__).with_name("memory_local_recovery.py"))
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class CheckFailed(RuntimeError):
    """Fixed nonsecret failure code; raw exceptions never enter reports."""


def require(condition, code):
    if not condition:
        raise CheckFailed(code)


def valid_uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except (ValueError, TypeError, AttributeError):
        return False


def private_file(path):
    path = Path(path).absolute()
    info = path.lstat()
    require(path.resolve(strict=True) == path and stat.S_ISREG(info.st_mode)
            and info.st_uid == os.getuid() and not info.st_mode & 0o077,
            "private_regular_nonsymlink_file_required")
    return info


def private_read(path):
    info = private_file(path)
    require(info.st_size <= 1_000_000, "input_size_bound")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(fd)
        require((info.st_dev, info.st_ino) == (opened.st_dev, opened.st_ino), "input_identity_changed")
        return os.read(fd, 1_000_001)
    finally:
        os.close(fd)


def scalars(raw):
    """Read only the generated fixture's plain scalar subset, without reserializing YAML."""
    values, stack = {}, []
    for line in raw.decode("utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r"( *)([a-z_][a-z_0-9]*):(?: (.*))?", line)
        require(match is not None, "generated_fixture_yaml_required")
        indent, key, value = len(match[1]), match[2], match[3]
        while stack and stack[-1][0] >= indent:
            stack.pop()
        path = tuple(item[1] for item in stack) + (key,)
        require(path not in values, "duplicate_yaml_key")
        values[path] = value
        if value is None:
            stack.append((indent, key))
    return values


def delayed_config(original):
    values = scalars(original)
    require(all(values.get(key) == "1000" for key in (
        ("memory", "sync_interval_ms"), ("capture", "upload_interval_ms"))), "normal_fixture_intervals_required")
    result = original
    for section, key in ((b"memory", b"sync_interval_ms"), (b"capture", b"upload_interval_ms")):
        pattern = rb"(^" + section + rb":\r?\n(?:(?!^[^ \r\n]).*\r?\n)*?^  " + key + rb": )1000(?=\r?$)"
        result, count = re.subn(pattern, rb"\g<1>600000", result, flags=re.MULTILINE)
        require(count == 1, "exact_interval_patch_required")
    return result


class ConfigGuard:
    def __init__(self, path, backup):
        self.path, self.backup = path, backup
        info = private_file(path)
        self.identity = info.st_dev, info.st_ino
        self.original = private_read(path)
        self.held = delayed_config(self.original)
        self.expected = self.original
        self.changed = False

    def check(self):
        info = private_file(self.path)
        require((info.st_dev, info.st_ino) == self.identity and private_read(self.path) == self.expected,
                "external_config_edit_refused")

    def replace(self, content):
        self.check()
        fd = os.open(self.path, os.O_RDWR | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            require((info.st_dev, info.st_ino) == self.identity
                    and os.read(fd, 1_000_001) == self.expected, "external_config_edit_refused")
            os.lseek(fd, 0, os.SEEK_SET)
            with os.fdopen(os.dup(fd), "wb") as stream:
                stream.write(content)
                stream.truncate()
                stream.flush()
                os.fsync(stream.fileno())
            self.expected = content
        finally:
            os.close(fd)
        self.check()

    def hold(self):
        fd = os.open(self.backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(self.original)
            stream.flush()
            os.fsync(stream.fileno())
        self.changed = True
        self.replace(self.held)

    def restore(self):
        self.replace(self.original)


class Effects:
    now = staticmethod(time.monotonic)
    sleep = staticmethod(time.sleep)
    read_state = staticmethod(recovery.lifecycle.read_state)
    owns = staticmethod(recovery.lifecycle.owns)

    def host_service(self, state_dir, action, timeout):
        recovery.lifecycle.service(state_dir, "host", action, timeout=timeout)

    def post(self, base, path, body, timeout):
        request = urllib.request.Request(base + path, data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(1_000_001)
            require(len(raw) <= 1_000_000, "http_response_bound")
            return response.status, json.loads(raw)

    def owner_snapshot(self, base, request, timeout):
        try:
            status, reply = self.post(base, "/memory/diagnostics", request, timeout)
        except (urllib.error.URLError, TimeoutError):
            raise CheckFailed("owner_diagnostics_unavailable") from None
        require(status == 200 and reply.get("ok") is True and isinstance(reply.get("result"), dict),
                "owner_diagnostics_unavailable")
        return reply["result"]

    def probe(self, operation, request, timeout):
        return recovery.store_probe(operation, request, timeout=timeout)

    def tombstones(self, path, scope, timeout):
        result = subprocess.run([sys.executable, "-I", str(Path(__file__).resolve()), "--tombstones-probe"],
                                input=json.dumps({"path": str(path), "scope": scope}), text=True,
                                capture_output=True, timeout=timeout)
        require(result.returncode == 0 and len(result.stdout) < 1000, "tombstone_probe_failed")
        return json.loads(result.stdout)

    def canonical(self, runner, timeout):
        psql = shutil.which("psql") or str(ROOT / ".devenv/profile/bin/psql")
        command = [psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-h", runner.socket, "-d", runner.database]
        for key, value in {"space": runner.partition["memory_space_id"], "scope": runner.scope,
                           "content": runner.content, "session": runner.agent}.items():
            command.extend(["-v", key + "=" + value])
        sql = """BEGIN READ ONLY;
SET LOCAL statement_timeout='5s';
SELECT json_build_object(
 'memory_ids', (SELECT coalesce(json_agg(id::text), '[]'::json) FROM bpm_memories
  WHERE memory_space_id=:'space'::uuid AND scope=:'scope' AND namespace='private' AND content=:'content'),
 'event_ids', (SELECT coalesce(json_agg(id::text), '[]'::json) FROM bpm_events
  WHERE memory_space_id=:'space'::uuid AND session_id=:'session'));
COMMIT;
"""
        result = subprocess.run(command, input=sql, text=True, capture_output=True, timeout=timeout)
        require(result.returncode == 0 and len(result.stdout) < 10_000, "canonical_read_only_query_failed")
        return json.loads(result.stdout)


class Runner:
    def __init__(self, fixture, state_dir, case_id, database="backplane_dev",
                 socket="/tmp/devenv-e733526/postgres", effects=None, output=None):
        self.fixture_path, self.state_dir = Path(fixture).absolute(), Path(state_dir).absolute()
        self.case_id, self.database, self.socket = case_id, database, socket
        self.fx = effects or Effects()
        self.output = output
        self.guard = None
        self.started, self.held_started = self.fx.now(), None
        self.report = {"status": "failed", "complete_L11_L12_L18": False,
                       "interrupted_snapshot_visibility_tested": False,
                       "tombstone_survival_proven": False, "phases": [],
                       "cleanup": {"attempted": False, "verified": False}}

    def remaining(self, cleanup=False):
        remaining = (300 if cleanup else 210) - (self.fx.now() - self.started)
        require(remaining > 0, "scenario_deadline_exceeded")
        if self.held_started is not None and not cleanup:
            held = 120 - (self.fx.now() - self.held_started)
            require(held > 0, "delayed_host_window_exceeded")
            remaining = min(remaining, held)
        return remaining

    def bound(self, maximum=8, cleanup=False):
        return max(0.01, min(maximum, self.remaining(cleanup)))

    def record(self, phase, **safe):
        self.report["phases"].append({"phase": phase, "elapsed_ms": round((self.fx.now() - self.started) * 1000), **safe})
        self.save()

    def save(self):
        if self.output is not None and self.output.is_dir():
            path = self.output / "report.json"
            fd = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w") as stream:
                json.dump(self.report, stream, indent=2)

    def stack(self, running=None):
        private_file(self.state_dir / "state.json")
        state = self.fx.read_state(self.state_dir)
        require(Path(state["config"]).absolute() == self.config, "fixture_lifecycle_mismatch")
        if hasattr(self, "urls"):
            require(state["urls"] == self.urls, "fixture_endpoints_changed")
        records = {row["name"]: row for row in state["processes"]}
        require(len(state["processes"]) == 2 and set(records) == {"gateway", "host"}, "owned_stack_required")
        gateway = records["gateway"]
        require(not gateway.get("stopped") and self.fx.owns(gateway), "owned_gateway_required")
        identity = {key: gateway.get(key) for key in ("pid", "birth", "pgid", "uid")}
        if hasattr(self, "gateway"):
            require(identity == self.gateway, "gateway_identity_changed")
        else:
            self.gateway = identity
        host = records["host"]
        if not host.get("stopped"):
            require(self.fx.owns(host), "owned_host_required")
        if running is not None:
            require(bool(host.get("stopped")) != running, "host_running_state_mismatch")
        return state

    def preflight(self):
        require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,39}", self.case_id) is not None, "case_id_invalid")
        fixture = json.loads(private_read(self.fixture_path))
        self.run_id = fixture["run_id"]
        require(isinstance(self.run_id, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}", self.run_id), "fixture_run_id_invalid")
        require(isinstance(fixture.get("hosts"), list) and len(fixture["hosts"]) == 2, "two_fixture_hosts_required")
        for host, suffix in zip(fixture["hosts"], ("primary", "isolated")):
            partition = host["partition"]
            require(all(valid_uuid(partition.get(key)) for key in ("memory_space_id", "host_id"))
                    and partition.get("host_id") == host.get("host_id")
                    and partition.get("client_id") == "host:" + partition["host_id"]
                    and partition.get("scope") == "memory_local_" + self.run_id + "_" + suffix
                    and partition.get("namespace") == "private"
                    and host.get("name") == "memory-local-" + self.run_id + "-" + suffix,
                    "fixture_partition_not_owned")
            private_file(host["config"])
        require(fixture["hosts"][0]["partition"]["memory_space_id"] != fixture["hosts"][1]["partition"]["memory_space_id"],
                "distinct_fixture_spaces_required")
        primary = fixture["hosts"][0]
        self.config = Path(primary["config"]).absolute()
        self.partition, self.scope = primary["partition"], primary["partition"]["scope"]
        self.stores = {name: self.config.parent / filename for name, filename in (
            ("commands", "commands.db"), ("capture", "capture-spool.db"), ("mirror", "mirror.db"))}
        inodes = {(info.st_dev, info.st_ino) for info in map(private_file, self.stores.values())}
        require(len(inodes) == 3, "three_distinct_prepared_stores_required")
        state = self.stack(running=True)
        ports = {"public": 4220, "admin": 4221, "host": 4222}
        for name, port in ports.items():
            parsed = urllib.parse.urlsplit(state["urls"][name])
            require(parsed.scheme == "http" and parsed.hostname in ("localhost", "127.0.0.1", "::1")
                    and parsed.port == port and parsed.path in ("", "/") and not parsed.query
                    and not parsed.fragment and parsed.username is None and parsed.password is None,
                    "loopback_fixture_endpoints_required")
        self.host_url = state["urls"]["host"].rstrip("/")
        self.urls = dict(state["urls"])
        self.agent = "memory-local-" + self.run_id + "-pending-restart-" + self.case_id
        self.marker = "MEMORY-PENDING-RESTART-" + self.run_id + "-" + self.case_id
        self.content = self.marker + " durable pending command"
        if self.output is None:
            self.output = ROOT / ".devenv/memory-local-evidence" / self.run_id / ("pending-restart-" + self.case_id + "-" + str(time.time_ns()))
        self.output = Path(self.output)
        self.output.mkdir(parents=True, exist_ok=False, mode=0o700)
        self.backup = self.output / "original-host.yaml.private"
        self.guard = ConfigGuard(self.config, self.backup)
        config = scalars(self.guard.original)
        expected = {("agent", "host_id"): self.partition["host_id"], ("agent", "http_port"): "4222",
                    ("agent", "http_bind"): "127.0.0.1", ("memory", "bound_scope"): self.scope,
                    ("memory", "enabled"): "true", ("capture", "enabled"): "true",
                    ("memory", "host_sync", "enabled"): "true",
                    ("memory", "db_path"): str(self.stores["commands"]),
                    ("capture", "db_path"): str(self.stores["capture"]),
                    ("memory", "host_sync", "db_path"): str(self.stores["mirror"])}
        require(all(config.get(key) == value for key, value in expected.items()), "fixture_config_binding_required")
        hub = urllib.parse.urlsplit(config.get(("agent", "hub_url"), ""))
        require(hub.scheme == "http" and hub.hostname in ("127.0.0.1", "localhost", "::1") and hub.port == 4220
                and hub.username is None and hub.password is None and hub.path in ("", "/")
                and not hub.query and not hub.fragment, "config_loopback_hub_required")
        baseline = self.direct("list", {"q": "MEMORY-LOCAL-" + self.run_id, "limit": 20},
                               agent="memory-local-" + self.run_id)
        require(baseline.get("mode") == "online" and isinstance(baseline.get("results"), list), "baseline_online_list_required")
        self.survivors = sorted({recovery.identity(row) for row in baseline["results"] if valid_uuid(recovery.identity(row))})
        require(self.survivors, "populated_existing_mirror_required")
        baseline_observation = self.observe()
        self.baseline_mirror = baseline_observation["mirror"]
        require(self.baseline_mirror.get("partition") and self.baseline_mirror.get("active_target_ids")
                and self.baseline_mirror["partition"].get("active_generation") is not None
                and type(self.baseline_mirror["partition"].get("applied_revision")) is int
                and self.baseline_mirror["partition"]["applied_revision"] > 0
                and self.baseline_mirror["partition"].get("snapshot_id") is None, "populated_existing_mirror_required")
        generation = self.baseline_mirror["partition"]["active_generation"]
        require(generation == "0" or valid_uuid(generation), "mirror_generation_invalid")
        self.survivors = self.baseline_mirror["active_target_ids"]
        self.last_mirror_revision = self.baseline_mirror["partition"]["applied_revision"]
        self.baseline_tombstones = baseline_observation["tombstones"]
        require(type(self.baseline_tombstones.get("count")) is int and 0 <= self.baseline_tombstones["count"] <= 10000,
                "tombstone_count_bound")
        require(self.fx.canonical(self, self.bound(10)) == {"memory_ids": [], "event_ids": []}, "fresh_case_id_required")
        self.record("preflight", observation_source="owner_connection", populated_existing_mirror=True,
                    mirror_generation=generation, mirror_revision=self.baseline_mirror["partition"]["applied_revision"],
                    mirror_target_ids=self.survivors, existing_tombstones=self.baseline_tombstones["count"])

    def direct(self, method, body, agent=None, cleanup=False):
        status, reply = self.fx.post(self.host_url, f"/memory/{agent or self.agent}/call/{method}",
                                     {"scope": self.scope, **body}, self.bound(cleanup=cleanup))
        self.record("direct_receipt", method=method, http_status=status, receipt=recovery.safe_reply(reply))
        require(status == 200 and reply.get("ok") is True and isinstance(reply.get("result"), dict), "direct_http_success_required")
        self.remaining(cleanup)
        return reply["result"]

    def capture(self, expected):
        status, reply = self.fx.post(self.host_url, "/capture/v1/hooks/codex/SessionStart", self.capture_body, self.bound())
        self.record("capture_receipt", http_status=status, receipt=recovery.safe_reply(reply))
        require(status == 202 and reply.get("ok") is True and reply.get("status") == expected
                and valid_uuid(reply.get("event_id")), "capture_acceptance_required")
        self.remaining()
        return reply["event_id"]

    def observe(self, stopped=False, cleanup=False):
        self.stack(running=not stopped)
        if stopped:
            # Independent readers are used only after the owned host has exited.
            commands = self.fx.probe("commands", {"path": str(self.stores["commands"]),
                "ids": [self.local_id], "scope": self.scope, "hashes": []}, self.bound(cleanup=cleanup))
            capture = self.fx.probe("capture", {"path": str(self.stores["capture"]),
                "ids": [self.event_id]}, self.bound(cleanup=cleanup))
            mirror = self.fx.probe("mirror", {"path": str(self.stores["mirror"]), "ids": self.survivors,
                "partition": [self.partition[key] for key in ("memory_space_id", "scope", "namespace")]}, self.bound(cleanup=cleanup))
            tombstones = self.fx.tombstones(self.stores["commands"], self.scope, self.bound(cleanup=cleanup))
            observation = {"commands": commands, "capture": capture, "mirror": mirror,
                           "tombstones": tombstones, "observation_source": "stopped_store"}
        else:
            observation = self.fx.owner_snapshot(self.host_url, {
                "partition": {key: self.partition[key] for key in ("memory_space_id", "scope", "namespace")},
                "command_ids": [self.local_id] if hasattr(self, "local_id") else [],
                "event_ids": [self.event_id] if hasattr(self, "event_id") else [],
                "mirror_ids": self.survivors}, self.bound(cleanup=cleanup))
            require(isinstance(observation, dict) and observation.get("observation_source") == "owner_connection"
                    and all(isinstance(observation.get(key), dict) for key in ("commands", "capture", "mirror", "tombstones")),
                    "owner_diagnostics_shape_required")
        # The stopped reader includes private internal hashes used by other drivers.
        # Normalize to the same metadata contract returned by the owner endpoint.
        observation["commands"] = {
            "outbox": observation["commands"]["outbox"],
            "memories": [{key: row.get(key) for key in ("id", "remote_id", "sync_state", "deleted")}
                         for row in observation["commands"]["memories"]]}
        observation["capture"].pop("expected", None)
        return observation

    def snapshot(self, label, stopped=False):
        observation = self.observe(stopped=stopped)
        commands, capture, mirror, tombstones = (observation[key] for key in ("commands", "capture", "mirror", "tombstones"))
        self.remaining()
        partition = mirror.get("partition") or {}
        generation = partition.get("active_generation")
        require((generation == "0" or valid_uuid(generation)) and partition.get("snapshot_id") is None
                and type(partition.get("applied_revision")) is int
                and partition["applied_revision"] >= self.last_mirror_revision
                and set(self.survivors).issubset(mirror.get("active_target_ids", [])), "existing_mirror_survival_required")
        self.last_mirror_revision = partition["applied_revision"]
        require(tombstones == self.baseline_tombstones, "existing_tombstones_changed")
        # Only allowlisted metadata enters the report; hashes and file/config bodies remain private.
        self.record(label, observation_source=observation["observation_source"], command_id=self.local_id, event_id=self.event_id,
                    outbox=[{"seq": row.get("seq") if type(row.get("seq")) is int else None,
                             "op": row.get("op") if row.get("op") in ("remember", "forget") else "invalid",
                             "state": row.get("state") if row.get("state") in ("pending", "inflight", "retry_wait", "done", "failed") else "invalid",
                             "attempts": row.get("attempts") if type(row.get("attempts")) is int else None}
                            for row in commands["outbox"]],
                    capture_pending=all(row["state"] == "pending" and not row["acknowledged"] for row in capture["rows"]),
                    mirror_generation=generation, mirror_revision=partition["applied_revision"],
                    mirror_target_ids=mirror["active_target_ids"], tombstones=tombstones["count"])
        return {"commands": commands, "capture": capture}

    def pending(self, snapshot):
        rows = snapshot["commands"]["outbox"]
        require(len(rows) == 1 and rows[0]["memory_id"] == self.local_id and rows[0]["op"] == "remember"
                and rows[0]["state"] == "pending" and rows[0]["attempts"] == 0
                and rows[0].get("ack_canonical_id") is None and rows[0].get("ack_revision") is None,
                "command_pending_attempts_zero_required")
        memories = snapshot["commands"]["memories"]
        require(len(memories) == 1 and memories[0]["id"] == self.local_id
                and memories[0]["sync_state"] == "pending" and not memories[0]["deleted"], "local_pending_memory_required")
        capture = snapshot["capture"]
        require(capture.get("missing_or_compacted") == 0 and len(capture["rows"]) == 1
                and capture["rows"][0]["event_id"] == self.event_id and capture["rows"][0]["state"] == "pending"
                and capture["rows"][0]["attempts"] == 0 and not capture["rows"][0]["acknowledged"],
                "capture_pending_attempts_zero_required")

    def service(self, action, cleanup=False):
        self.guard.check()
        self.stack()
        # Existing stop/start helpers have bounded shutdown overhead; reserve it before invoking them.
        require(self.remaining(cleanup) > 12, "lifecycle_cleanup_headroom_required")
        if action == "start" and self.guard.expected == self.guard.held:
            self.held_started = self.fx.now()
        held_started = self.held_started
        self.fx.host_service(self.state_dir, action, min(45, self.remaining(cleanup) - 12))
        self.stack(running=action == "start")
        if action == "stop":
            self.held_started = None
            if held_started is not None and not cleanup:
                require(self.fx.now() - held_started < 120, "delayed_host_window_exceeded")
        self.remaining(cleanup)
        self.record("host_" + action)

    def restoration_listing(self):
        """Retry only startup 503/refused connections; normal direct calls stay strict."""
        try:
            status, reply = self.fx.post(
                self.host_url, "/memory/memory-local-" + self.run_id + "/call/list",
                {"scope": self.scope, "q": "MEMORY-LOCAL-" + self.run_id, "limit": 20},
                self.bound(cleanup=True))
        except urllib.error.HTTPError as error:
            status, reply = error.code, None
            error.close()
        except urllib.error.URLError as error:
            if not isinstance(error.reason, ConnectionRefusedError):
                raise
            self.remaining(cleanup=True)
            return None
        self.remaining(cleanup=True)
        if status == 503:
            return None
        require(status == 200 and isinstance(reply, dict) and reply.get("ok") is True
                and isinstance(reply.get("result"), dict), "restored_host_http_success_required")
        return reply["result"]

    def restore_host(self):
        self.report["cleanup"]["attempted"] = True
        self.guard.check()
        try:
            state = self.stack()
            host = next(row for row in state["processes"] if row["name"] == "host")
            if not host.get("stopped"):
                self.service("stop", cleanup=True)
        finally:
            # Process identity changes prohibit lifecycle actions, but do not justify
            # leaving our YAML edit behind when the independent file guard is intact.
            self.guard.restore()
        self.held_started = None
        self.service("start", cleanup=True)
        while True:
            self.stack(running=True)
            health = self.restoration_listing()
            if (health is not None and health.get("mode") == "online" and isinstance(health.get("results"), list)
                    and set(self.survivors).issubset({recovery.identity(row) for row in health["results"]})):
                break
            self.fx.sleep(min(0.5, self.remaining(cleanup=True)))
        self.guard.check()
        self.report["cleanup"]["verified"] = True
        self.record("original_config_host_restored", exact_original_bytes=True, online=True)
        self.backup.unlink()

    def settle(self):
        while True:
            observation = self.observe(cleanup=True)
            commands, capture = observation["commands"], observation["capture"]
            rows = commands["outbox"]
            if (len(rows) == 1 and rows[0]["memory_id"] == self.local_id and rows[0]["op"] == "remember"
                    and rows[0]["state"] == "done" and valid_uuid(rows[0].get("ack_canonical_id"))
                    and type(rows[0].get("ack_revision")) is int and rows[0]["ack_revision"] > 0
                    and len(capture["rows"]) == 1 and capture["rows"][0]["event_id"] == self.event_id
                    and capture["rows"][0]["state"] == "acknowledged"
                    and capture["rows"][0]["acknowledged"]):
                canonical_id = rows[0]["ack_canonical_id"]
                memories = commands["memories"]
                require(any(row.get("remote_id") == canonical_id and row.get("sync_state") == "synced" for row in memories),
                        "local_canonical_ack_required")
                canonical = self.fx.canonical(self, self.bound(10, cleanup=True))
                require(canonical == {"memory_ids": [canonical_id], "event_ids": [self.event_id]}, "canonical_exactly_once_required")
                listed = self.direct("list", {"q": self.marker, "limit": 20}, cleanup=True)
                results = listed.get("results")
                require(listed.get("mode") == "online" and isinstance(results, list) and results
                        and len({recovery.identity(row) for row in results}) == len(results)
                        and len(results) == 1 and recovery.identity(results[0]) == canonical_id
                        and results[0].get("content") == self.content, "online_unique_marker_required")
                self.record("normal_sync_settled", canonical_id=canonical_id, ack_revision=rows[0]["ack_revision"],
                            canonical_memories=1, canonical_events=1, online_results=1)
                return
            self.fx.sleep(min(0.5, self.remaining(cleanup=True)))

    def run(self):
        try:
            self.preflight()
            self.guard.hold()
            self.service("stop")
            self.service("start")
            self.write_body = {"content": self.content, "type": "semantic", "idempotency_key": self.agent + ":pending"}
            reply = self.direct("remember", self.write_body)
            require(valid_uuid(reply.get("id")) and reply.get("sync_state") == "pending"
                    and reply.get("authority") == "provisional" and reply.get("consistency") == "pending_canonical_ack",
                    "provisional_pending_acceptance_required")
            self.local_id = reply["id"]
            self.capture_body = {"hook_event_name": "SessionStart", "session_id": self.agent, "agent_id": self.agent,
                                 "cwd": "/synthetic/backplane-memory/" + self.run_id, "scope": self.scope,
                                 "occurred_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                 "source_event_id": self.agent + ":0"}
            self.event_id = self.capture("accepted")
            before = self.snapshot("before_stop")
            self.pending(before)
            self.service("stop")
            down = self.snapshot("while_host_down", stopped=True)
            self.pending(down)
            require(down == before, "durable_rows_changed_while_down")
            self.service("start")
            after = self.snapshot("after_delayed_restart")
            self.pending(after)
            require(after == before, "durable_rows_changed_after_restart")
            require(self.direct("remember", self.write_body).get("id") == self.local_id, "command_duplicate_identity")
            require(self.capture("duplicate") == self.event_id, "capture_duplicate_identity")
            duplicate = self.snapshot("after_duplicates")
            self.pending(duplicate)
            require(duplicate == before, "duplicate_changed_durable_identity")
            self.report["tombstone_survival_proven"] = self.baseline_tombstones["count"] > 0
            self.restore_host()
            self.settle()
            self.stack(running=True)
            self.guard.check()
            self.remaining(cleanup=True)
            self.report["status"] = "passed-pending-restart-subset"
        except (Exception, KeyboardInterrupt) as error:
            self.report["failure"] = str(error) if isinstance(error, CheckFailed) else "unexpected_operation_failure"
        finally:
            if self.guard is not None and self.guard.changed and not self.report["cleanup"]["verified"]:
                try:
                    self.restore_host()
                except (Exception, KeyboardInterrupt):
                    self.report["cleanup"]["failure"] = "RESTORATION_NOT_PROVEN"
                    self.report["status"] = "failed"
            self.report["elapsed_ms"] = round((self.fx.now() - self.started) * 1000)
            self.save()
        return self.report


def tombstones_probe():
    request = json.load(sys.stdin)
    digest, count = hashlib.sha256(), 0
    with recovery.read_only(request["path"]) as connection:
        for row in connection.execute("SELECT content_hash FROM tombstones WHERE scope=? ORDER BY content_hash LIMIT 10001", [request["scope"]]):
            count += 1
            require(count <= 10000, "tombstone_count_bound")
            digest.update(json.dumps(row[0]).encode() + b"\n")
    print(json.dumps({"count": count, "digest": digest.hexdigest()}))


def main():
    if sys.argv[1:] == ["--tombstones-probe"]:
        try:
            tombstones_probe()
            return 0
        except Exception:
            return 1
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--state-dir", type=Path, default=ROOT / ".devenv/memory-local")
    parser.add_argument("--case-id", required=True)
    parser.add_argument("--database", default="backplane_dev")
    parser.add_argument("--socket", default="/tmp/devenv-e733526/postgres")
    args = parser.parse_args()
    runner = Runner(args.fixture, args.state_dir, args.case_id, args.database, args.socket)
    report = runner.run()
    print(json.dumps({key: report[key] for key in ("status", "cleanup", "elapsed_ms")}))
    if runner.output is not None:
        print(runner.output / "report.json")
    return 0 if report["status"] == "passed-pending-restart-subset" else 1


if __name__ == "__main__":
    sys.exit(main())
