#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["playwright==1.56.0"]
# ///
"""Observe bounded L12/L14 governance on an existing synthetic captured session.

run forgets one selected derived fact, heals its summary through the Admin form,
and duplicates one unrelated late Codex hook. checkpoint is read-only: use it
after a parent-owned targeted rebuild. This script never starts Mix, changes
settings, invokes workers directly, or claims complete L01-L18 acceptance.
"""

import argparse
import datetime
import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import time
import urllib.parse
from pathlib import Path

from memory_local_core_parity import CheckFailed, Effects, require, safe_receipt, valid_uuid


ROOT = Path(__file__).resolve().parents[1]
PARTITION_KEYS = ("memory_space_id", "host_id", "client_id", "scope", "namespace")
LIMITS = {"session": 1, "events": 256, "frontier": 1, "stages": 16,
          "summaries": 64, "summary_sources": 1024, "memories": 128,
          "evidence": 1024, "requests": 256, "crystals": 16,
          "crystal_events": 1024, "crystal_summaries": 128,
          "nodes": 128, "edges": 256, "jobs": 128, "candidates": 32}


def private_json(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and not path.is_symlink()
            and info.st_uid == os.getuid() and not info.st_mode & 0o077
            and info.st_size <= 4_000_000, "private_input_required")
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW)) as stream:
        opened = os.fstat(stream.fileno())
        require((info.st_dev, info.st_ino) == (opened.st_dev, opened.st_ino), "input_identity_changed")
        return json.load(stream)


def selected_partition(fixture, session, target_id):
    run_id = fixture.get("run_id")
    require(isinstance(run_id, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}", run_id), "fixture_run_id_invalid")
    require(isinstance(session, str) and session.startswith("memory-local-" + run_id + "-")
            and len(session.encode("utf-8")) <= 512 and not any(ord(c) < 32 for c in session),
            "synthetic_captured_session_required")
    require(valid_uuid(target_id), "canonical_target_id_required")
    host = fixture["hosts"][0]
    partition = {key: host["partition"][key] for key in PARTITION_KEYS}
    require(all(valid_uuid(partition[key]) for key in ("memory_space_id", "host_id"))
            and host["host_id"] == partition["host_id"]
            and partition["client_id"] == "host:" + partition["host_id"]
            and partition["scope"] == "memory_local_" + run_id + "_primary"
            and partition["namespace"] == "private", "primary_fixture_partition_required")
    return partition


def partition_sql(alias, client=True):
    keys = PARTITION_KEYS if client else ("memory_space_id", "host_id", "scope", "namespace")
    return " AND ".join(alias + "." + key + "=:'" + key + "'" + ("::uuid" if key == "memory_space_id" else "")
                        for key in keys)


def snapshot_sql():
    # All substitutions are psql quoted variables. Only fixed allowlisted SELECTs
    # run inside one READ ONLY transaction; no raw envelopes, errors or keys.
    session = partition_sql("s") + " AND s.session_id=:'session'"
    event = partition_sql("e") + " AND e.session_id=:'session' AND e.schema_version IS NOT NULL"
    memory = partition_sql("m")
    summary = partition_sql("s", client=False) + " AND s.session_id=:'session'"
    ctes = {
        "selected": "SELECT s.* FROM bpm_projected_sessions s WHERE " + session,
        "source": "SELECT e.* FROM bpm_events e WHERE " + event,
        "summaries_all": "SELECT s.* FROM memory_summaries s WHERE " + summary,
        "target": "SELECT m.* FROM bpm_memories m WHERE " + memory + " AND m.id=:'target_id'::uuid",
        "facts": "SELECT m.* FROM bpm_memories m WHERE " + memory + " AND (m.session_id=:'session' OR m.id=:'target_id'::uuid)",
        "crystals_all": "SELECT c.* FROM memory_crystals c WHERE " + partition_sql("c") + " AND c.source_session_id=:'session' AND c.source_kind='session'",
        "nodes_all": "SELECT n.* FROM memory_graph_nodes n WHERE " + partition_sql("n") + " AND n.source_observation_ids && ARRAY(SELECT id FROM source)",
    }
    queries = {
        "session": "SELECT subject_id, session_id, project, agent_id, integration, source_client_id, status, source_sequence_max, gap_count, input_revision FROM selected",
        "events": "SELECT id, sequence, source_sequence, event_type, integration, occurred_at, payload_hash FROM source ORDER BY source_sequence,id",
        "frontier": "SELECT f.requested_generation,f.requested_revision,f.inflight_generation,f.inflight_revision,f.completed_generation,f.completed_revision FROM bpm_projection_repair_frontiers f JOIN selected s ON s.host_id=f.host_id AND s.session_id=f.session_id",
        "stages": "SELECT p.projector,p.processing_version,p.input_revision,p.output_revision,p.status,p.attempt_count,p.last_error IS NOT NULL AS has_error,p.completed_at FROM bpm_projection_states p JOIN selected s ON s.subject_id=p.subject_id WHERE " + partition_sql("p", client=False) + " AND p.subject_type='captured_session' ORDER BY p.projector,p.processing_version",
        "summaries": "SELECT id,input_revision,output_revision,processing_version,source_complete,source_gap_count,superseded_at,encode(sha256(convert_to(content,'UTF8')),'hex') AS content_hash FROM summaries_all ORDER BY created_at,id",
        "summary_sources": "SELECT l.summary_id,l.event_id FROM memory_summary_source_events l JOIN summaries_all s ON s.id=l.summary_id ORDER BY l.summary_id,l.event_id",
        "memories": "SELECT id,memory_type,lifecycle_state,deleted_at,encode(content_hash,'hex') AS content_hash,CASE WHEN id=:'target_id'::uuid THEN content END AS target_content FROM facts ORDER BY id",
        "evidence": "SELECT e.id,e.memory_id,e.source_event_id,e.source_summary_id,e.source_session_id,e.source_request_id,e.evidence_kind FROM bpm_memory_evidence e JOIN facts m ON m.id=e.memory_id ORDER BY e.id",
        "requests": "SELECT r.id,r.memory_id,r.idempotency_scope,encode(r.request_hash,'hex') AS request_hash FROM bpm_memory_remember_requests r JOIN target m ON m.id=r.memory_id WHERE r.idempotency_scope='memory-worker:episodic' ORDER BY r.id",
        "crystals": "SELECT id,memory_id,input_revision,output_revision,processing_version,status,model FROM crystals_all ORDER BY id",
        "crystal_events": "SELECT l.crystal_id,l.event_id FROM memory_crystal_source_events l JOIN crystals_all c ON c.id=l.crystal_id ORDER BY l.crystal_id,l.event_id",
        "crystal_summaries": "SELECT l.crystal_id,l.summary_id FROM memory_crystal_source_summaries l JOIN crystals_all c ON c.id=l.crystal_id ORDER BY l.crystal_id,l.summary_id",
        "nodes": "SELECT id,source_observation_ids FROM nodes_all ORDER BY id",
        "edges": "SELECT e.id,e.source_id,e.target_id FROM memory_graph_edges e WHERE " + partition_sql("e") + " AND e.source_id IN (SELECT id FROM nodes_all) AND e.target_id IN (SELECT id FROM nodes_all) ORDER BY e.id",
        "jobs": "SELECT j.id,j.worker,j.state,j.attempt,j.completed_at,j.args->>'input_revision' AS input_revision,j.args->>'summary_id' AS summary_id FROM styx_jobs j WHERE (j.args->>'memory_space_id'=:'memory_space_id' AND j.args->>'host_id'=:'host_id' AND j.args->>'scope'=:'scope' AND j.args->>'namespace'=:'namespace' AND j.args->>'session_id'=:'session') OR j.args->>'summary_id' IN (SELECT id::text FROM summaries_all) ORDER BY j.id DESC",
        "candidates": "SELECT m.id,m.lifecycle_state,m.deleted_at FROM bpm_memories m JOIN target t ON m.content_hash=t.content_hash AND m.memory_type=t.memory_type AND coalesce(m.metadata->>'project','')=coalesce(t.metadata->>'project','') WHERE " + memory + " ORDER BY m.id",
    }
    pairs = []
    for key, select in queries.items():
        pairs.append("'" + key + "',coalesce((SELECT json_agg(row_to_json(q)) FROM (" + select
                     + " LIMIT " + str(LIMITS[key] + 1) + ") q),'[]'::json)")
    return "WITH " + ",\n".join(key + " AS (" + value + ")" for key, value in ctes.items()) + "\nSELECT json_build_object(" + ",\n".join(pairs) + ");"


def target_row(snapshot, target_id):
    rows = [row for row in snapshot["memories"] if row["id"] == target_id]
    require(len(rows) == 1, "selected_target_missing")
    return rows[0]


def current_summary(snapshot):
    rows = [row for row in snapshot["summaries"] if row["processing_version"] == "summary-v1"
            and row["superseded_at"] is None]
    require(len(rows) == 1, "current_summary_required")
    return rows[0]


def artifact_ids(snapshot):
    return {"facts": sorted(row["id"] for row in snapshot["memories"] if row["memory_type"] == "semantic"),
            "crystals": sorted(row["id"] for row in snapshot["crystals"]),
            "nodes": sorted(row["id"] for row in snapshot["nodes"]),
            "edges": sorted(row["id"] for row in snapshot["edges"])}


def new_worker_completions(snapshot, original):
    old_ids = {row["id"] for row in original["jobs"]}
    return {row["worker"].rsplit(".", 1)[-1] for row in snapshot["jobs"]
            if row["id"] not in old_ids and row["state"] == "completed"}


def derived_ready(snapshot, revision):
    summary = current_summary(snapshot)
    crystals = [row for row in snapshot["crystals"] if row["processing_version"] == "crystal-v1"]
    stages = {row["projector"]: row for row in snapshot["stages"]}
    required = ("observations", "session", "activity", "replay", "summary", "episodic", "crystal", "graph")
    return (summary["input_revision"] == revision and summary["source_complete"] is True
            and summary["source_gap_count"] == 0
            and all(name in stages and stages[name]["status"] == "complete"
                    and stages[name]["input_revision"] == revision for name in required)
            and stages["summary"]["output_revision"] == summary["output_revision"]
            and stages["episodic"]["output_revision"] == summary["output_revision"]
            and bool(crystals) and all(row["status"] == "complete" and row["input_revision"] == revision
                                      for row in crystals)
            and bool(snapshot["nodes"]))


def assert_governed(snapshot, original, target_id):
    target = target_row(snapshot, target_id)
    require(target["content_hash"] == target_row(original, target_id)["content_hash"]
            and target["deleted_at"] is not None and target["lifecycle_state"] == "tombstoned",
            "original_hash_tombstone_required")
    require(not any(row["deleted_at"] is None for row in snapshot["candidates"]), "same_candidate_resurrected")
    old_evidence = {row["id"] for row in original["evidence"] if row["memory_id"] == target_id}
    evidence = {row["id"] for row in snapshot["evidence"] if row["memory_id"] == target_id}
    require(evidence == old_evidence, "tombstone_evidence_changed")
    require({row["id"] for row in original["events"]} <= {row["id"] for row in snapshot["events"]}, "original_source_lost")
    require({row["id"] for row in original["summaries"]} <= {row["id"] for row in snapshot["summaries"]}, "historical_summary_lost")
    return {"original_hash_tombstoned": True, "same_hash_active_candidates": 0,
            "original_evidence_preserved": True,
            "new_worker_requests_to_original_tombstone": sorted({r["id"] for r in snapshot["requests"]}
                                                                  - {r["id"] for r in original["requests"]})}


class Governance:
    def __init__(self, args):
        self.args, self.fx = args, Effects()
        self.deadline = time.monotonic() + args.timeout
        self.sequence, self.forget_attempted = 0, False
        self.report = {"status": "failed", "evidence_level": "live-local-governance-subset",
                       "complete_L12": False, "complete_L14": False, "complete_L01_L18": False,
                       "observations": [], "snapshots": {}, "limits": [
                           "Exact candidate identity uses content hash; paraphrases are not suppressed by this contract.",
                           "Whole-session source evidence is not fact-level attribution.",
                           "No forced stale-worker race, full live-update/navigation qualification, or cross-machine validation."]}

    def remaining(self):
        seconds = self.deadline - time.monotonic()
        require(seconds > 0, "bounded_wait_expired")
        return seconds

    def preflight(self):
        require(math.isfinite(self.args.timeout) and 30 <= self.args.timeout <= 900, "timeout_bound_required")
        require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,39}", self.args.case_id or ""), "case_id_required")
        fixture = private_json(self.args.fixture)
        self.partition = selected_partition(fixture, self.args.session, self.args.target_id)
        parsed = urllib.parse.urlsplit(self.args.host_url)
        require(parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost", "::1")
                and parsed.port == 4222 and not parsed.username and not parsed.password
                and parsed.path in ("", "/") and not parsed.query and not parsed.fragment,
                "primary_loopback_host_required")
        require(self.args.database == "backplane_dev" and self.args.socket.startswith("/")
                and "\x00" not in self.args.socket, "local_dev_database_required")
        self.agent = "memory-local-" + fixture["run_id"]
        self.report.update(run_id=fixture["run_id"], session=self.args.session, target_id=self.args.target_id,
                           partition=self.partition, case_id=self.args.case_id, phase=self.args.phase,
                           source_revision=self.fx.revision())
        if self.args.phase == "checkpoint":
            require(self.args.checkpoint is not None, "checkpoint_report_required")
            self.previous = private_json(self.args.checkpoint)
            require(all(self.previous.get(key) == self.report[key]
                        for key in ("run_id", "session", "target_id", "partition", "case_id"))
                    and self.previous.get("status") == "observed-subset"
                    and self.previous.get("phase") == "run", "checkpoint_selection_mismatch")
        else:
            require(self.args.checkpoint is None, "checkpoint_only_for_checkpoint_phase")
            # Resolve the optional browser dependency before irreversible forget.
            from playwright.sync_api import sync_playwright
            self.playwright_factory = sync_playwright
        output = ROOT / ".devenv/memory-local-evidence" / fixture["run_id"]
        output.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.output = output / ("governance-" + self.args.case_id + "-" + str(time.time_ns()) + ".json")
        self.stream = os.fdopen(os.open(self.output, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600), "w")
        self.save()
        print(self.output, flush=True)

    def save(self):
        if hasattr(self, "stream"):
            self.stream.seek(0)
            json.dump(self.report, self.stream, indent=2)
            self.stream.truncate()
            self.stream.flush()
            os.fsync(self.stream.fileno())

    def snapshot(self, label=None):
        command = [str(shutil.which("psql") or ROOT / ".devenv/profile/bin/psql"), "-X", "-qAt", "-v", "ON_ERROR_STOP=1",
                   "-h", self.args.socket, "-d", self.args.database]
        for key, value in {**self.partition, "session": self.args.session, "target_id": self.args.target_id}.items():
            command += ["-v", key + "=" + value]
        sql = "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\nSET LOCAL statement_timeout='5s';\n" + snapshot_sql() + "\nCOMMIT;\n"
        try:
            result = subprocess.run(command, input=sql, text=True, capture_output=True,
                                    timeout=min(15, self.remaining()), check=True)
            require(len(result.stdout.encode()) <= 2_000_000, "canonical_response_bound")
            snapshot = json.loads(result.stdout)
        except CheckFailed:
            raise
        except Exception:
            raise CheckFailed("canonical_snapshot_failed") from None
        require(set(snapshot) == set(LIMITS) and all(isinstance(snapshot[key], list) and len(snapshot[key]) <= bound
                                                  for key, bound in LIMITS.items()), "canonical_snapshot_truncated")
        for row in snapshot["memories"]:
            content = row.pop("target_content", None)
            if row["id"] == self.args.target_id:
                require(isinstance(content, str) and 0 < len(content.encode()) <= 4000
                        and hashlib.sha256(content.encode()).hexdigest() == row["content_hash"], "target_content_hash_required")
                self.content = content
        self.report["last_snapshot"] = snapshot
        if label:
            self.report["snapshots"][label] = snapshot
            self.save()
        return snapshot

    def wait(self, predicate, label):
        self.report["waiting_for"] = label
        while True:
            snapshot = self.snapshot()
            self.save()
            if predicate(snapshot):
                self.report["snapshots"][label] = snapshot
                self.report.pop("waiting_for", None)
                self.save()
                return snapshot
            time.sleep(min(1, self.remaining()))

    def post(self, path, body):
        self.sequence += 1
        started = time.monotonic()
        try:
            status, reply = self.fx.post(self.args.host_url.rstrip("/"), path, body, min(20, self.remaining()))
        except Exception:
            raise CheckFailed("host_request_failed") from None
        self.report["observations"].append({"path": path, "http_status": status,
                                             "elapsed_ms": round((time.monotonic() - started) * 1000)})
        require(status in (200, 202) and isinstance(reply, dict), "host_http_success_required")
        return reply

    def direct(self, method, arguments):
        reply = self.post("/memory/" + self.agent + "/call/" + method, arguments)
        require(reply.get("ok") is True and isinstance(reply.get("result"), dict), "direct_" + method + "_rejected")
        return reply["result"]

    def heal(self):
        errors = []
        with self.playwright_factory() as playwright:
            browser = playwright.chromium.launch(channel="chrome", headless=True,
                                                  timeout=min(30000, self.remaining() * 1000))
            try:
                page = browser.new_page()
                page.on("pageerror", lambda _error: errors.append(True))
                page.set_default_timeout(min(15000, self.remaining() * 1000))
                response = page.goto("http://127.0.0.1:4221/memory", wait_until="domcontentloaded",
                                     timeout=min(30000, self.remaining() * 1000))
                require(response is not None and response.status == 200, "trusted_admin_page_required")
                page.locator("[data-phx-main].phx-connected").wait_for(timeout=min(15000, self.remaining() * 1000))
                self.heal_page(page)
                require(not errors, "admin_browser_page_error")
            finally:
                browser.close()

    def heal_page(self, page):
        url = "http://127.0.0.1:4221/memory"
        fields = {"repair-memory-space": self.partition["memory_space_id"],
                  "repair-host": self.partition["host_id"], "repair-client": self.partition["client_id"],
                  "repair-scope": self.partition["scope"], "repair-namespace": self.partition["namespace"],
                  "repair-session": self.args.session,
                  "repair-idempotency-key": "local-governance:" + self.args.case_id + ":" + self.args.target_id}
        outcomes = []
        for expected in ("dispatched", "already_applied"):
            require(page.url == url, "trusted_loopback_admin_url_required")
            for field, value in fields.items():
                page.locator("#" + field).fill(value, timeout=min(15000, self.remaining() * 1000))
            page.locator("#repair-kind").select_option("summary", timeout=min(15000, self.remaining() * 1000))
            page.locator("#memory-repair-operations form").get_by_role("button", name="Run repair", exact=True).click(
                timeout=min(15000, self.remaining() * 1000))
            message = "Summary: " + expected + "; affected 1"
            page.wait_for_function("""expected => {
                const success = document.querySelector('#memory-repair-result');
                return !!document.querySelector('#memory-repair-error') ||
                    (success && success.textContent.trim().endsWith(expected));
            }""", arg=message, timeout=min(30000, self.remaining() * 1000))
            require(page.locator("#memory-repair-error").count() == 0, "admin_summary_heal_rejected")
            require(page.url == url and page.locator("#memory-repair-result").inner_text().strip().endswith(message),
                    "admin_summary_heal_result_mismatch")
            outcomes.append(expected)
            self.report["heal"] = {"interface": "trusted-admin-form", "url": url, "kind": "summary",
                                   "outcomes": list(outcomes), "normal_styx_only": True}
            self.save()

    def online(self, result):
        require(result.get("mode") == "online" and result.get("stale") is False
                and result.get("authority") in ("canonical", "canonical_with_provisional")
                and result.get("overlay_truncated") is False, "online_canonical_read_required")

    def forget_selected(self):
        # A successful canonical read records this agent's authorized receipt in
        # the host store. A DB snapshot alone cannot authorize canonical forget.
        result = self.direct("list", {"scope": self.partition["scope"], "q": self.content,
                                      "type": "semantic", "limit": 100})
        self.online(result)
        rows = result.get("items", result.get("results"))
        require(result.get("pending_operations") == 0 and isinstance(rows, list) and len(rows) < 100
                and all(isinstance(row, dict) for row in rows), "bounded_canonical_target_read_required")
        selected = [row for row in rows if row.get("id") == self.args.target_id]
        require(len(selected) == 1 and selected[0].get("content") == self.content
                and selected[0].get("memory_type") == "semantic"
                and selected[0].get("scope") == self.partition["scope"], "canonical_target_read_required")
        self.report["positive_target_read"] = {"id": self.args.target_id,
                                                "content_hash": self.original_hash,
                                                "memory_type": "semantic", "online": True,
                                                "untruncated": True, "same_agent_as_forget": True}
        self.save()
        self.forget_attempted = True
        receipt = self.direct("forget", {"id": self.args.target_id})
        require(receipt.get("canonical_id") == self.args.target_id
                and receipt.get("sync_state") in ("pending", "synced"), "forget_receipt_required")
        self.report["forget_receipt"] = safe_receipt(receipt)

    def absent(self):
        # Scope/type/query restrict the read; only selected ID/hash is forbidden.
        # Retained summaries, Crystals and paraphrases may legitimately be returned.
        listing = self.direct("list", {"scope": self.partition["scope"], "q": self.content, "type": "semantic", "limit": 100})
        recall = self.direct("recall", {"query": self.content, "scope": self.partition["scope"], "limit": 100, "token_budget": 4096})
        for name, result in (("list", listing), ("recall", recall)):
            self.online(result)
            rows = result.get("items", result.get("results")) if name == "list" else result.get("results")
            require(isinstance(rows, list) and (name != "list" or len(rows) < 100)
                    and all(isinstance(row, dict) for row in rows) and not any(row.get("id") == self.args.target_id
                    or (row.get("memory_type") == "semantic" and isinstance(row.get("content"), str)
                        and hashlib.sha256(row["content"].encode()).hexdigest() == self.original_hash) for row in rows),
                    "forgotten_candidate_visible")
        self.report["active_read_absence"] = {"selected_id_and_hash_absent": True,
                                               "historical_source_absence_not_required": True}
        diagnostic = self.post("/memory/diagnostics", {"partition": {key: self.partition[key] for key in ("memory_space_id", "scope", "namespace")},
                               "command_ids": [], "event_ids": [], "mirror_ids": [self.args.target_id]})
        require(diagnostic.get("ok") is True, "owner_diagnostics_required")
        mirror = diagnostic["result"]["mirror"]
        require(self.args.target_id not in mirror["active_target_ids"], "forgotten_target_active_in_mirror")
        self.report["mirror"] = mirror

    def run_scenario(self):
        before = self.snapshot("before")
        require(len(before["session"]) == 1 and before["session"][0]["integration"] == "codex"
                and before["session"][0]["status"] in ("completed", "stopped", "abandoned")
                and before["session"][0]["gap_count"] == 0, "closed_captured_session_required")
        session, target = before["session"][0], target_row(before, self.args.target_id)
        require(target["memory_type"] == "semantic" and target["lifecycle_state"] == "active"
                and target["deleted_at"] is None and session["project"].startswith("/synthetic/backplane-memory/" + self.report["run_id"]),
                "active_synthetic_derived_semantic_target_required")
        require(derived_ready(before, session["input_revision"]), "healthy_derived_baseline_required")
        summary = current_summary(before)
        require(any(row["memory_id"] == self.args.target_id and row["source_summary_id"] == summary["id"]
                    for row in before["evidence"]), "target_current_summary_evidence_required")
        require({row["event_id"] for row in before["summary_sources"] if row["summary_id"] == summary["id"]}
                == {row["id"] for row in before["events"]}, "baseline_summary_source_correlation_required")
        self.original, self.original_hash = before, target["content_hash"]
        self.report["original_hash"] = self.original_hash
        self.save()  # Preserve original IDs and evidence before irreversible forget.
        self.forget_selected()
        self.wait(lambda s: target_row(s, self.args.target_id)["deleted_at"] is not None, "forgotten")
        self.heal()
        healed = self.wait(lambda s: derived_ready(s, session["input_revision"])
                           and {"SummaryWorker", "EpisodicWorker", "CrystalWorker"}
                           <= new_worker_completions(s, before), "unchanged_heal")
        self.report["unchanged_governance"] = assert_governed(healed, before, self.args.target_id)
        require(current_summary(healed)["id"] == summary["id"], "unchanged_summary_identity_changed")
        require(artifact_ids(before) == artifact_ids(healed), "unchanged_artifact_inventory_changed")
        require(before["events"] == healed["events"], "unchanged_source_events_changed")
        self.absent()
        self.late_event(session, healed)

    def late_event(self, session, before_late):
        source_id = "local-governance:" + self.args.case_id + ":" + self.args.target_id + ":late"
        body = {"hook_event_name": "UserPromptSubmit", "session_id": self.args.session,
                "source_event_id": source_id, "agent_id": session["agent_id"], "cwd": session["project"],
                "scope": self.partition["scope"], "occurred_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "prompt": "MEMORY-LOCAL-" + self.report["run_id"] + ": Unrelated synthetic follow-up: the Quartz display uses an amber status indicator. Case " + self.args.case_id + "."}
        replies = [self.post("/capture/v1/hooks/codex/UserPromptSubmit", body) for _ in range(2)]
        require(all(reply.get("ok") is True for reply in replies) and valid_uuid(replies[0].get("event_id"))
                and replies[0]["event_id"] == replies[1].get("event_id") and replies[1].get("status") == "duplicate", "late_duplicate_contract_required")
        event_id = replies[0]["event_id"]
        self.report["late_capture"] = {"event_id": event_id, "source_event_id": source_id, "duplicate_same_id": True}
        self.save()
        late = self.wait(lambda s: len(s["session"]) == 1 and s["session"][0]["input_revision"] != session["input_revision"]
                         and derived_ready(s, s["session"][0]["input_revision"]), "late_complete")
        require({row["id"] for row in late["events"]} == {row["id"] for row in before_late["events"]} | {event_id}, "late_source_not_exactly_once")
        require(late["session"][0]["source_sequence_max"] == session["source_sequence_max"] + 1, "late_source_sequence_required")
        frontier = late["frontier"]
        revision = late["session"][0]["input_revision"]
        require(len(frontier) == 1 and frontier[0]["completed_revision"] == revision
                and frontier[0]["requested_revision"] == revision and frontier[0]["completed_generation"] == frontier[0]["requested_generation"], "late_frontier_not_settled")
        summary = current_summary(late)
        require(summary["id"] != current_summary(before_late)["id"], "late_summary_revision_identity_required")
        require({row["event_id"] for row in late["summary_sources"] if row["summary_id"] == summary["id"]}
                == {row["id"] for row in late["events"]}, "late_summary_evidence_mismatch")
        require(any(e["source_summary_id"] == summary["id"] and e["memory_id"] != self.args.target_id for e in late["evidence"]), "late_facts_evidence_missing")
        for crystal in late["crystals"]:
            if crystal["processing_version"] != "crystal-v1":
                continue
            require(any(e["crystal_id"] == crystal["id"] and e["summary_id"] == summary["id"] for e in late["crystal_summaries"])
                    and event_id in {e["event_id"] for e in late["crystal_events"] if e["crystal_id"] == crystal["id"]}, "late_crystal_evidence_missing")
        require(any(event_id in row["source_observation_ids"] for row in late["nodes"]), "late_graph_evidence_missing")
        self.report["late_governance"] = assert_governed(late, self.original, self.args.target_id)
        self.report["same_content_attempt_observed"] = bool(self.report["late_governance"]["new_worker_requests_to_original_tombstone"])
        self.report["artifact_ids"] = {"before": artifact_ids(self.original), "unchanged": artifact_ids(before_late), "late": artifact_ids(late)}
        self.report["late_revision"] = revision
        self.absent()

    def checkpoint(self):
        self.original = self.previous["snapshots"]["before"]
        self.original_hash = self.previous["original_hash"]
        current = self.snapshot("after_parent_rebuild")
        self.report["governance"] = assert_governed(current, self.original, self.args.target_id)
        require(current["session"][0]["input_revision"] == self.previous["late_revision"]
                and derived_ready(current, self.previous["late_revision"]), "rebuild_changed_source_or_derived_state")
        for name in ("events", "summary_sources", "evidence"):
            require(current[name] == self.previous["snapshots"]["late_complete"][name], "rebuild_source_or_evidence_changed")
        self.report["parent_rebuild_execution_verified"] = False
        self.report["limits"].append("This read-only checkpoint requires separate parent evidence that the supported rebuild ran.")
        self.absent()

    def finish_health(self):
        # No configuration, gate, fault or service state was changed. Let only the
        # already accepted forget settle; never resurrect the deleted target.
        self.deadline = time.monotonic() + 30
        while True:
            if self.forget_attempted:
                try:
                    receipt = self.direct("forget", {"id": self.args.target_id})
                    self.report["final_forget_receipt"] = safe_receipt(receipt)
                except CheckFailed as error:
                    # A rejected retry does not establish gateway health. Preserve
                    # the failure and still obtain independent readiness evidence.
                    self.report["final_forget_error"] = str(error)
                    self.report["status"] = "failed"
                    self.report.setdefault("error", "final_forget_failed")
            stats = self.direct("stats", {})
            self.online(stats)
            if stats.get("pending_operations") == 0:
                self.report["final_health"] = {"online": True, "pending_operations": 0,
                                                 "configuration_and_lifecycle_unchanged": True}
                return
            time.sleep(min(1, self.remaining()))

    def run(self):
        try:
            self.preflight()
            if self.args.phase == "run":
                self.run_scenario()
                self.report["rebuild_checkpoint"] = {
                    "argv": ["mix", "memory.projections.rebuild", "--host", self.partition["host_id"], "--session", self.args.session],
                    "warning": "CLI calls app.start. Parent must choose its owned execution environment; do not launch beside a live gateway blindly.",
                    "driver_phase": "checkpoint", "input_report": str(self.output)}
            else:
                self.checkpoint()
            self.report["status"] = "observed-subset"
        except CheckFailed as error:
            self.report["error"] = str(error)
        except Exception:
            self.report["error"] = "unexpected_driver_failure"
        finally:
            if hasattr(self, "stream"):
                try:
                    self.finish_health()
                except Exception:
                    self.report.update(status="failed", final_health={"online": None, "error": "final_health_unverified"})
                self.save()
                self.stream.close()
        if hasattr(self, "output"):
            print(self.output)
        else:
            print("governance preflight failed: " + self.report.get("error", "unknown"))
        return 0 if self.report["status"] == "observed-subset" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("run", "checkpoint"))
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--session", required=True)
    parser.add_argument("--target-id", required=True)
    parser.add_argument("--case-id", required=True, help="fresh lowercase case ID; reuse it only for checkpoint")
    parser.add_argument("--checkpoint", type=Path, help="successful run report after a parent-performed rebuild")
    parser.add_argument("--host-url", default="http://127.0.0.1:4222")
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--database", default="backplane_dev")
    parser.add_argument("--socket", default="/tmp/devenv-e733526/postgres")
    return Governance(parser.parse_args()).run()


if __name__ == "__main__":
    raise SystemExit(main())
