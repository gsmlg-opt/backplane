"""Actual Hermes message occurrences -> existing host capture hooks."""

import copy
from difflib import SequenceMatcher
import hashlib
import json
import uuid

from .delivery import canonical_json


def _content_text(value):
    if isinstance(value, str):
        return value, "text"
    if isinstance(value, list):
        return "\n".join(part["text"] for part in value if isinstance(part, dict) and part.get("type") in {"text", "input_text", "output_text"} and isinstance(part.get("text"), str)), "text_only"
    return "", "unsupported"


def boundary(provider, hook, session_id, *, lifecycle=None, dedup_key=None):
    if not session_id:
        return None
    journal = provider._journal
    if dedup_key and journal.get(dedup_key):
        return journal.get(dedup_key)
    event_id = str(uuid.uuid4())
    payload = provider._capture_common(session_id)
    payload.update(event_id=event_id, source_sequence=journal.sequence("capture"))
    if lifecycle:
        payload["lifecycle"] = lifecycle
    journal.enqueue(event_id, "/capture/v1/hooks/hermes/" + hook, payload)
    if dedup_key:
        journal.set(dedup_key, event_id)
    return event_id


def capture_messages(provider, messages, session_id, *, author=None, turn_user_content=None, checkpoint=False, align_legacy=True):
    journal = provider._journal
    rows = copy.deepcopy(messages)
    if not isinstance(rows, list) or len(rows) > 4096:
        raise ValueError("capture_snapshot_too_large")
    roles = {"user", "assistant"} if checkpoint else {"user", "assistant", "tool"}
    rows = [row for row in rows if isinstance(row, dict) and row.get("role") in roles and not row.get("_compressed_summary")]
    signatures = [hashlib.sha256(canonical_json({key: row.get(key) for key in ("role", "content", "tool_call_id", "tool_calls")}).encode()).hexdigest() for row in rows]
    author_indices = [index for index, row in enumerate(rows) if row.get("role") == "user" and _content_text(row.get("content"))[0] == turn_user_content]
    author_index = author_indices[-1] if author_indices else None
    with journal.transaction():
        if journal.db.execute("SELECT count(*) FROM messages").fetchone()[0] > 100000 or journal.db.execute("SELECT count(*) FROM sessions").fetchone()[0] > 1000:
            raise RuntimeError("capture_identity_journal_full")
        boundary(provider, "session-start", session_id, dedup_key="session-start:" + session_id)
        previous_row = journal.db.execute("SELECT snapshot FROM sessions WHERE session_id=?", (session_id,)).fetchone()
        previous = json.loads(previous_row[0]) if previous_row else []
        matched = {}
        # Legacy rows lack native occurrence IDs. Align ordered context, preserving
        # two equal messages as two occurrences. This is explicitly not exactly-once
        # interpretation of indistinguishable callbacks or a full-history cursor.
        for block in SequenceMatcher(None, [r["signature"] for r in previous] if align_legacy else [], signatures, autojunk=False).get_matching_blocks():
            for offset in range(block.size):
                matched[block.b + offset] = previous[block.a + offset]["identity"]
        current, event_ids = [], []
        for index, row in enumerate(rows):
            native_uid = row.get("message_uid")
            native_uid = native_uid if isinstance(native_uid, str) and native_uid else None
            identity = session_id + ":" + ("native:" + native_uid if native_uid else matched.get(index, "adapter:" + str(uuid.uuid4())))
            # matched legacy identities already include the session prefix.
            if not native_uid and index in matched:
                identity = matched[index]
            current.append({"signature": signatures[index], "identity": identity})
            existing = journal.db.execute("SELECT digest,text_digest,revision,event_id,author FROM messages WHERE identity=?", (identity,)).fetchone()
            row_author = row.get("author") if isinstance(row.get("author"), dict) else author if index == author_index else None
            if row_author is None and existing and existing["author"]:
                row_author = json.loads(existing["author"])
            text, coverage = _content_text(row.get("content"))
            if checkpoint and not text.strip():
                continue
            if not text and not row.get("tool_calls"):
                continue
            content = text
            original_length = len(text)
            original_hash = hashlib.sha256(text.encode()).hexdigest()
            truncated = len(text) > provider._config["evidence_chars"] or len(text.encode()) > 262144
            if truncated:
                if not native_uid:
                    raise ValueError("oversized_evidence_without_original_reference")
                content = text[:provider._config["evidence_chars"]].encode()[:262144].decode('utf-8',errors='ignore')
            source_reference = None
            if native_uid:
                source_reference = "hermes-session://" + journal.profile_id + "/" + session_id + "/" + native_uid
            semantic = {"role": row["role"], "content": content, "original_sha256": original_hash, "tool_calls": row.get("tool_calls"), "author": row_author}
            digest = hashlib.sha256(canonical_json(semantic).encode()).hexdigest()
            text_digest = hashlib.sha256(canonical_json({"role": row["role"], "original_sha256": original_hash}).encode()).hexdigest()
            if existing and (existing["digest"] == digest or checkpoint and existing["text_digest"] == text_digest):
                event_ids.append(existing["event_id"])
                continue
            revision = existing["revision"] + 1 if existing else 1
            event_id = str(uuid.uuid4())
            payload = {**provider._capture_common(session_id), "event_id": event_id, "source_sequence": journal.sequence("capture"), "source_revision": revision, "role": row["role"], "content": content, "completeness": {"truncated": truncated, "original_length": original_length, "original_sha256": original_hash, "coverage": "direct_text" if checkpoint else coverage}}
            if native_uid:
                payload["message_uid"] = native_uid
                payload["source_reference"] = source_reference
            for original, field in (("_tool_call_uid", "tool_call_uid"), ("_tool_call_uids", "tool_call_uids"), ("_absorbed_message_uids", "absorbed_message_uids"), ("tool_call_id", "tool_call_id")):
                if row.get(original):
                    payload[field] = row[original]
            if row_author and row["role"] == "user":
                payload["author"] = row_author
            # Tool call arguments are available evidence, not assistant-confirmed
            # facts. Preserve the actual payload in content without fabricating a row.
            if row.get("tool_calls") and not checkpoint:
                tool_text = canonical_json({"text": content, "tool_calls": row["tool_calls"]})
                if len(tool_text.encode()) > 262144:
                    raise ValueError("tool_evidence_too_large")
                payload["content"] = tool_text
                payload["completeness"]["coverage"] = "text_and_tool_calls"
            journal.enqueue(event_id, "/capture/v1/hooks/hermes/message", payload)
            journal.db.execute("INSERT INTO messages VALUES (?,?,?,?,?,?) ON CONFLICT(identity) DO UPDATE SET digest=excluded.digest,text_digest=excluded.text_digest,revision=excluded.revision,event_id=excluded.event_id,author=excluded.author", (identity, digest, text_digest, revision, event_id, canonical_json(row_author) if row_author else None))
            event_ids.append(event_id)
        journal.db.execute("INSERT INTO sessions VALUES (?,?) ON CONFLICT(session_id) DO UPDATE SET snapshot=excluded.snapshot", (session_id, canonical_json(current)))
        if checkpoint:
            fingerprint = hashlib.sha256(canonical_json(event_ids).encode()).hexdigest()
            boundary(provider, "pre-compress", session_id, lifecycle={"reason": "checkpoint"}, dedup_key="checkpoint:" + session_id + ":" + fingerprint)
        return event_ids
