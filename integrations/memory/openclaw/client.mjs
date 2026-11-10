const LOOPBACK = new Set(["localhost", "127.0.0.1", "::1"]);
const SAFE_CODE = /^[a-z][a-z0-9_]{0,80}$/;
const MAX_ERROR_CHARS = 200;

export function safeError(error) {
  const code = typeof error === "string" ? error : error instanceof Error ? error.message : "";
  return SAFE_CODE.test(code) ? code : "operation_failed";
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

/**
 * The host agent HTTP client. Requests never throw: every non-2xx, transport,
 * timeout or malformed answer becomes `{ ok: false, error, status? }` and logs
 * exactly one content-free warning, so callers can simply degrade.
 */
export class MemoryClient {
  constructor(config, logger) {
    this.baseUrl = config.base_url.replace(/\/+$/, "");
    const url = new URL(this.baseUrl);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) throw new Error("invalid_base_url");
    this.agentId = config.agent_id;
    this.timeout = config.timeout_ms;
    this.logger = logger;
    this.warnPlaintext = createPlaintextWarner((message) => logger?.warn?.(message));
    this.abort = new AbortController();
  }
  failure(label, code, status) {
    const safe = SAFE_CODE.test(code) ? code : "request_rejected";
    this.logger?.warn?.(`backplane-memory: ${label} failed: ${safe}${status ? ` (HTTP ${status})` : ""}`);
    return { ok: false, error: code, ...(status ? { status } : {}) };
  }
  async request(path, body, { label = path, signal } = {}) {
    let res;
    try {
      this.warnPlaintext(this.baseUrl);
      res = await fetch(this.baseUrl + path, {
        method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
        signal: AbortSignal.any([AbortSignal.timeout(this.timeout), this.abort.signal, ...(signal ? [signal] : [])]),
      });
    } catch { return this.failure(label, "request_failed"); }
    let parsed;
    try { parsed = await res.json(); } catch { return this.failure(label, res.ok ? "invalid_response" : "http_error", res.status); }
    if (!res.ok || parsed?.ok !== true) {
      const code = typeof parsed?.error === "string" && parsed.error.trim() ? parsed.error.slice(0, MAX_ERROR_CHARS) : res.ok ? "invalid_response" : "http_error";
      return this.failure(label, code, res.status);
    }
    return parsed;
  }
  callPath(method) { return `/memory/${encodeURIComponent(this.agentId)}/call/${method}`; }
  /** One `memory::<method>` call: `{ ok: true, result }` or a logged failure. */
  async call(method, args, { signal } = {}) {
    const label = `memory ${method}`;
    const response = await this.request(this.callPath(method), args, { label, signal });
    if (!response.ok) return response;
    if (!response.result || typeof response.result !== "object" || Array.isArray(response.result)) return this.failure(label, "invalid_response");
    return { ok: true, result: response.result };
  }
  close() { this.abort.abort(); }
}
