import { createHash, randomUUID } from "node:crypto";

export const SOURCE_PROTOCOL = "memory_sources.v1";
export const SOURCE_CAPABILITY = "openclaw_source.v1";
export const CAPTURE_PROTOCOL = "openclaw_capture.v1";
export const MAX_CONTENT_BYTES = 262144;
export const TOOL_NAMES = Object.freeze({
  search: "backplane_memory_search", get: "backplane_memory_get",
  save: "backplane_memory_save", correct: "backplane_memory_correct",
  withdraw: "backplane_memory_withdraw", forget: "backplane_memory_forget",
  status: "backplane_memory_status",
});
export const uuid = () => randomUUID();
export const sha256 = (value) => createHash("sha256").update(value).digest("hex");
export const isUuid = (value) => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);

// Elixir sorts UTF-8 binary keys. JS's default UTF-16 sort differs for astral keys.
export function canonicalJson(value) {
  if (value === null || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "number" && Number.isSafeInteger(value)) return String(value);
  if (typeof value === "string") {
    if (!value.isWellFormed()) throw new Error("invalid_unicode");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && Object.getPrototypeOf(value) === Object.prototype) {
    return `{${Object.keys(value).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
      .map((key) => `${canonicalJson(key)}:${canonicalJson(value[key])}`).join(",")}}`;
  }
  throw new Error("not_portable_json");
}
export const digest = (value) => sha256(canonicalJson(value));
export function text(value, max = MAX_CONTENT_BYTES) {
  if (typeof value !== "string" || !value.isWellFormed() || value.includes("\0") || !value.trim() || Buffer.byteLength(value) > max) {
    throw new Error("invalid_content");
  }
  return value;
}

// This is the adapter's explicit local egress policy, in addition to host capture
// filtering. Redaction failure never falls back to the original text.
export function redactForEgress(value) {
  if (typeof value !== "string" || !value.isWellFormed() || value.includes("\0")) throw new Error("egress_policy_failed");
  const markers = [...value.matchAll(/<\/?private(?:\s[^>]*)?>/gi)];
  if ((value.match(/<\/?private\b/gi) || []).length !== markers.length) throw new Error("egress_policy_failed");
  let privateBlock = false;
  for (const marker of markers) {
    const closing = marker[0].startsWith("</");
    if (closing !== privateBlock) throw new Error("egress_policy_failed");
    privateBlock = !closing;
  }
  if (privateBlock) throw new Error("egress_policy_failed");
  return value.replace(/<private(?:\s[^>]*)?>[\s\S]*?<\/private\s*>/gi, "[private content removed]")
    .replace(/\b(?:sk|ghp|github_pat|bp2)_[A-Za-z0-9_-]{16,}\b/g, "[credential removed]")
    .replace(/\bsk-[A-Za-z0-9_-]{16,}\b/g, "[credential removed]")
    .replace(/(\b(?:api[_-]?key|authorization|access[_-]?token|password)\s*[:=]\s*)(?:Bearer\s+)?[^\s,;]+/gi, "$1[credential removed]");
}

export function extractText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter((part) => part?.type === "text" && typeof part.text === "string").map((part) => part.text).join("\n");
}

export function sourceSnapshot(source, entries, revision) {
  const reconciliation_id = uuid();
  const common = { protocol: SOURCE_PROTOCOL, source, reconciliation_id };
  const pages = [];
  for (let i = 0; i < entries.length; i += 100) pages.push(entries.slice(i, i + 100));
  return [
    { ...common, event_id: uuid(), phase: "begin", revision, page_count: pages.length, entry_count: entries.length, snapshot_hash: digest(entries) },
    ...pages.map((page, page_index) => ({ ...common, event_id: uuid(), phase: "page", page_index, entries: page, page_hash: digest(page) })),
    { ...common, event_id: uuid(), phase: "commit", complete: true },
  ];
}
