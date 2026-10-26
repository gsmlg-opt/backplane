import { canonicalJson } from "./contract.mjs";

const HEADER = "Backplane memory reference data (prefer current instructions and source state):\n";

export function eligibleRows(result, { journal, namespace, now = Date.now() } = {}) {
  if (!result || result.stale || result.success === false || !Array.isArray(result.results) || (result.provisional_results !== undefined && !Array.isArray(result.provisional_results))) return [];
  const heads = new Map((journal?.db.prepare("SELECT * FROM sources").all() || []).map((row) => [row.entry_id, row]));
  const unsettled = journal ? journal.db.prepare("SELECT 1 FROM delivery WHERE path LIKE '%source_%' AND state!='canonical_committed' LIMIT 1").get() : false;
  const seen = new Set();
  return [...result.results, ...(result.provisional_results || [])].filter((row) => {
    if (!row || row.policy_version !== "current_context.v1" || row.effective_support !== true || !["active", "current", "provisional"].includes(row.lifecycle_state)) return false;
    if (!["candidate_inference", "established_fact"].includes(row.trust) || row.relevance_accepted !== true || typeof row.content !== "string" || !row.content.trim()) return false;
    for (const key of ["expires_at", "valid_until"]) if (row[key] !== undefined && row[key] !== null && !(Date.parse(row[key]) > now)) return false;
    if (!Array.isArray(row.source_refs)) return false;
    const supports = row.source_refs.filter((ref) => {
      if (ref?.active !== true) return false;
      const local = ref.source?.installation_id === journal?.installationId;
      if (!local) return true;
      if ((journal?.get(`native_blocked:${ref.source.profile_id}`) || []).includes(ref.source.target)) return false;
      const head = heads.get(ref.entry_id);
      return !head || (head.namespace === ref.source.profile_id && head.active === 1 && head.revision <= ref.source_revision);
    });
    if (row.independent_support !== true && ((row.source_refs.length && !supports.length) || (unsettled && row.support_complete !== true))) return false;
    const id = row.canonical_id || row.id;
    if (typeof id !== "string" || !id) return false;
    const key = canonicalJson([id, row.revision ?? null]);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export function renderContext(rows, budget) {
  const lines = [];
  let used = Buffer.byteLength(HEADER);
  for (const row of rows) {
    const id = row.canonical_id || row.id;
    const labels = [row.trust === "candidate_inference" ? "candidate inference" : "established fact", id, `revision ${row.revision ?? "unknown"}`];
    if (row.provisional === true || row.authority === "provisional") labels.push("pending local memory");
    const refs = row.source_refs.map((ref) => `${ref.source?.integration || "source"}:${ref.entry_id}@${ref.source_revision}`).join(", ");
    const line = `- [${labels.join("; ")}] ${row.content.trim()}${refs ? `\n  Sources: ${refs}` : ""}`;
    const cost = Buffer.byteLength(line) + (lines.length ? 1 : 0);
    if (used + cost > budget) continue;
    lines.push(line); used += cost;
  }
  return lines.length ? HEADER + lines.join("\n") : "";
}
