"""Converge native Hermes files under the same per-target lock as MemoryStore."""

from contextlib import contextmanager
import hashlib
import json
import os
import stat
import time
import uuid

from .delivery import canonical_json
from . import source_contract


@contextmanager
def source_snapshot(home, target, *, timeout=2, max_bytes=16 * 1024 * 1024):
    if target not in {"memory", "user"}:
        raise ValueError("unsupported_source_target")
    path = home / "memories" / ("USER.md" if target == "user" else "MEMORY.md")
    if not path.is_file() or path.is_symlink():
        raise OSError("source_missing_or_unsupported")
    try:
        import fcntl
    except ImportError:
        fcntl = None
        try:
            import msvcrt
        except ImportError as error:
            raise OSError("source_lock_unsupported") from error
    fd = os.open(str(path) + ".lock", os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    acquired = False
    try:
        deadline = time.monotonic() + timeout
        while not acquired:
            try:
                if fcntl:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                else:
                    os.lseek(fd, 0, os.SEEK_SET)
                    msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                acquired = True
            except OSError:
                if time.monotonic() >= deadline:
                    raise OSError("source_lock_timeout") from None
                time.sleep(0.02)
        read_fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(read_fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise OSError("source_unsupported")
            raw = stream.read(max_bytes + 1)
        if len(raw) > max_bytes:
            raise OSError("source_snapshot_too_large")
        text = raw.decode("utf-8-sig")
        entries = list(dict.fromkeys(part.strip() for part in text.split("\n§\n") if part.strip()))
        if len(entries) > 10000 or any(len(part.encode()) > 262144 for part in entries):
            raise OSError("source_snapshot_too_large")
        yield entries
    finally:
        if acquired:
            if fcntl:
                fcntl.flock(fd, fcntl.LOCK_UN)
            else:
                os.lseek(fd, 0, os.SEEK_SET)
                msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
        os.close(fd)


def capture_callback(provider, action, target, content, metadata):
    if action not in {"add", "replace", "remove"} or target not in {"memory", "user"}:
        raise ValueError("unsupported_native_callback")
    callback = {"action": action, "content": content, "metadata": metadata}
    if len(canonical_json(callback).encode()) > 600000:
        raise ValueError("native_callback_too_large")
    journal = provider._journal
    with journal.transaction():
        count = journal.db.execute("SELECT count(*) FROM callbacks WHERE processed=0").fetchone()[0]
        if count >= journal.max_pending:
            raise RuntimeError("delivery_journal_full")
        journal.db.execute("INSERT INTO callbacks(target,payload) VALUES (?,?)", (target, canonical_json(callback)))
        # Fence cached and in-flight context at durable callback acceptance, even
        # when the native file cannot yet provide an authoritative snapshot.
        provider._invalidate_context()
    return reconcile(provider, target)


def reconcile(provider, target, *, force=False, dry_run=False):
    journal = provider._journal
    try:
        with source_snapshot(provider._home, target) as entries:
            with journal.transaction():
                callbacks = list(journal.db.execute("SELECT id,payload FROM callbacks WHERE target=? AND processed=0 ORDER BY id", (target,)))
                all_rows = {row["entry_id"]: dict(row) for row in journal.db.execute("SELECT * FROM source_entries WHERE target=?", (target,))}
                current = {key: value for key, value in all_rows.items() if value["active"]}
                desired = {entry["content"]: entry for entry in current.values()}
                provenance = callbacks and json.loads(callbacks[-1]["payload"])["metadata"] or {}
                if dry_run:
                    return {"complete": True, "target": target, "entries": len(entries), "upserts": len(set(entries) - set(desired)), "withdrawals": len(set(desired) - set(entries)), "pending_identity_chains": journal.db.execute("SELECT count(*) FROM source_chains WHERE target=?", (target,)).fetchone()[0]}
                try:
                    wire_contents = {text: provider._scrub_native(text) for text in entries}
                    wire_provenance = provider._scrub_native(provider._provenance(provenance))
                except RuntimeError:
                    journal.set("source-state:" + target, "native_egress_scrub_unavailable")
                    return {"complete": False, "target": target, "error": "native_egress_scrub_unavailable"}
                source_contract.provenance(wire_provenance)
                approved_additions = set()
                ambiguities = 0
                for row in callbacks:
                    cb = json.loads(row["payload"])
                    previous = cb["metadata"].get("previous_content")
                    content = cb["content"].strip()
                    if cb["action"] == "add":
                        if content in entries:
                            approved_additions.add(content)
                        continue
                    if not isinstance(previous, str) or not previous:
                        ambiguities += 1
                        continue
                    ids = {r["entry_id"] for r in journal.db.execute("SELECT a.entry_id,a.content FROM source_aliases a JOIN source_entries e ON e.entry_id=a.entry_id WHERE a.target=? AND e.retired=0 UNION SELECT entry_id,expected_content AS content FROM source_chains WHERE target=?", (target, target)) if provider._scrub_native(r["content"]) == previous}
                    ids.update(entry["entry_id"] for text, entry in desired.items() if provider._scrub_native(text) == previous and not entry.get("retired"))
                    if len(ids) != 1:
                        ambiguities += 1
                        continue  # an exact string can still have ambiguous historical ownership
                    entry_id = ids.pop()
                    entry = all_rows[entry_id]
                    live = next((text for text, member in desired.items() if member["entry_id"] == entry_id), None)
                    # Late callbacks cannot retract the locked file's already-known head.
                    matches = [text for text in entries if wire_contents[text] == content]
                    actual_content = matches[0] if len(matches) == 1 else content
                    if live in entries and provider._scrub_native(live) != previous and not matches:
                        continue
                    if cb["action"] == "remove":
                        if entry["content"] in entries:
                            continue
                        journal.db.execute("UPDATE source_entries SET retired=1 WHERE entry_id=?", (entry_id,))
                        journal.db.execute("DELETE FROM source_chains WHERE entry_id=?", (entry_id,))
                        for text in [text for text, member in desired.items() if member["entry_id"] == entry_id]:
                            desired.pop(text)
                        continue
                    if not content:
                        continue
                    # Exact links survive independently of debounce/callback timing.
                    journal.db.execute("INSERT OR IGNORE INTO source_aliases VALUES (?,?,?)", (target, previous, entry_id))
                    journal.db.execute("INSERT OR IGNORE INTO source_aliases VALUES (?,?,?)", (target, content, entry_id))
                    for text in [text for text, member in desired.items() if member["entry_id"] == entry_id]:
                        desired.pop(text)
                    if len(matches) == 1:
                        desired[actual_content] = {**entry, "content": actual_content}
                        journal.db.execute("DELETE FROM source_chains WHERE entry_id=?", (entry_id,))
                    else:
                        journal.db.execute("INSERT INTO source_chains VALUES (?,?,?) ON CONFLICT(entry_id) DO UPDATE SET expected_content=excluded.expected_content", (entry_id, target, content))
                desired = {text: entry for text, entry in desired.items() if text in entries}
                unresolved = journal.db.execute("SELECT count(*) FROM source_chains WHERE target=?", (target,)).fetchone()[0]
                for content in entries:
                    if content not in desired and (not unresolved or content in approved_additions):
                        desired[content] = {"entry_id": str(uuid.uuid4()), "content": content, "target": target}
                by_id = {entry["entry_id"]: entry for entry in desired.values()}
                plan = [(entry, "withdraw", None) for key, entry in current.items() if key not in by_id]
                plan += [(entry, "upsert", entry["content"]) for key, entry in by_id.items() if key not in current or current[key]["content"] != entry["content"]]
                if len(all_rows) + sum(entry["entry_id"] not in all_rows for entry in by_id.values()) > 10000:
                    raise RuntimeError("source_identity_journal_full")
                mutations = []
                for entry, operation, content in plan:
                    revision = journal.sequence("source:" + target)
                    event_id = str(uuid.uuid4())
                    payload = {**provider._source_common(target), "entry_id": entry["entry_id"], "event_id": event_id, "revision": revision, "operation": operation, "type": "semantic", "occurred_at": provider._now(), "provenance": wire_provenance}
                    if content is not None:
                        payload["content"] = wire_contents[content]
                    mutations.append((entry, content, source_contract.payload(payload)))
                complete = len(desired) == len(entries) and not unresolved
                snapshot_commands = []
                if complete:
                    snapshot_entries = [{"entry_id": desired[content]["entry_id"], "content": wire_contents[content], "type": "semantic", "provenance": wire_provenance} for content in entries]
                    state_digest = hashlib.sha256(canonical_json([(desired[c]["entry_id"], c) for c in entries]).encode()).hexdigest()
                    if force or state_digest != journal.get("snapshot:" + target):
                        snapshot_commands = source_contract.snapshot(provider, target, snapshot_entries)
                        journal.set("snapshot:" + target, state_digest)
                # Every command is prepared and validated before enqueue or head
                # updates. The surrounding transaction also rolls back aliases,
                # revision allocation and callbacks if any preparation fails.
                for entry, content, payload in mutations:
                    journal.enqueue(payload['event_id'], provider._method_path("source_mutate"), payload)
                    journal.db.execute("INSERT INTO source_entries(target,entry_id,content,active,revision) VALUES (?,?,?,?,?) ON CONFLICT(entry_id) DO UPDATE SET content=excluded.content,active=excluded.active,revision=excluded.revision", (target, entry["entry_id"], content if content is not None else entry["content"], int(payload['operation'] == "upsert"), payload['revision']))
                    journal.db.execute("INSERT OR IGNORE INTO source_aliases VALUES (?,?,?)", (target, entry["content"], entry["entry_id"]))
                for payload in snapshot_commands:
                    journal.enqueue(payload['event_id'], provider._method_path('source_reconcile'), payload)
                if callbacks:
                    journal.db.execute("UPDATE callbacks SET processed=1 WHERE target=? AND id<=?", (target, callbacks[-1]["id"]))
                if ambiguities:
                    journal.set("source-ambiguities:" + target, int(journal.get("source-ambiguities:" + target, "0")) + ambiguities)
                if plan or callbacks:
                    provider._invalidate_context()
                journal.set("source-state:" + target, "ready" if complete else "identity_chain_pending")
                return {"complete": complete, "target": target, "entries": len(entries), "mutations": len(plan), "pending_identity_chains": unresolved}
    except source_contract.SourceValidationError as error:
        journal.set('source-state:' + target, str(error))
        return {'complete':False,'target':target,'error':str(error)}
    except (OSError, UnicodeError):
        if not dry_run:
            journal.set("source-state:" + target, "source_snapshot_unavailable")
        return {"complete": False, "target": target, "error": "source_snapshot_unavailable"}
    except RuntimeError as error:
        if str(error) != "native_egress_scrub_unavailable":
            raise
        if not dry_run:
            journal.set("source-state:" + target, "native_egress_scrub_unavailable")
        return {"complete": False, "target": target, "error": "native_egress_scrub_unavailable"}
