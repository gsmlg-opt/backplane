import { digest } from "./contract.mjs";

const LOOPBACK = new Set(["localhost", "127.0.0.1", "::1"]);
const SAFE_CODES = new Set([
  "invalid_scope", "unknown_scope", "memory_scope_mismatch", "invalid_arguments", "invalid_request",
  "unauthorized", "forbidden", "access_denied", "not_found", "unsupported_operation", "unsupported_capability",
  "memory_access_revoked", "memory_access_denied", "authority_changed", "partition_mismatch", "binding_changed",
  "capture_binding_mismatch", "source_binding_mismatch", "canonical_unavailable", "payload_too_large",
]);
export class MemoryRequestError extends Error {
  constructor(code, status) { super(`${code}${status ? ` (HTTP ${status})` : ""}`); this.code = code; this.status = status; }
}
export function safeError(error) {
  if (error instanceof MemoryRequestError) return error.message;
  if (error instanceof Error && /^[a-z][a-z0-9_]{0,80}$/.test(error.message)) return error.message;
  return "operation_failed";
}
export function createPlaintextWarner(warn) {
  let warned = false;
  return (url) => {
    const parsed = new URL(url);
    if (!warned && parsed.protocol === "http:" && !LOOPBACK.has(parsed.hostname.replace(/^\[|\]$/g, ""))) {
      warned = true;
      warn("backplane-memory: plaintext_remote_transport; configure HTTPS or a local tunnel");
    }
  };
}
export class MemoryClient {
  constructor(config, logger) {
    this.baseUrl = config.base_url.replace(/\/+$/, "");
    const url = new URL(this.baseUrl);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) throw new Error("invalid_base_url");
    this.timeout = config.timeout_ms;
    this.warn = createPlaintextWarner((message) => logger?.warn?.(message));
    this.abort = new AbortController();
  }
  path(agentId, method) { return `/memory/${encodeURIComponent(agentId)}/call/${method}`; }
  async request(path, args, guard = () => {}, signal) {
    guard();
    this.warn(this.baseUrl);
    const res = await fetch(this.baseUrl + path, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(args),
      signal: AbortSignal.any([AbortSignal.timeout(this.timeout), this.abort.signal, ...(signal ? [signal] : [])]),
    });
    guard();
    let body;
    try { body = await res.json(); } catch { throw new MemoryRequestError("invalid_response", res.status); }
    guard();
    if (!res.ok || body?.ok === false) throw new MemoryRequestError(SAFE_CODES.has(body?.error) ? body.error : "request_failed", res.status);
    if (body?.ok !== true) throw new MemoryRequestError("invalid_response", res.status);
    return body;
  }
  async call(agentId, method, args, guard, signal) {
    const body = await this.request(this.path(agentId, method), args, guard, signal);
    if (!body.result || typeof body.result !== "object" || Array.isArray(body.result)) throw new MemoryRequestError("invalid_response");
    return body.result;
  }
  async capabilities(agentId, accessId, guard, { requireWrite = false } = {}) {
    const peer = await this.call(agentId, "source_capabilities", { integration: "openclaw", memory_access_id: accessId }, guard);
    if (peer.protocol !== "memory_sources.v1" || peer.supported !== true || !peer.contracts?.includes("openclaw_source.v1") || !peer.negotiated?.includes("openclaw_source.v1")) throw new MemoryRequestError("unsupported_capability");
    if (!peer.binding || peer.binding.access_id !== accessId || digest(peer.binding) !== peer.binding_fingerprint) throw new MemoryRequestError("invalid_binding");
    if (requireWrite && peer.ready !== true) throw new MemoryRequestError("source_unavailable");
    return peer;
  }
  close() { this.abort.abort(); }
}
