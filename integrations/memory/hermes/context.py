"""Conservative automatic-context policy and whole-entry final packing."""

from datetime import datetime, timezone
import json
import re


def _deadline(value):
    if value is None:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError, AttributeError):
        return 0


def render_context(provider, query, result):
    ttl = provider._config["cache_ttl"]
    if result.get("stale") or result.get("success") is False or not isinstance(result.get("results"), list):
        return "", 0
    if not isinstance(result.get("provisional_results", []), list):
        return "", 0
    rows = result["results"] + result.get("provisional_results", [])
    now = datetime.now(timezone.utc).timestamp()
    tokens = {term for term in re.findall(r"\w+", query.lower()) if len(term) > 1 and term not in {"the", "and", "for", "what", "that", "this", "with", "from", "have", "does", "about"}}
    lines, used, seen = [], 0, set()
    with provider._journal.lock:
        heads = {row["entry_id"]: dict(row) for row in provider._journal.db.execute("SELECT * FROM source_entries")}
        # An unresolved callback cannot choose a destructive entry identity. It
        # can conservatively suppress this profile/target's contribution until
        # a complete snapshot resolves it. The durable journal survives restart.
        pending_targets = {
            row["target"] for row in provider._journal.db.execute(
                "SELECT target,payload FROM callbacks WHERE processed=0")
            if json.loads(row["payload"]).get("action") in {"remove", "replace"}
        }
        pending_targets.update(row["target"] for row in provider._journal.db.execute(
            "SELECT DISTINCT target FROM source_chains"))
        unsettled = provider._journal.db.execute("SELECT 1 FROM delivery WHERE path LIKE '%source_%' AND state!='canonical_committed' LIMIT 1").fetchone() is not None
        unsettled = unsettled or bool(pending_targets)
    for row in rows:
        if not isinstance(row, dict) or row.get("policy_version") != "current_context.v1":
            continue
        if row.get("lifecycle_state") not in {"active", "current", "provisional"} or row.get("effective_support") is not True:
            continue
        expires, valid = _deadline(row.get("expires_at")), _deadline(row.get("valid_until"))
        if any(value is not None and value <= now for value in (expires, valid)):
            continue
        refs = row.get("source_refs")
        if not isinstance(refs, list):
            continue
        supports = []
        for ref in refs:
            if not isinstance(ref, dict) or ref.get("active") is not True:
                continue
            src = ref.get("source") or {}
            local = src.get("installation_id") == provider._journal.installation_id and src.get("profile_id") == provider._journal.profile_id
            if local and src.get("target") in pending_targets:
                continue
            head = heads.get(ref.get("entry_id")) if local else None
            if head and (not head["active"] or head["revision"] > ref.get("source_revision", 0)):
                continue
            supports.append(ref)
        independent = row.get("independent_support") is True
        if refs and not supports and not independent or unsettled and row.get("support_complete") is not True and not independent:
            continue
        selected = provider._config["source_selection"]
        if selected and not any((ref.get("source") or {}).get("integration") in selected for ref in supports):
            continue
        trust = row.get("trust")
        if trust == "raw_evidence" or trust not in {"candidate_inference", "established_fact"}:
            continue
        content = row.get("content")
        if not isinstance(content, str) or not content.strip():
            continue
        if provider._config["relevance_mode"] == "lexical":
            if not tokens or not any(term in content.lower() for term in tokens):
                continue
        elif row.get("relevance_accepted") is not True:
            continue
        identity = (row.get("canonical_id") or row.get("id"), row.get("revision"))
        if not identity[0] or identity in seen:
            continue
        seen.add(identity)
        pending = row.get("provisional") is True or row.get("authority") == "provisional"
        label = "candidate inference" if trust == "candidate_inference" else "established fact"
        if pending:
            label += "; pending local memory"
        rendered = "- [" + label + "; " + str(identity[0]) + "; revision " + str(identity[1]) + "] " + content.strip()
        # UTF-8 bytes are a conservative upper bound on byte-tokenizer tokens.
        # Count all labels/references/newlines and skip oversized whole entries.
        cost = len(rendered.encode()) + (1 if lines else 0)
        if used + cost > provider._config["context_token_budget"]:
            continue
        lines.append(rendered)
        used += cost
        for deadline in (expires, valid):
            if deadline is not None:
                ttl = min(ttl, max(0, deadline - now))
    return "\n".join(lines), ttl
