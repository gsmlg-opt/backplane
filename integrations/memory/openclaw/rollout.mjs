#!/usr/bin/env node
/** Explicit local-operator, read-only legacy audit. No import/apply/replay path. */
import { pathToFileURL } from "node:url";
import { MemoryClient, safeError } from "./client.mjs";
import { isUuid } from "./contract.mjs";

export async function auditLegacyPage(client, { agentId, accessId, cursor, limit = 25 }) {
  if (!agentId || !isUuid(accessId) || !Number.isSafeInteger(limit) || limit < 1 || limit > 100) throw new Error("invalid_audit_arguments");
  const offset = cursor?.offset || 0;
  if (!Number.isSafeInteger(offset) || offset < 0) throw new Error("invalid_audit_cursor");
  const peer = await client.capabilities(agentId, accessId);
  if (cursor && cursor.binding_fingerprint !== peer.binding_fingerprint) throw new Error("audit_binding_changed");
  const page = await client.call(agentId, "list", { memory_access_id: accessId, limit, offset });
  if (!Array.isArray(page.results) || page.stale || page.authority !== "canonical" || page.results.length > limit) throw new Error("canonical_audit_unavailable");
  const records = [];
  for (const item of page.results) {
    if (!isUuid(item.id) || item.provisional || item.authority === "provisional") continue;
    const response = await client.call(agentId, "get", { id: item.id, memory_access_id: accessId });
    if (response.authority !== "canonical" || response.stale || response.record?.id !== item.id) throw new Error("canonical_audit_unavailable");
    const record = response.record;
    records.push({
      id: record.id, stored_agent_id: record.provenance?.agent_id ?? null,
      stored_session_id: record.provenance?.session_id ?? null,
      source_host_id: record.provenance?.source_host_id ?? null,
      classification: "ambiguous_legacy_origin", session_attribution: "not_reconstructed",
      coverage: "unknown_legacy_truncation", proposed_action: "preserve",
    });
  }
  return {
    dry_run: true, read_only: true, records, automatic_import_candidates: [],
    limitation: "The public list/get contract does not expose the old metadata.source marker. Agent ID alone does not prove OpenClaw origin; a trusted original export is required for reliable import. Old run IDs are never reinterpreted as sessions.",
    next_cursor: page.results.length === limit ? { offset: offset + page.results.length, binding_fingerprint: peer.binding_fingerprint } : null,
  };
}

async function main(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--operator-read-only") args.operator = true;
    else if (["--base-url", "--agent-id", "--access-id", "--offset", "--binding-fingerprint", "--limit"].includes(argv[i]) && argv[i + 1]) args[argv[i++].slice(2)] = argv[i];
    else throw new Error("invalid_audit_arguments");
  }
  if (!args.operator || !args["base-url"] || !args["agent-id"] || !args["access-id"]) throw new Error("explicit_operator_audit_required");
  // The local HTTP API trusts local operator processes. This CLI does not mint
  // an OpenClaw session audience or bypass any Backplane server grant.
  const client = new MemoryClient({ base_url: args["base-url"], timeout_ms: 5000 }, { warn: (message) => process.stderr.write(message + "\n") });
  try {
    const result = await auditLegacyPage(client, { agentId: args["agent-id"], accessId: args["access-id"], limit: Number(args.limit || 25),
      ...(args.offset ? { cursor: { offset: Number(args.offset), binding_fingerprint: args["binding-fingerprint"] } } : {}) });
    process.stdout.write(JSON.stringify(result, null, 2) + "\n");
  } finally { client.close(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((error) => { process.stderr.write(`backplane-memory: ${safeError(error)}\n`); process.exitCode = 1; });
}
