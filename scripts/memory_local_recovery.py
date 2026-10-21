#!/usr/bin/env python3
"""Run owned local HTTP recovery subsets; live services are changed only on explicit invocation.

Requires the primary fixture and an already running memory_local_dev.py-owned stack.
This is not full L10-L12 qualification: stalled transports, interrupted snapshots,
browser agreement, and canonical replay/rebuild need separate controlled checks.
"""

import argparse
import contextlib
import datetime
import importlib.util
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("memory_local_dev", Path(__file__).with_name("memory_local_dev.py"))
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)


class CheckFailed(RuntimeError):
    """A fixed, nonsecret check code, never a raw provider or lifecycle error."""


def require(condition, code):
    if not condition:
        raise CheckFailed(code)


def identity(row):
    return row.get("canonical_id") or row.get("id")


def safe_reply(reply):
    """Allowlist response metadata; never persist content, envelopes, tokens or error strings."""
    if not isinstance(reply, dict):
        return {}
    safe = {}
    enums = {
        "mode": {"online", "offline"},
        "source": {"edge_mirror", "acknowledged_commands", "provisional_commands"},
        "authority": {"canonical", "provisional", "canonical_with_provisional"},
        "consistency": {"canonical", "pending_canonical_ack", "read_your_writes", "bounded_stale", "provisional_only"},
        "sync_state": {"pending", "synced", "failed"},
        "status": {"accepted", "duplicate", "pending", "acknowledged", "done"},
    }
    for key, values in enums.items():
        if isinstance(reply.get(key), str) and reply[key] in values:
            safe[key] = reply[key]
    for key in ("ok", "stale", "history_available", "overlay_truncated"):
        if type(reply.get(key)) is bool:
            safe[key] = reply[key]
    for key in ("pending_operations", "acknowledged_operations", "partition_revision", "revision"):
        if type(reply.get(key)) is int:
            safe[key] = reply[key]
    for key in ("id", "canonical_id", "event_id", "memory_space_id"):
        value = reply.get(key)
        if isinstance(value, str):
            try:
                uuid.UUID(value.removeprefix("canonical:"))
                safe[key] = value
            except ValueError:
                pass
    if isinstance(reply.get("result"), dict):
        safe["result"] = safe_reply(reply["result"])
    for key in ("items", "results"):
        if isinstance(reply.get(key), list):
            safe[key] = [safe_reply(row) for row in reply[key][:50]]
    return safe


@contextlib.contextmanager
def read_only(path):
    """Open existing plaintext development SQLite stores without creating or modifying them."""
    path = Path(path).resolve(strict=True)
    with contextlib.closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=5)) as connection:
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA query_only=ON")
        connection.execute("BEGIN")
        yield connection


def store_probe(operation, request, timeout=8):
    """Kill and reap a hung SQLite reader; busy_timeout cannot bound native hangs."""
    require(operation in ("commands", "capture", "mirror"), "store_probe_operation")
    try:
        result = subprocess.run([sys.executable, "-I", str(Path(__file__).resolve()), "--store-probe", operation],
                                input=json.dumps(request), text=True, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise CheckFailed("store_probe_timeout") from None
    require(result.returncode == 0 and len(result.stdout) <= 200_000, "store_probe_failed")
    reply = json.loads(result.stdout)
    require(isinstance(reply, dict), "store_probe_shape")
    return reply


def command_snapshot(path, ids, scope, hashes=()):
    return store_probe("commands", {"path": str(path), "ids": sorted(ids), "scope": scope, "hashes": sorted(hashes)})


def probe_commands(path, ids, scope, hashes=()):
    ids = sorted(set(ids))
    require(0 < len(ids) <= 32, "command_identity_bound")
    targets = sorted(set(ids + ["canonical:" + value for value in ids]))
    marks = ",".join("?" for _ in targets)
    with read_only(path) as connection:
        outbox = [dict(row) for row in connection.execute(
            "SELECT seq,op,memory_id,state,attempts,ack_canonical_id,ack_revision FROM memory_outbox "
            f"WHERE memory_id IN ({marks}) ORDER BY seq LIMIT 100", targets)]
        memories = [dict(row) for row in connection.execute(
            "SELECT id,remote_id,sync_state,deleted_at IS NOT NULL AS deleted,content_hash FROM memories "
            f"WHERE id IN ({marks}) OR remote_id IN ({marks}) LIMIT 32", targets + targets)]
        for memory in memories:
            memory["deleted"] = bool(memory["deleted"])
        hashes = sorted(set(hashes) | {row["content_hash"] for row in memories})
        tombstones = 0
        if hashes:
            placeholders = ",".join("?" for _ in hashes)
            tombstones = connection.execute(
                f"SELECT count(*) FROM tombstones WHERE scope=? AND content_hash IN ({placeholders})",
                [scope] + hashes).fetchone()[0]
    return {"outbox": outbox, "memories": memories, "tombstones": tombstones}


def probe_capture(path, ids):
    require(len(ids) <= 32, "capture_identity_bound")
    with read_only(path) as connection:
        marks = ",".join("?" for _ in ids)
        rows = [dict(row) for row in connection.execute(
            f"SELECT event_id,state,attempts,acknowledged_at IS NOT NULL AS acknowledged FROM capture_event_spool WHERE event_id IN ({marks}) ORDER BY enqueue_id LIMIT 32", ids)] if ids else []
    return {"rows": rows, "expected": len(ids), "missing_or_compacted": len(set(ids) - {row["event_id"] for row in rows})}


def probe_mirror(path, partition, ids):
    require(len(partition) == 3 and len(ids) <= 32, "mirror_identity_bound")
    with read_only(path) as connection:
        row = connection.execute("SELECT applied_revision,active_generation,snapshot_id,snapshot_revision,sync_status FROM edge_partitions WHERE memory_space_id=? AND scope=? AND namespace=?", partition).fetchone()
        mirror = dict(row) if row else None
        active_ids = []
        if mirror and ids:
            marks = ",".join("?" for _ in ids)
            active_ids = [row[0] for row in connection.execute(
                "SELECT canonical_id FROM edge_memories WHERE memory_space_id=? AND scope=? AND namespace=? AND generation=? AND lifecycle_state='active' "
                f"AND canonical_id IN ({marks}) ORDER BY canonical_id LIMIT 32",
                partition + [mirror["active_generation"]] + ids)]
    return {"partition": mirror, "active_target_ids": active_ids}


def target_aliases(snapshot, target):
    """Follow durable local-to-canonical identities so a remapped delete cannot pass."""
    aliases = {target.removeprefix("canonical:")}
    commands = snapshot["commands"]
    links = [(row["memory_id"], row.get("ack_canonical_id")) for row in commands["outbox"]]
    links += [(row["id"], row.get("remote_id")) for row in commands["memories"]]
    for _ in range(len(links) + 1):
        previous = set(aliases)
        for left, right in links:
            pair = {value.removeprefix("canonical:") for value in (left, right) if value}
            if pair & aliases:
                aliases.update(pair)
        if aliases == previous:
            return aliases
    raise CheckFailed("identity_resolution_bound")


def require_delete_fence(snapshot, target):
    aliases = target_aliases(snapshot, target)
    commands = snapshot["commands"]
    require(any(row["op"] == "forget" and row["memory_id"].removeprefix("canonical:") in aliases
                for row in commands["outbox"]) or
            any(row["id"].removeprefix("canonical:") in aliases and row["deleted"]
                for row in commands["memories"]), "durable_delete_fence")


def require_mirror(result, canonical_id, minimum_revision):
    require(result.get("mode") == "offline" and result.get("source") == "edge_mirror" and
            result.get("consistency") == "bounded_stale" and result.get("history_available") is True and
            type(result.get("partition_revision")) is int and result["partition_revision"] >= minimum_revision and
            any(identity(row) == canonical_id for row in result.get("results", [])), "actual_edge_mirror")


class Recovery:
    def __init__(self, fixture, state_dir, host_url, timeout, case_id, database, socket):
        self.fixture_path = Path(fixture).resolve(strict=True)
        self.fixture = json.loads(self.fixture_path.read_text())
        self.run_id = self.fixture["run_id"]
        require(bool(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}", self.run_id)), "fixture_run_id")
        require(bool(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,39}", case_id)), "case_id")
        require(0 < timeout <= 900, "timeout_bound")
        parsed = urllib.parse.urlparse(host_url)
        require(parsed.scheme == "http" and parsed.hostname in ("localhost", "127.0.0.1", "::1") and
                parsed.username is None and parsed.password is None and not parsed.query and
                not parsed.fragment and parsed.path in ("", "/"), "loopback_host_url")
        self.case_id, self.timeout = case_id, timeout
        self.state_dir, self.host_url = Path(state_dir).resolve(), host_url.rstrip("/")
        self.host_config = Path(self.fixture["hosts"][0]["config"]).resolve(strict=True)
        self.partition = self.fixture["hosts"][0]["partition"]
        uuid.UUID(self.partition["memory_space_id"])
        self.scope = self.partition["scope"]
        self.agent = "memory-local-" + self.run_id + "-recovery-" + case_id
        self.marker = "MEMORY-RECOVERY-" + self.run_id + "-" + case_id
        self.output = ROOT / ".devenv/memory-local-evidence" / self.run_id
        self.output.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.database, self.socket = database, socket
        self.observations, self.ids, self.hashes, self.captures = [], set(), set(), {}
        self.phase = "preflight"

    def preflight(self):
        state = lifecycle.read_state(self.state_dir)
        require(Path(state["config"]).resolve() == self.host_config and
                state["urls"]["host"].rstrip("/") == self.host_url, "fixture_lifecycle_mismatch")
        records = state["processes"]
        require({row["name"] for row in records} == {"gateway", "host"} and
                all(not row.get("stopped") and lifecycle.owns(row) for row in records), "owned_stack_running")
        self.stores = {"commands": self.host_config.parent / "commands.db",
                       "capture": self.host_config.parent / "capture-spool.db",
                       "mirror": self.host_config.parent / "mirror.db"}
        require(all(path.is_file() for path in self.stores.values()), "prepared_fixture_stores")
        self.record("preflight", {"owned": True, "primary_fixture": True})

    def record(self, kind, detail):
        require(len(self.observations) < 3000, "observation_bound")
        self.observations.append({"kind": kind, "elapsed_at": time.monotonic(), **detail})

    def post(self, path, body):
        request = urllib.request.Request(self.host_url + path, data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"}, method="POST")
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=min(20, self.timeout)) as response:
                status, raw = response.status, response.read(1_000_001)
        except urllib.error.HTTPError as error:
            status, raw = error.code, error.read(1_000_001)
        require(len(raw) <= 1_000_000, "http_response_bound")
        reply = json.loads(raw)
        self.record("http", {"method": path.rsplit("/", 1)[-1], "status": status,
                             "elapsed_ms": round((time.monotonic() - started) * 1000),
                             "response": safe_reply(reply)})
        require(status in (200, 202), "host_http_status")
        require(isinstance(reply, dict) and reply.get("ok") is True, "host_http_success")
        return reply

    def direct(self, method, args):
        reply = self.post(f"/memory/{self.agent}/call/{method}", {"scope": self.scope, **args})
        require(isinstance(reply.get("result"), dict), "host_result_shape")
        return reply["result"]

    def wait(self, code, operation):
        deadline = time.monotonic() + self.timeout
        while True:
            result = operation()
            if result:
                return result
            require(time.monotonic() < deadline, code)
            time.sleep(0.5)

    def service(self, name, action):
        self.record("lifecycle_requested", {"service": name, "action": action})
        self.save(self.phase, "running")
        lifecycle.service(self.state_dir, name, action, timeout=self.timeout)
        self.record("lifecycle_completed", {"service": name, "action": action})

    @contextlib.contextmanager
    def outage(self):
        self.service("gateway", "stop")
        try:
            yield
        finally:
            self.service("gateway", "start")

    def write(self, label):
        content = self.marker + ": " + label + " preserves bounded durable recovery evidence."
        args = {"content": content, "type": "semantic", "idempotency_key": self.agent + ":" + label}
        reply = self.direct("remember", args)
        require(isinstance(reply.get("id"), str), "write_identity")
        self.ids.add(reply["id"])
        return reply, args

    def listing(self):
        return self.direct("list", {"q": self.marker, "limit": 50})

    def settled(self, args):
        def check():
            result = self.listing()
            require(isinstance(result.get("items"), list), "list_items_shape")
            matches = [row for row in result["items"] if row.get("content") == args["content"]]
            if result.get("mode") == "online" and result.get("pending_operations") == 0 and len(matches) == 1:
                row = matches[0]
                self.ids.add(identity(row))
                return row
            return None
        return self.wait("canonical_settlement_timeout", check)

    def snapshot(self, label):
        commands = command_snapshot(self.stores["commands"], self.ids, self.scope, self.hashes)
        self.hashes.update(row["content_hash"] for row in commands["memories"])
        capture_ids = [event_id for rows in self.captures.values() for event_id in rows]
        capture = store_probe("capture", {"path": str(self.stores["capture"]), "ids": capture_ids})
        partition = [self.partition[key] for key in ("memory_space_id", "scope", "namespace")]
        mirror = store_probe("mirror", {"path": str(self.stores["mirror"]), "partition": partition, "ids": sorted(self.ids)})
        result = {"label": label, "commands": commands, "capture": capture["rows"],
                  "capture_missing_or_compacted": capture["missing_or_compacted"],
                  "mirror": mirror["partition"], "active_target_ids": mirror["active_target_ids"]}
        self.record("durable_snapshot", result)
        self.save(self.phase, "running")
        return result

    def warm(self, label):
        _, args = self.write(label)
        canonical = identity(self.settled(args))
        def check():
            snapshot = self.snapshot("mirror_warm")
            if canonical in snapshot["active_target_ids"] and snapshot["mirror"]["snapshot_id"] is None:
                return snapshot["mirror"]["applied_revision"]
            return None
        return canonical, self.wait("mirror_warm_timeout", check)

    def recall_mirror(self, canonical, revision):
        result = self.direct("recall", {"query": self.marker, "limit": 20})
        require_mirror(result, canonical, revision)

    def capture(self, label):
        session = self.agent + "-" + label
        events = [("SessionStart", {}), ("UserPromptSubmit", {"prompt": self.marker + " recovery probe"}),
                  ("Stop", {"message": self.marker + " durable upload verified"}), ("SessionEnd", {"reason": "completed"})]
        ids = []
        for index, (hook, extra) in enumerate(events):
            body = {"hook_event_name": hook, "session_id": session, "agent_id": self.agent,
                    "cwd": "/synthetic/backplane-memory/" + self.run_id, "scope": self.scope,
                    "occurred_at": self.fixture["prepared_at"],
                    "source_event_id": session + ":" + str(index), **extra}
            first = self.post("/capture/v1/hooks/codex/" + hook, body)
            second = self.post("/capture/v1/hooks/codex/" + hook, body)
            require(first.get("event_id") and second.get("status") == "duplicate" and
                    first["event_id"] == second.get("event_id"), "capture_duplicate_identity")
            ids.append(first["event_id"])
        require(session not in self.captures or self.captures[session] == ids, "capture_restart_identity")
        self.captures[session] = ids

    def pending(self, snapshot):
        require(any(row["state"] in ("pending", "inflight", "retry_wait") for row in snapshot["commands"]["outbox"]), "durable_pending_command")
        pending = [row for row in snapshot["capture"] if not row["acknowledged"]]
        require(pending and all(row["state"] == "pending" for row in pending), "durable_pending_capture")

    def drained(self):
        def check():
            snapshot = self.snapshot("settlement")
            rows = snapshot["commands"]["outbox"]
            if rows and all(row["state"] == "done" and (row["ack_revision"] or 0) > 0 for row in rows) and all(row["state"] == "acknowledged" for row in snapshot["capture"]):
                return snapshot
            return None
        result = self.wait("durable_queue_drain_timeout", check)
        if self.captures:
            psql = shutil.which("psql") or str(ROOT / ".devenv/profile/bin/psql")
            # Sessions contain only validated fixture/case IDs and fixed suffixes.
            sessions = ",".join("'" + value + "'" for value in self.captures)
            space = str(uuid.UUID(self.partition["memory_space_id"]))
            sql = f"BEGIN READ ONLY; SET LOCAL statement_timeout='5s'; SELECT coalesce(json_agg(id::text),'[]'::json) FROM bpm_events WHERE memory_space_id='{space}'::uuid AND session_id IN ({sessions}); COMMIT;"
            reply = subprocess.run([psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-h", self.socket, "-d", self.database], input=sql, text=True, capture_output=True, timeout=15)
            require(reply.returncode == 0 and len(reply.stdout) < 10000, "canonical_capture_query")
            ids = json.loads(reply.stdout)
            expected = [value for values in self.captures.values() for value in values]
            require(len(ids) == len(expected) and set(ids) == set(expected), "canonical_capture_exactly_once")
            self.record("canonical_capture", {"event_ids": ids, "exactly_once": True})
        return result

    def absent(self, target, snapshot=None):
        aliases = target_aliases(snapshot, target) if snapshot else {target.removeprefix("canonical:")}
        for method, args in (("list", {"q": self.marker, "limit": 50}), ("recall", {"query": self.marker, "limit": 20})):
            reply = self.direct(method, args)
            key = "items" if method == "list" else "results"
            require(isinstance(reply.get(key), list), "memory_rows_shape")
            require(all(identity(row).removeprefix("canonical:") not in aliases for row in reply[key]), "forgotten_memory_visible")

    def outage_scenario(self):
        canonical, revision = self.warm("outage-survivor")
        with self.outage():
            self.recall_mirror(canonical, revision)
            accepted, args = self.write("outage-pending")
            require(accepted.get("authority") == "provisional" and accepted.get("sync_state") == "pending", "offline_provisional_acceptance")
            self.capture("outage")
            self.pending(self.snapshot("gateway_offline"))
        self.settled(args)
        self.drained()
        repeated = self.direct("remember", args)
        require(repeated.get("id") == accepted["id"], "command_retry_identity")

    def restart_scenario(self):
        canonical, revision = self.warm("restart-survivor")
        deleted, _ = self.warm("restart-delete")
        with self.outage():
            _, args = self.write("restart-pending")
            self.capture("restart")
            self.direct("forget", {"id": deleted})
            before = self.snapshot("before_host_restart")
            self.pending(before)
            require_delete_fence(before, deleted)
            self.service("host", "restart")
            self.recall_mirror(canonical, revision)
            self.absent(deleted)
            self.capture("restart")
            after = self.snapshot("after_host_restart")
            self.pending(after)
            require_delete_fence(after, deleted)
            require({(row["seq"], row["op"], row["memory_id"]) for row in before["commands"]["outbox"]} <=
                    {(row["seq"], row["op"], row["memory_id"]) for row in after["commands"]["outbox"]}, "restart_outbox_survival")
            require(after["mirror"]["applied_revision"] >= revision, "restart_cursor_survival")
            if before["commands"]["tombstones"] > 0:
                require(after["commands"]["tombstones"] >= before["commands"]["tombstones"], "restart_tombstone_survival")
            self.record("restart_delete_fence", {"durable": True, "positive_tombstone_observed": before["commands"]["tombstones"] > 0})
        self.settled(args)
        self.drained()
        self.absent(deleted)

    def forget_scenario(self):
        online, _ = self.warm("forget-online")
        self.direct("forget", {"id": online})
        self.drained()
        self.absent(online)
        offline, _ = self.warm("forget-offline")
        with self.outage():
            pending, _ = self.write("forget-before-settlement")
            self.direct("forget", {"id": pending["id"]})
            self.direct("forget", {"id": offline})
            self.absent(pending["id"])
            self.absent(offline)
            snapshot = self.snapshot("forget_before_settlement")
            require(any(row["id"] == pending["id"] and row["deleted"] for row in snapshot["commands"]["memories"]), "pending_delete_durable")
            self.service("host", "restart")
            self.absent(pending["id"])
            self.absent(offline)
        settled = self.drained()
        self.service("host", "restart")
        self.wait("post_restart_online_timeout", lambda: self.listing().get("mode") == "online")
        for target in (online, offline, pending["id"]):
            self.absent(target, settled)
        self.snapshot("forget_after_reconnect_restart")

    def save(self, phase, status, failed_check=None):
        report = {"run_id": self.run_id, "case_id": self.case_id, "phase": phase, "status": status,
                  "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                  "evidence_level": "live-http-and-read-only-store-subset", "complete_L10_L12": False,
                  "failed_check": failed_check,
                  "unexercised": ["stalled request", "deliberately interrupted snapshot", "browser agreement", "canonical replay/rebuild"],
                  "observations": self.observations}
        path = self.output / f"recovery-{phase}-{self.case_id}-{time.time_ns()}.json"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(report, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        return path


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--store-probe":
        try:
            request = json.loads(sys.stdin.read(20_001))
            probes = {"commands": probe_commands, "capture": probe_capture, "mirror": probe_mirror}
            print(json.dumps(probes[sys.argv[2]](**request)))
            return 0
        except Exception:
            return 1
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("outage", "restart", "forget", "all"))
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, default=ROOT / ".devenv/memory-local")
    parser.add_argument("--host-url", default="http://127.0.0.1:4222")
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--case-id", default=uuid.uuid4().hex[:12], help="use a new case ID for an independent retained-state run")
    parser.add_argument("--database", default="backplane_dev")
    parser.add_argument("--socket", default="/tmp/devenv-e733526/postgres")
    args = parser.parse_args()
    run = None
    try:
        run = Recovery(args.fixture, args.state_dir, args.host_url, args.timeout, args.case_id, args.database, args.socket)
        run.preflight()
        for phase in (("outage", "restart", "forget") if args.phase == "all" else (args.phase,)):
            run.phase = phase
            getattr(run, phase + "_scenario")()
            print(run.save(phase, "passed-subset"))
        return 0
    except Exception as error:
        # Deliberately exclude exception messages: network/storage/lifecycle errors
        # are not trusted to contain only nonsecret data.
        if run is not None:
            code = str(error) if isinstance(error, CheckFailed) else type(error).__name__
            print(run.save(run.phase, "failed", code))
        else:
            print("Recovery initialization failed; no service action performed.")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
