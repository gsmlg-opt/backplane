#!/usr/bin/env python3
"""Prove cold host-first automatic join on the owned oct20-a development stack.

Explicit invocation stops gateway and host, starts the host alone, accepts fresh
command/capture work, then starts only the gateway. No configuration or store is
replaced. The synthetic records and case reservation are retained. This is L01
evidence, not complete L01-L18 acceptance. Requires exclusive lifecycle ownership.
"""

import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import re
import shutil
import signal
import socket
import stat
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("host_first_pending", Path(__file__).with_name("memory_local_pending_restart.py"))
pending = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pending)
lifecycle = pending.recovery.lifecycle
CheckFailed, require, valid_uuid = pending.CheckFailed, pending.require, pending.valid_uuid


def safe_directory(path, create=False):
    path = Path(path).absolute()
    require(path.is_relative_to(ROOT / ".devenv"), "private_devenv_path_required")
    for folder in reversed([path, *path.parents]):
        if not folder.is_relative_to(ROOT / ".devenv"):
            continue
        if create and not folder.exists():
            folder.mkdir(mode=0o700)
        info = folder.lstat()
        require(folder.resolve(strict=True) == folder and stat.S_ISDIR(info.st_mode)
                and info.st_uid == os.getuid() and not info.st_mode & 0o022, "unsafe_directory")
    return path


def identity(record):
    return {key: record[key] for key in ("pid", "birth", "pgid", "uid")}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise CheckFailed("http_redirect_refused")


def canonical_sql():
    partition = " AND ".join(key + "=:'" + key + "'" + ("::uuid" if key == "memory_space_id" else "")
                             for key in ("memory_space_id", "host_id", "client_id", "scope", "namespace"))
    return """BEGIN READ ONLY;
SET LOCAL statement_timeout='4s';
SET LOCAL search_path=public;
WITH memories AS (SELECT id FROM bpm_memories WHERE """ + partition + """ AND content=:'content' LIMIT 2),
events AS (SELECT id,source_sequence,event_type FROM bpm_events WHERE """ + partition + """ AND session_id=:'session' LIMIT 2),
sessions AS (SELECT subject_id,status,source_sequence_max,gap_count,input_revision FROM bpm_projected_sessions
 WHERE """ + partition + """ AND session_id=:'session' LIMIT 2),
stages AS (SELECT p.status,p.input_revision,p.completed_at IS NOT NULL AS finished FROM bpm_projection_states p
 JOIN sessions s ON s.subject_id=p.subject_id WHERE p.projector='session' AND p.subject_type='captured_session'
 AND p.memory_space_id=:'memory_space_id'::uuid AND p.host_id=:'host_id'
 AND p.scope=:'scope' AND p.namespace=:'namespace' LIMIT 2),
jobs AS (SELECT id,state,attempt,completed_at IS NOT NULL AS finished FROM styx_jobs
 WHERE worker IN ('Backplane.Memory.Workers.ProjectionRepairWorker','Elixir.Backplane.Memory.Workers.ProjectionRepairWorker')
 AND ((args->>'host_id'=:'host_id' AND args->>'session_id'=:'session')
 OR args->>'event_id' IN (SELECT id::text FROM events)) ORDER BY id DESC LIMIT 4)
SELECT json_build_object('database',current_database(),
 'memory_ids',(SELECT coalesce(json_agg(id::text),'[]'::json) FROM memories),
 'events',(SELECT coalesce(json_agg(row_to_json(e)),'[]'::json) FROM events e),
 'sessions',(SELECT coalesce(json_agg(row_to_json(s)),'[]'::json) FROM sessions s),
 'stages',(SELECT coalesce(json_agg(row_to_json(p)),'[]'::json) FROM stages p),
 'jobs',(SELECT coalesce(json_agg(row_to_json(j)),'[]'::json) FROM jobs j));
COMMIT;
"""


class Effects(pending.Effects):
    ready = staticmethod(lifecycle.http_ready)

    def stopped_empty(self, record):
        return lifecycle.process_identity(record["pid"]) is None and not lifecycle.group_alive(record["pgid"])

    def revision(self):
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()

    def reachable(self, port):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                return True
        except OSError:
            return False

    def service(self, state_dir, name, action, timeout):
        lifecycle.service(state_dir, name, action, timeout=timeout)

    def post(self, base, path, body, timeout):
        request = urllib.request.Request(base + path, data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        try:
            response = urllib.request.build_opener(NoRedirect()).open(request, timeout=timeout)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read(100_001)
            require(len(raw) <= 100_000, "http_response_bound")
            return response.status, json.loads(raw)

    def owner_snapshot(self, base, request, timeout):
        status, reply = self.post(base, "/memory/diagnostics", request, timeout)
        # A cold host cannot resolve this protected diagnostic partition until
        # authenticated V2 negotiation. Permanent rejection is never retried.
        if status == 503 and reply == {"ok": False, "error": "diagnostics unavailable"}:
            return None
        require(status == 200 and reply.get("ok") is True and isinstance(reply.get("result"), dict),
                "owner_diagnostics_unavailable")
        return reply["result"]

    def canonical(self, runner, timeout):
        psql = shutil.which("psql") or str(ROOT / ".devenv/profile/bin/psql")
        command = [psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-h", runner.socket, "-d", "backplane_dev"]
        for key, value in {**runner.partition, "content": runner.content, "session": runner.agent}.items():
            command.extend(["-v", key + "=" + value])
        result = subprocess.run(command, input=canonical_sql(), text=True, capture_output=True, timeout=timeout)
        require(result.returncode == 0 and len(result.stdout) < 10_000, "canonical_read_only_query_failed")
        result = json.loads(result.stdout)
        require(result.get("database") == "backplane_dev" and all(isinstance(result.get(key), list)
                for key in ("memory_ids", "events", "sessions", "stages", "jobs")), "canonical_shape_required")
        return result


class Runner:
    def __init__(self, fixture, state_dir, case_id, effects=None, timeout=240,
                 socket="/tmp/devenv-e733526/postgres"):
        self.fixture_path, self.state_dir = Path(fixture).absolute(), Path(state_dir).absolute()
        self.case_id, self.socket, self.timeout = case_id, socket, timeout
        self.fx = effects or Effects()
        self.started = self.fx.now()
        self.deadline = self.started + timeout
        self.output, self.disrupted = None, False
        self.expected, self.files = {}, {}
        self.report = {"status": "failed", "complete_L01_L18": False,
            "evidence_level": "owned-cold-host-before-gateway-normal-sync-and-styx",
            "runtime_hook_integration": "adapter-only", "phases": [],
            "cleanup": {"attempted": False, "verified": False}}

    def bound(self, maximum=8):
        remaining = self.deadline - self.fx.now()
        require(remaining > 0, "scenario_deadline_exceeded")
        return min(maximum, remaining)

    def record(self, phase, **safe):
        self.report["phases"].append({"phase": phase, **safe})
        self.save()

    def save(self):
        if self.output:
            path = self.output / "report.json"
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w") as stream:
                json.dump(self.report, stream, indent=2)

    def files_unchanged(self):
        for path, original in self.files.items():
            info = pending.private_file(path)
            require((info.st_dev, info.st_ino) == original, "fixture_file_identity_changed")
        require(pending.private_read(self.config) == self.original, "external_config_edit_refused")

    def stack(self):
        pending.private_file(self.state_dir / "state.json")
        state = self.fx.read_state(self.state_dir)
        require(state["config"] == str(self.config) and state["urls"] == self.urls, "fixture_lifecycle_mismatch")
        rows = {row["name"]: row for row in state["processes"]}
        require(len(state["processes"]) == 2 and set(rows) == {"gateway", "host"}, "owned_stack_required")
        for name, row in rows.items():
            require(identity(row) == self.expected[name], "service_identity_changed")
            if not row.get("stopped"):
                require(self.fx.owns(row), "service_ownership_lost")
        return rows

    def healthy(self):
        rows = self.stack()
        return all(not row.get("stopped") for row in rows.values()) and all(
            self.fx.ready(url) for url in self.urls.values())

    def direct(self, method, arguments):
        arguments = arguments if method == "stats" else {"scope": self.partition["scope"], **arguments}
        status, reply = self.fx.post(self.urls["host"].rstrip("/"),
            f"/memory/{self.agent}/call/{method}", arguments, self.bound())
        require(status == 200 and reply.get("ok") is True and isinstance(reply.get("result"), dict),
                "direct_http_success_required")
        return reply["result"]

    def preflight(self):
        require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,39}", self.case_id or ""), "case_id_invalid")
        require(120 <= self.timeout <= 360, "timeout_bound_required")
        expected = ROOT / ".devenv/memory-local-fixtures/oct20-a/fixture.json"
        require(self.fixture_path == expected and self.state_dir == ROOT / ".devenv/memory-local", "oct20_a_owned_fixture_only")
        safe_directory(self.fixture_path.parent)
        safe_directory(self.state_dir)
        fixture = json.loads(pending.private_read(self.fixture_path))
        require(fixture.get("run_id") == "oct20-a" and len(fixture.get("hosts", [])) == 2, "synthetic_fixture_required")
        primary = fixture["hosts"][0]
        self.partition = {key: primary["partition"][key] for key in (
            "memory_space_id", "host_id", "client_id", "scope", "namespace")}
        require(primary.get("name") == "memory-local-oct20-a-primary" and valid_uuid(primary.get("host_id"))
                and self.partition["host_id"] == primary["host_id"] and valid_uuid(self.partition["memory_space_id"])
                and self.partition["client_id"] == "host:" + primary["host_id"]
                and self.partition["scope"] == "memory_local_oct20-a_primary"
                and self.partition["namespace"] == "private", "primary_fixture_partition_required")
        self.config = expected.parent / "primary/host.yaml"
        require(primary["config"] == str(self.config), "fixture_config_binding_required")
        safe_directory(self.config.parent)
        self.original = pending.private_read(self.config)
        config = pending.scalars(self.original)
        self.stores = [self.config.parent / name for name in ("commands.db", "capture-spool.db", "mirror.db")]
        values = {("agent", "host_id"): primary["host_id"], ("agent", "http_bind"): "127.0.0.1",
            ("agent", "http_port"): "4222", ("memory", "enabled"): "true", ("capture", "enabled"): "true",
            ("memory", "bound_scope"): self.partition["scope"], ("memory", "host_sync_v2", "enabled"): "true",
            ("memory", "host_sync_v2", "development_plaintext"): "true",
            ("memory", "db_path"): str(self.stores[0]), ("capture", "db_path"): str(self.stores[1]),
            ("memory", "host_sync_v2", "db_path"): str(self.stores[2])}
        require(all(config.get(key) == value for key, value in values.items()), "local_fixture_configuration_required")
        hub = urllib.parse.urlsplit(config.get(("agent", "hub_url"), ""))
        require(hub.scheme == "http" and hub.hostname in ("127.0.0.1", "localhost") and hub.port == 4220
                and not hub.username and not hub.password and hub.path in ("", "/") and not hub.query and not hub.fragment,
                "config_loopback_hub_required")
        for path in [self.config, *self.stores]:
            info = pending.private_file(path)
            self.files[path] = info.st_dev, info.st_ino
        require(len(set(self.files.values())) == 4, "distinct_fixture_files_required")
        require(re.fullmatch(r"/tmp/devenv-[a-zA-Z0-9_-]+/postgres", self.socket), "local_postgres_socket_required")
        self.urls = lifecycle.endpoints()
        pending.private_file(self.state_dir / "state.json")
        state = self.fx.read_state(self.state_dir)
        self.expected = {row["name"]: identity(row) for row in state["processes"]}
        require(self.healthy(), "healthy_owned_stack_required")
        self.agent = "memory-local-oct20-a-host-first-" + self.case_id
        self.marker = "MEMORY-LOCAL-oct20-a HOST-FIRST-" + self.case_id
        self.content = self.marker + ": Cold host durable command before gateway arrival."
        baseline = self.direct("list", {"q": self.marker, "limit": 5})
        require(baseline.get("mode") == "online" and baseline.get("results") == [], "fresh_local_marker_required")
        canonical = self.fx.canonical(self, self.bound())
        require(all(canonical[key] == [] for key in ("memory_ids", "events", "sessions", "stages", "jobs")),
                "fresh_canonical_case_required")
        folder = safe_directory(ROOT / ".devenv/memory-local-evidence/oct20-a", create=True)
        self.output = folder / ("host-first-" + self.case_id + "-" + str(time.time_ns()))
        self.output.mkdir(mode=0o700)
        # Keep this reservation even on failure: an accepted local event might not
        # have reached canonical storage when a previous attempt stopped.
        claim = self.state_dir / ("host-first-case-" + self.case_id + ".json")
        fd = os.open(claim, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump({"case_id": self.case_id, "session_id": self.agent}, stream)
        self.report.update(case_id=self.case_id, partition=self.partition, session_id=self.agent,
            original_yaml_sha256=hashlib.sha256(self.original).hexdigest(), source_state="uncommitted task checkout",
            revision=self.fx.revision())
        self.record("preflight", healthy_owned_stack=True, fresh_local_and_canonical_case=True)

    def service(self, name, action):
        self.files_unchanged()
        rows = self.stack()
        require(bool(rows[name].get("stopped")) == (action == "start"), "lifecycle_order_required")
        peer = "host" if name == "gateway" else "gateway"
        peer_identity, prior = self.expected[peer], self.expected[name]
        try:
            self.fx.service(self.state_dir, name, action, self.bound(60))
        except (Exception, KeyboardInterrupt):
            # A timed-out supported start writes its replacement record and then
            # stops/reaps that child. Retain that safe stopped identity for the
            # finally restoration, while refusing a reused PID or occupied group.
            if action == "start":
                state = self.fx.read_state(self.state_dir)
                current = {row["name"]: row for row in state["processes"]}
                row = current[name]
                require(identity(current[peer]) == peer_identity, "peer_identity_changed")
                if identity(row) != prior:
                    require(row.get("uid") == os.getuid() and row.get("pid") == row.get("pgid")
                            and ((row.get("stopped") and self.fx.stopped_empty(row))
                                 or (not row.get("stopped") and self.fx.owns(row))), "service_ownership_lost")
                    self.expected[name] = identity(row)
            raise
        state = self.fx.read_state(self.state_dir)
        row = next(row for row in state["processes"] if row["name"] == name)
        if action == "start":
            require(identity(row) != prior and self.fx.owns(row), "fresh_owned_service_required")
            self.expected[name] = identity(row)
        require(self.expected[peer] == peer_identity, "peer_identity_changed")
        rows = self.stack()
        require(bool(rows[name].get("stopped")) == (action == "stop"), "lifecycle_result_required")
        self.files_unchanged()
        self.record(name + "_" + action, identity=self.expected[name], peer_identity_unchanged=True)

    def gateway_down(self):
        require(self.stack()["gateway"].get("stopped") and not self.fx.reachable(4220)
                and not self.fx.reachable(4221), "gateway_must_remain_unreachable")

    def capture(self, expected):
        status, reply = self.fx.post(self.urls["host"].rstrip("/"), "/capture/v1/hooks/codex/SessionStart",
            self.capture_body, self.bound())
        require(status == 202 and reply.get("ok") is True and reply.get("status") == expected
                and valid_uuid(reply.get("event_id")), "capture_acceptance_required")
        if expected == "accepted":
            self.report.setdefault("acceptance", {})["event_id"] = reply["event_id"]
        self.record("capture_receipt", http_status=status, status=expected, event_id=reply["event_id"])
        return reply["event_id"]

    def owner(self):
        self.stack()
        observation = self.fx.owner_snapshot(self.urls["host"].rstrip("/"), {
            "partition": {key: self.partition[key] for key in ("memory_space_id", "scope", "namespace")},
            "command_ids": [self.local_id], "event_ids": [self.event_id], "mirror_ids": []}, self.bound())
        if observation is None:
            return None
        require(observation.get("observation_source") == "owner_connection", "owner_diagnostics_required")
        return observation

    def settled(self):
        self.files_unchanged()
        require(self.expected["host"] == self.cold_host, "cold_host_identity_changed")
        observation = self.owner()
        if observation is None:
            return False
        rows = observation["commands"]["outbox"]
        capture = observation["capture"]
        if not (len(rows) == 1 and rows[0]["memory_id"] == self.local_id and rows[0]["op"] == "remember"
                and rows[0]["state"] == "done" and valid_uuid(rows[0].get("ack_canonical_id"))
                and type(rows[0].get("ack_revision")) is int and rows[0]["ack_revision"] > 0
                and capture["missing_or_compacted"] == 0 and len(capture["rows"]) == 1
                and capture["rows"][0]["event_id"] == self.event_id
                and capture["rows"][0]["state"] == "acknowledged" and capture["rows"][0]["acknowledged"]):
            return False
        canonical_id = rows[0]["ack_canonical_id"]
        memories = observation["commands"]["memories"]
        require(len(memories) == 1 and memories[0]["id"] == self.local_id
                and memories[0].get("remote_id") == canonical_id and memories[0]["sync_state"] == "synced",
                "command_ack_identity_required")
        data = self.fx.canonical(self, self.bound())
        require(data["memory_ids"] == [canonical_id] and len(data["events"]) == 1
                and data["events"][0]["id"] == self.event_id and data["events"][0]["source_sequence"] == 1
                and data["events"][0]["event_type"] == "agent.session.started", "canonical_exactly_once_required")
        if not (len(data["sessions"]) == 1 and len(data["stages"]) == 1):
            return False
        session, stage = data["sessions"][0], data["stages"][0]
        if not (session["status"] == "active" and session["source_sequence_max"] == 1 and session["gap_count"] == 0
                and re.fullmatch(r"[0-9a-f]{64}", session.get("input_revision") or "")
                and stage["status"] == "complete" and stage["finished"]
                and stage["input_revision"] == session["input_revision"]):
            return False
        jobs = [job for job in data["jobs"] if job["state"] == "completed" and job["finished"] and job["attempt"] >= 1]
        if not jobs:
            return False
        listed = self.direct("list", {"q": self.marker, "limit": 5})
        results = listed.get("results", [])
        if listed.get("mode") != "online":
            return False
        require(len(results) == 1 and pending.recovery.identity(results[0]) == canonical_id
                and results[0].get("content") == self.content, "online_unique_canonical_result_required")
        self.report["settlement"] = {"provisional_id": self.local_id, "canonical_id": canonical_id,
            "event_id": self.event_id, "ack_revision": rows[0]["ack_revision"], "canonical_memories": 1,
            "canonical_events": 1, "session_source_sequence_max": 1, "session_gap_count": 0,
            "input_revision": session["input_revision"], "session_projection_completed": True,
            "completed_normal_styx_job_ids": [job["id"] for job in jobs]}
        return True

    def wait(self, operation, code):
        while not operation():
            require(self.deadline - self.fx.now() > 0.5, code)
            self.fx.sleep(0.5)

    def online_ready(self):
        """Retry only documented startup availability, never schema or authority errors."""
        self.files_unchanged()
        self.stack()
        try:
            # stats advertises an empty schema; injecting scope here is invalid.
            status, reply = self.fx.post(self.urls["host"].rstrip("/"),
                f"/memory/{self.agent}/call/stats", {}, self.bound())
        except urllib.error.URLError as error:
            if isinstance(error.reason, ConnectionRefusedError):
                self.report["cleanup"]["readiness_retries"] = self.report["cleanup"].get("readiness_retries", 0) + 1
                return False
            raise
        if status == 503 and reply.get("ok") is False and reply.get("error") in (
                "canonical memory is unavailable", "canonical memory facade is unavailable"):
            self.report["cleanup"]["readiness_retries"] = self.report["cleanup"].get("readiness_retries", 0) + 1
            return False
        require(status == 200 and reply.get("ok") is True and isinstance(reply.get("result"), dict)
                and reply["result"].get("mode") in ("online", "offline"), "restored_host_http_success_required")
        return reply["result"]["mode"] == "online"

    def restore(self):
        self.report["cleanup"]["attempted"] = True
        self.deadline = self.fx.now() + 180
        self.files_unchanged()
        for name in ("gateway", "host"):
            if self.stack()[name].get("stopped"):
                self.service(name, "start")
        self.wait(self.healthy, "healthy_restoration_timeout")
        self.wait(self.online_ready, "online_restoration_timeout")
        self.files_unchanged()
        self.report["cleanup"].update(verified=True, all_endpoints_ready=True,
            original_yaml_bytes_preserved=True, original_store_identities_preserved=True)

    def execute(self):
        self.disrupted = True
        self.service("gateway", "stop")
        self.gateway_down()
        self.service("host", "stop")
        self.service("host", "start")
        self.cold_host = dict(self.expected["host"])
        self.gateway_down()
        self.write_body = {"content": self.content, "type": "semantic", "idempotency_key": self.agent + ":remember"}
        receipt = self.direct("remember", self.write_body)
        require(valid_uuid(receipt.get("id")) and receipt.get("authority") == "provisional"
                and receipt.get("sync_state") == "pending" and receipt.get("consistency") == "pending_canonical_ack"
                and not receipt.get("canonical_id") and not receipt.get("revision"), "provisional_acceptance_required")
        self.local_id = receipt["id"]
        self.report["acceptance"] = {"provisional_id": self.local_id,
            "request_id": self.write_body["idempotency_key"], "source_event_id": self.agent + ":SessionStart",
            "authority": "provisional", "sync_state": "pending", "consistency": "pending_canonical_ack"}
        self.record("remember_receipt", http_status=200, provisional_id=self.local_id,
            gateway_public_and_admin_unreachable=not self.fx.reachable(4220) and not self.fx.reachable(4221))
        self.capture_body = {"hook_event_name": "SessionStart", "session_id": self.agent, "agent_id": self.agent,
            "cwd": "/synthetic/backplane-memory/oct20-a", "scope": self.partition["scope"],
            "occurred_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "source_event_id": self.agent + ":SessionStart"}
        self.event_id = self.capture("accepted")
        require(self.direct("remember", self.write_body).get("id") == self.local_id
                and self.capture("duplicate") == self.event_id, "offline_retry_identity_required")
        self.gateway_down()
        self.record("durable_before_gateway", provisional_id=self.local_id, event_id=self.event_id,
            gateway_public_and_admin_unreachable=True, duplicate_ids_preserved=True,
            durability_evidence="successful_local_transaction_ack_and_duplicate_identity",
            owner_diagnostics="deferred_until_authenticated_negotiation", independent_store_reopen_tested=False,
            cold_host_identity=self.cold_host)
        self.service("gateway", "start")
        self.wait(self.settled, "automatic_join_and_projection_timeout")
        require(self.direct("remember", self.write_body).get("id") == self.local_id
                and self.capture("duplicate") == self.event_id, "online_retry_identity_required")
        self.wait(self.settled, "post_retry_exactly_once_timeout")
        self.record("automatic_join", host_identity_unchanged=True, no_intervening_host_restart=True,
            normal_worker_session_projection_ready=True)
        self.restore()
        self.report.update(status="passed-cold-host-first-subset", complete_L01=True)

    def run(self):
        try:
            self.preflight()
            self.execute()
        except (Exception, KeyboardInterrupt) as error:
            self.report["failure"] = str(error) if isinstance(error, CheckFailed) else "host_first_operation_failed"
        finally:
            if self.disrupted and not self.report["cleanup"]["verified"]:
                handlers = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
                try:
                    for number in handlers:
                        signal.signal(number, signal.SIG_IGN)
                    require(not self.report["cleanup"]["attempted"], "restoration_already_attempted")
                    self.restore()
                except (Exception, KeyboardInterrupt):
                    self.report["cleanup"]["failure"] = "RESTORATION_NOT_PROVEN"
                    self.report["status"] = "failed"
                finally:
                    for number, handler in handlers.items():
                        signal.signal(number, handler)
            self.report["elapsed_ms"] = round((self.fx.now() - self.started) * 1000)
            self.save()
        return self.report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, default=ROOT / ".devenv/memory-local-fixtures/oct20-a/fixture.json")
    parser.add_argument("--state-dir", type=Path, default=ROOT / ".devenv/memory-local")
    parser.add_argument("--case-id", required=True, help="fresh lowercase case; retained reservations cannot be reused")
    parser.add_argument("--timeout", type=int, default=240, help="120-360 seconds, plus bounded failure restoration")
    parser.add_argument("--socket", default="/tmp/devenv-e733526/postgres")
    args = parser.parse_args()
    def interrupted(_number, _frame):
        raise CheckFailed("interrupted")
    for number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(number, interrupted)
    runner = Runner(args.fixture, args.state_dir, args.case_id, timeout=args.timeout, socket=args.socket)
    report = runner.run()
    print(json.dumps({"status": report["status"], "failure": report.get("failure"),
        "cleanup": report["cleanup"], "report": str(runner.output / "report.json") if runner.output else None}))
    return 0 if report["status"] == "passed-cold-host-first-subset" else 1


if __name__ == "__main__":
    raise SystemExit(main())
