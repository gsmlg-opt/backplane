#!/usr/bin/env python3
"""Content-free read-only local dev inventory; compare retained rows across runs."""

import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
FIELDS = {"id", "memory_space_id", "host_id", "client_id", "source_client_id",
          "scope", "namespace", "content_hash", "deleted_at", "lifecycle_state"}
SQL = """BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='5s';
SELECT coalesce(json_agg(row_to_json(m) ORDER BY m.id),'[]'::json) FROM
(SELECT id,memory_space_id,host_id,client_id,source_client_id,scope,namespace,
encode(content_hash,'hex') AS content_hash,deleted_at,lifecycle_state
FROM bpm_memories WHERE memory_space_id IN (:'space_a'::uuid,:'space_b'::uuid)
ORDER BY id LIMIT 10001) m;
COMMIT;
"""


class InventoryFailed(RuntimeError):
    pass


def require(condition, code):
    if not condition:
        raise InventoryFailed(code)


def validate(rows):
    require(isinstance(rows, list) and len(rows) <= 10000, "inventory_bound")
    require(all(isinstance(row, dict) and set(row) == FIELDS for row in rows), "inventory_shape")
    require(all(isinstance(row["id"], str) and isinstance(row["content_hash"], str)
                and re.fullmatch(r"[a-f0-9]{64}", row["content_hash"]) for row in rows), "inventory_identity")
    require(len({row["id"] for row in rows}) == len(rows), "duplicate_inventory_id")
    return {row["id"]: row for row in rows}


def compare(before, after):
    old, new = validate(before), validate(after)
    missing = sorted(old.keys() - new.keys())
    # Read counters/confidence can change. Identity/content/deletion and lifecycle
    # must be inspected if they change; extra newly created rows are reported.
    changed = sorted(key for key in old.keys() & new.keys() if old[key] != new[key])
    return {"status": "passed" if not missing and not changed else "failed",
            "before_count": len(old), "after_count": len(new),
            "retained_tombstones": sum(row["deleted_at"] is not None for row in before),
            "missing_ids": missing, "changed_ids": changed, "new_ids": sorted(new.keys() - old.keys())}


def snapshot(fixture, socket):
    hosts = fixture["hosts"][:2]
    spaces = [str(uuid.UUID(host["partition"]["memory_space_id"])) for host in hosts]
    require(len(spaces) == 2 and spaces[0] != spaces[1], "distinct_fixture_spaces_required")
    socket = Path(socket).resolve()
    require(socket.is_dir() and socket.name == "postgres" and socket.parent.name.startswith("devenv-"),
            "local_devenv_socket_required")
    command = [str(ROOT / ".devenv/profile/bin/psql"), "-X", "-qAt", "-v", "ON_ERROR_STOP=1",
               "-h", str(socket), "-d", "backplane_dev", "-v", "space_a=" + spaces[0],
               "-v", "space_b=" + spaces[1]]
    try:
        result = subprocess.run(command, input=SQL, text=True, capture_output=True, timeout=15, check=True)
        require(len(result.stdout.encode()) <= 4_000_000, "inventory_response_bound")
        rows = json.loads(result.stdout)
    except InventoryFailed:
        raise
    except Exception:
        raise InventoryFailed("canonical_snapshot_failed") from None
    validate(rows)
    require(all(row["memory_space_id"] in spaces for row in rows), "inventory_space_mismatch")
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--socket", default="/tmp/devenv-e733526/postgres")
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        rows = snapshot(json.loads(args.fixture.read_text()), args.socket)
        report = {"evidence_level": "read-only-canonical-baseline", "rows": rows,
                  "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
        if args.baseline:
            require(args.baseline.stat().st_size <= 4_000_000, "baseline_bound")
            report["comparison"] = compare(json.loads(args.baseline.read_text())["rows"], rows)
        with args.output.open("x") as stream:
            os.chmod(args.output, 0o600)
            json.dump(report, stream, indent=2)
        print(json.dumps({"path": str(args.output), "count": len(rows),
                          "comparison": report.get("comparison", {}).get("status", "not_requested")}))
        return 0 if report.get("comparison", {}).get("status", "passed") == "passed" else 1
    except (InventoryFailed, OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"status": "failed", "failure": str(error) if isinstance(error, InventoryFailed)
                          else type(error).__name__}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
