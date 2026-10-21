#!/usr/bin/env python3
"""Read bounded canonical fixture evidence; never create or execute derived work."""

import argparse
import datetime
import json
import os
import shutil
import subprocess
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def query(psql, database, socket, space, sql):
    command = [str(psql), "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-v", "space=" + space,
               "-h", socket, "-d", database]
    result = subprocess.run(command, input="BEGIN READ ONLY;\nSET LOCAL statement_timeout='5s';\n" + sql + "\nCOMMIT;\n",
                            text=True, capture_output=True, timeout=15, check=True)
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--database", default="backplane_dev")
    parser.add_argument("--socket", default="/tmp/devenv-e733526/postgres")
    parser.add_argument("--host-index", type=int, choices=(0, 1), default=0)
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text())
    space = str(uuid.UUID(fixture["hosts"][args.host_index]["partition"]["memory_space_id"]))
    psql = shutil.which("psql") or ROOT / ".devenv/profile/bin/psql"
    # Each projection is deliberately allowlisted: no tokens, raw envelopes, job
    # arguments, provider responses, or arbitrary error messages enter artifacts.
    queries = {
        "events": "SELECT id, stream_id, sequence, session_id, source_sequence, event_type, integration, client_id, source_client_id, occurred_at FROM bpm_events WHERE memory_space_id=:'space'::uuid ORDER BY inserted_at, id LIMIT 250",
        "sessions": "SELECT subject_id, session_id, status, client_id, source_client_id, source_sequence_max, gap_count, input_revision FROM bpm_projected_sessions WHERE memory_space_id=:'space'::uuid ORDER BY updated_at DESC LIMIT 50",
        "repair_frontiers": "SELECT f.host_id, f.session_id, f.requested_generation, f.requested_revision, f.inflight_generation, f.inflight_revision, f.completed_generation, f.completed_revision FROM bpm_projection_repair_frontiers f WHERE EXISTS (SELECT 1 FROM bpm_projected_sessions s WHERE s.host_id=f.host_id AND s.session_id=f.session_id AND s.memory_space_id=:'space'::uuid) ORDER BY f.session_id LIMIT 50",
        "stages": "SELECT projector, subject_type, subject_id, processing_version, input_revision, output_revision, status, attempt_count, last_error IS NOT NULL AS has_error, started_at, completed_at FROM bpm_projection_states WHERE memory_space_id=:'space'::uuid ORDER BY updated_at DESC LIMIT 200",
        "memories": "SELECT id, memory_type, left(content,2000) AS content, session_id, client_id, source_client_id, lifecycle_state, confidence, embedding IS NOT NULL AS embedded, embedding_model, deleted_at FROM bpm_memories WHERE memory_space_id=:'space'::uuid ORDER BY inserted_at DESC LIMIT 100",
        "summaries": "SELECT id, session_id, subject_id, left(content,3000) AS content, input_revision, output_revision, source_complete, source_gap_count, superseded_at FROM memory_summaries WHERE memory_space_id=:'space'::uuid ORDER BY created_at DESC LIMIT 50",
        "lessons": "SELECT l.memory_id, l.status, l.source_kind, l.reinforcement_count, l.decay_rate, l.last_decayed_at FROM memory_lessons l JOIN bpm_memories m ON m.id=l.memory_id WHERE m.memory_space_id=:'space'::uuid ORDER BY l.created_at DESC LIMIT 50",
        "crystals": "SELECT id, memory_id, source_session_id, title, left(narrative,3000) AS narrative, key_outcomes, decisions, unresolved_items, model, input_revision, output_revision, status FROM memory_crystals WHERE memory_space_id=:'space'::uuid ORDER BY inserted_at DESC LIMIT 50",
        "evidence": "SELECT e.memory_id, e.source_event_id, e.source_summary_id, e.source_session_id, e.evidence_kind FROM bpm_memory_evidence e JOIN bpm_memories m ON m.id=e.memory_id WHERE m.memory_space_id=:'space'::uuid ORDER BY e.created_at DESC LIMIT 250",
        "graph_nodes": "SELECT id, type, name FROM memory_graph_nodes WHERE memory_space_id=:'space'::uuid ORDER BY created_at DESC LIMIT 100",
        "graph_edges": "SELECT id, source_id, target_id, relation FROM memory_graph_edges WHERE memory_space_id=:'space'::uuid ORDER BY created_at DESC LIMIT 100",
        "recall": "SELECT id, request_id, normalized_query, channel_availability, result_count, query_embedding_model, status, failure_class, completed_at FROM memory_recall_runs WHERE memory_space_id=:'space'::uuid ORDER BY inserted_at DESC LIMIT 30",
        "jobs": "SELECT id, worker, state, attempt, max_attempts, scheduled_at, completed_at FROM styx_jobs WHERE args->>'memory_space_id'=:'space' ORDER BY inserted_at DESC LIMIT 150",
    }
    report = {"run_id": fixture["run_id"], "memory_space_id": space,
              "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "evidence_level": "read-only-canonical-snapshot", "complete_L01_L18": False,
              "limits": "Allowlisted rows are bounded; a snapshot alone does not prove automatic execution.",
              "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "data": {}}
    for name, select in queries.items():
        sql = "SELECT coalesce(json_agg(row_to_json(e)), '[]'::json) FROM (" + select + ") e;"
        report["data"][name] = query(psql, args.database, args.socket, space, sql)
    output = ROOT / ".devenv/memory-local-evidence" / fixture["run_id"]
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = output / ("canonical-" + str(time.time_ns()) + ".json")
    with path.open("x") as stream:
        os.chmod(path, 0o600)
        json.dump(report, stream, indent=2)
    print(path)
    print(json.dumps({name: len(rows) for name, rows in report["data"].items()}))


if __name__ == "__main__":
    main()
