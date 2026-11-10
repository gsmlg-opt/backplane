import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { CAPTURE_PROTOCOL, TOOL_NAMES, canonicalJson, digest, extractText, redactForEgress, sha256, text, uuid } from "./contract.mjs";
import { DeliveryJournal } from "./journal.mjs";
import { MemoryClient, safeError } from "./client.mjs";
import { describe, renderContext } from "./context.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
// The installer places INSTRUCTIONS.md beside this file; a repository/release checkout has it in ../shared.
export const INSTRUCTION_PATHS = [join(HERE, "INSTRUCTIONS.md"), join(HERE, "..", "shared", "INSTRUCTIONS.md")];
const MAX_QUERY_CHARS = 4000;
const TERMINAL_STATUS = new Set([400, 401, 403, 404, 409, 413, 422]);
const STATUS_POLL_MS = 30000;
const KINDS = ["fact", "procedure", "worklog", "note"];

export const configSchema = {
  type: "object", additionalProperties: false,
  properties: {
    enabled: { type: "boolean" }, base_url: { type: "string" }, agent_id: { type: "string", minLength: 1 },
    profile_id: { type: "string", minLength: 1, maxLength: 128 }, journal_path: { type: "string" },
    token_budget: { type: "integer", minimum: 128, maximum: 32768 },
    search_limit: { type: "integer", minimum: 1, maximum: 50 },
    timeout_ms: { type: "integer", minimum: 100, maximum: 20000 },
  },
};
const DEFAULTS = { enabled: true, base_url: "http://127.0.0.1:4222", agent_id: "openclaw", profile_id: "default", token_budget: 2000, search_limit: 8, timeout_ms: 5000 };
const intIn = (value, low, high) => Number.isInteger(value) && value >= low && value <= high;

function configOf(api) {
  const supplied = api.pluginConfig || {};
  const unknown = Object.keys(supplied).filter((key) => !Object.hasOwn(configSchema.properties, key)).sort();
  // Settings written for older plugin versions are ignored, never applied.
  if (unknown.length) api.logger?.warn?.(`backplane-memory: ignoring unsupported config keys: ${unknown.join(", ")}`);
  const config = { ...DEFAULTS, ...Object.fromEntries(Object.entries(supplied).filter(([key]) => !unknown.includes(key))) };
  if (!intIn(config.token_budget, 128, 32768) || !intIn(config.timeout_ms, 100, 20000) || !intIn(config.search_limit, 1, 50)) throw new Error("invalid_config");
  if (!/^[A-Za-z0-9_.-]{1,128}$/.test(config.profile_id) || typeof config.agent_id !== "string" || !config.agent_id.trim()) throw new Error("invalid_config");
  return config;
}
export function loadInstructions(paths = INSTRUCTION_PATHS) {
  for (const path of paths) {
    try { return readFileSync(path, "utf8"); } catch { /* try the next location */ }
  }
  return null;
}
function signature(messages) {
  // A local equality fence, never an occurrence identity or a wire hash. Message
  // tool arguments may contain floats even though the wire contract may not.
  return sha256(JSON.stringify(messages.map((message) => ({ role: message?.role ?? null, content: message?.content ?? null, provenance: message?.provenance ?? null, toolCallId: message?.toolCallId ?? null }))));
}
const withoutUndefined = (value) => Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined));
const toolResult = (result) => ({ content: [{ type: "text", text: JSON.stringify(result) }], details: result });
const failed = (response) => ({ success: false, error: response.error, ...(response.status ? { http_status: response.status } : {}) });
const completeness = (content) => ({ truncated: false, original_length: [...content].length, original_sha256: sha256(content), coverage: "full" });

const SUBJECT = { type: "object", properties: { type: { type: "string" }, key: { type: "string" } }, required: ["type", "key"] };
const TIME = { type: "string", description: "ISO 8601 timestamp" };
// Mirrors Backplane.MemoryToolContract.schemas/0. remember omits the provenance
// fields the host stamps (host, agent, integration, writer, request_key, observed_at);
// the plugin adds the current session_id itself.
const TOOLS = [
  ["search", TOOL_NAMES.search, "Backplane memory::search. Search memories shared by all of the user's agents and hosts; results show where each came from.",
    { query: { type: "string", minLength: 1 }, host: { type: "string" }, agent: { type: "string" }, kind: { type: "string", enum: KINDS },
      subject: { type: "string", description: "Subject as type:key, e.g. repo:backplane" }, since: TIME, until: TIME,
      include_inactive: { type: "boolean", default: false }, limit: { type: "integer", minimum: 1, maximum: 50, default: 10 } }, ["query"]],
  ["get", TOOL_NAMES.get, "Backplane memory::get. Fetch one memory and its supersession history by id.", { id: { type: "string" } }, ["id"]],
  ["recent", TOOL_NAMES.recent, "Backplane memory::recent. List recent worklog memories, newest first.",
    { host: { type: "string" }, agent: { type: "string" }, since: TIME, limit: { type: "integer", minimum: 1, maximum: 100, default: 20 } }, []],
  ["remember", TOOL_NAMES.remember, "Backplane memory::remember. Store something worth keeping: where something lives, how an operation is done, or what you did. The current session is attached automatically.",
    { content: { type: "string", minLength: 1 }, kind: { type: "string", enum: KINDS, default: "note" }, title: { type: "string" },
      subjects: { type: "array", items: SUBJECT, description: "e.g. host:<name>, repo:<name>, service:<name>, path:<path>" },
      property: { type: "string" }, tags: { type: "array", items: { type: "string" } } }, ["content"]],
  ["forget", TOOL_NAMES.forget, "Backplane memory::forget. Mark a memory as outdated or forgotten, with a reason.",
    { id: { type: "string" }, reason: { type: "string", minLength: 1 } }, ["id", "reason"]],
];

export class MemoryService {
  constructor(api) {
    this.api = api;
    this.config = configOf(api);
    this.client = new MemoryClient(this.config, api.logger);
    this.closed = false;
    this.running = null;
    this.timer = null;
    this.journal = null;
    this.leaseGeneration = 0;
    this.conversationAccess = api.config?.plugins?.entries?.["backplane-memory"]?.hooks?.allowConversationAccess === true;
  }
  warn(error) { this.api.logger?.warn?.(`backplane-memory: ${safeError(error)}`); }
  instructions() {
    if (this.instructionText === undefined) {
      this.instructionText = loadInstructions();
      if (this.instructionText === null) this.api.logger?.warn?.("backplane-memory: INSTRUCTIONS.md is missing");
    }
    return this.instructionText;
  }
  promptLines() {
    const names = Object.values(TOOL_NAMES).join(", ");
    return [
      ...(this.instructions() ? [this.instructions()] : []),
      `In OpenClaw the memory::search, memory::get, memory::recent, memory::remember and memory::forget tools are named ${names}.`,
    ];
  }
  journalForUse() {
    if (this.closed) throw new Error("provider_disabled");
    if (!this.journal) {
      const root = this.config.journal_path ? null : this.api.runtime?.state?.resolveStateDir?.();
      if (!this.config.journal_path && !root) throw new Error("plugin_state_unavailable");
      const path = this.config.journal_path || join(root, "plugins", "backplane-memory", this.config.profile_id, "delivery.sqlite");
      this.journal = new DeliveryJournal(path, { base_url: this.client.baseUrl, profile_id: this.config.profile_id });
    }
    return this.journal;
  }
  /**
   * OpenClaw's own policy for automatic (hook-driven) recall and capture: a real
   * owner conversation turn, not a maintenance run, a sandboxed caller or an
   * audience shared with other people, and the matching tool not disabled.
   */
  automatic(ctx, tool) {
    if (this.closed || !this.conversationAccess || !ctx?.agentId || !ctx.sessionId || ctx.trigger === "memory" || ctx.sandboxed === true) return false;
    if (ctx.memoryAudience !== undefined && ctx.memoryAudience?.kind !== "owner-private") return false;
    if (!tool || typeof ctx.toolAuthority?.allows !== "function") return true;
    try { return ctx.toolAuthority.allows(tool) === true; } catch { return false; }
  }
  namespace(ctx) {
    return `${this.config.profile_id}:${digest({ agent_id: ctx.agentId, workspace: ctx.workspaceDir ? resolve(ctx.workspaceDir) : null })}`;
  }
  captureEnqueue(ctx, hook, extra) {
    const journal = this.journal, now = new Date().toISOString(), profile_id = this.namespace(ctx);
    const payload = withoutUndefined({
      protocol: CAPTURE_PROTOCOL, event_id: uuid(), installation_id: journal.installationId, profile_id,
      source_sequence: journal.next(`capture:${ctx.agentId}:${ctx.sessionId}`),
      session_id: ctx.sessionId, session_key: ctx.sessionKey, run_id: ctx.runId, agent_id: ctx.agentId,
      occurred_at: now, captured_at: now,
      // Required by openclaw_capture.v1: a stable fingerprint of this capture source (installation and profile).
      binding_fingerprint: digest({ integration: "openclaw", installation_id: journal.installationId, profile_id }),
      ...extra,
    });
    journal.enqueue(payload.event_id, `/capture/v1/hooks/openclaw/${hook}`, payload);
    return payload.event_id;
  }
  async beforePrompt(event, ctx) {
    try {
      if (!this.automatic(ctx)) return;
      const prompt = Object.hasOwn(event ?? {}, "currentUserMessage") ? event.currentUserMessage : event?.prompt;
      if (typeof prompt !== "string") return;
      if (this.automatic(ctx, TOOL_NAMES.remember)) {
        try { this.admitPrompt(event, ctx, prompt); } catch (error) { this.warn(error); }
        void this.drain();
      }
      if (!this.automatic(ctx, TOOL_NAMES.search)) return;
      const query = redactForEgress(prompt).trim();
      if (!query) return;
      const response = await this.client.call("search", { query: query.slice(0, MAX_QUERY_CHARS), limit: this.config.search_limit }, { signal: ctx.signal });
      if (!response.ok || this.closed) return;
      const block = renderContext(response.result, this.config.token_budget);
      return block ? { prependContext: block } : undefined;
    } catch (error) {
      // Recall is best effort: no context, one warning, never an error into OpenClaw.
      this.warn(error);
    }
  }
  /** Durably admit this turn's original input, separately from any recall projection. */
  admitPrompt(event, ctx, prompt) {
    if (!ctx.runId || !ctx.sessionKey || !Array.isArray(event.messages)) throw new Error("capture_boundary_unavailable");
    const wire = redactForEgress(prompt);
    const journal = this.journalForUse();
    const identity = canonicalJson([ctx.agentId, ctx.sessionId, ctx.runId]);
    const fence = { history_count: event.messages.length, history_hash: signature(event.messages), prompt_hash: sha256(prompt), inputProvenance: ctx.inputProvenance || null };
    journal.transaction(() => {
      const existing = journal.db.prepare("SELECT payload FROM turns WHERE identity=?").get(identity);
      if (existing) {
        if (canonicalJson(JSON.parse(existing.payload)) !== canonicalJson(fence)) throw new Error("immutable_turn_conflict");
        return;
      }
      const sessionKey = `session:${ctx.agentId}:${ctx.sessionId}`;
      if (!journal.get(sessionKey)) {
        this.captureEnqueue(ctx, "session-start", {});
        journal.set(sessionKey, { sessionKey: ctx.sessionKey, runId: ctx.runId, ...(ctx.workspaceDir ? { workspaceDir: ctx.workspaceDir } : {}) });
      }
      if (wire.trim()) {
        text(wire);
        this.captureEnqueue(ctx, "message", {
          role: "user", content: wire, occurrence_id: event.currentUserMessageId || `${ctx.runId}:input`, message_index: event.messages.length,
          ...(ctx.inputProvenance ? { input_provenance: JSON.parse(canonicalJson(ctx.inputProvenance)) } : {}),
          completeness: completeness(wire),
        });
      }
      journal.db.prepare("INSERT INTO turns(identity,payload) VALUES (?,?)").run(identity, canonicalJson(fence));
    });
  }
  async agentEnd(event, ctx) {
    try {
      if (!this.automatic(ctx)) return;
      if (!ctx.runId || !Array.isArray(event?.messages)) throw new Error("capture_boundary_unavailable");
      const journal = this.journalForUse();
      const identity = canonicalJson([ctx.agentId, ctx.sessionId, ctx.runId]);
      const turn = journal.db.prepare("SELECT * FROM turns WHERE identity=?").get(identity);
      if (!turn) throw new Error("capture_boundary_unavailable");
      const fence = JSON.parse(turn.payload);
      if (event.messages.length < fence.history_count || signature(event.messages.slice(0, fence.history_count)) !== fence.history_hash) throw new Error("capture_boundary_unavailable");
      const suffix = event.messages.slice(fence.history_count);
      // The first new user projection can contain model-only prependContext. Its
      // original has already been durably admitted, so never ingest it again.
      if (suffix.length && suffix[0]?.role !== "user") throw new Error("capture_boundary_unavailable");
      if (suffix.slice(1).some((row) => row?.role === "user")) throw new Error("capture_boundary_unavailable");
      const projected = suffix.slice(1).flatMap((row, index) => {
        const role = row?.role === "toolResult" ? "tool" : row?.role;
        if (!["assistant", "tool"].includes(role)) return [];
        const content = redactForEgress(extractText(row.content));
        if (!content.trim()) return [];
        text(content);
        return [{ role, content, message_index: fence.history_count + index + 1, ...(row.toolCallId ? { tool_call_id: row.toolCallId } : {}) }];
      });
      // The host starts agent_end hooks without awaiting them: admit synchronously.
      journal.transaction(() => {
        const contentHash = digest(projected);
        const old = journal.get(`terminal:${identity}`);
        if (old && old !== contentHash) throw new Error("immutable_turn_conflict");
        if (turn.completed) return;
        for (const row of projected) this.captureEnqueue(ctx, "message", { ...row, occurrence_id: `${ctx.runId}:message:${row.message_index}`, completeness: completeness(row.content) });
        journal.set(`terminal:${identity}`, contentHash);
        journal.db.prepare("UPDATE turns SET completed=1 WHERE identity=?").run(identity);
      });
      void this.drain();
    } catch (error) { this.warn(error); }
  }
  async sessionEnd(event, ctx) {
    try {
      if (this.closed || !this.conversationAccess) return;
      if (!ctx?.agentId || !ctx.sessionId || !ctx.sessionKey || event?.sessionId !== ctx.sessionId || (event.sessionKey && event.sessionKey !== ctx.sessionKey)) throw new Error("session_identity_unavailable");
      const journal = this.journalForUse();
      const admitted = journal.get(`session:${ctx.agentId}:${ctx.sessionId}`);
      if (!admitted || admitted.sessionKey !== ctx.sessionKey) throw new Error("session_not_admitted");
      // A content-free closure of previously admitted work; it reads no transcript.
      const original = { agentId: ctx.agentId, sessionId: ctx.sessionId, sessionKey: ctx.sessionKey, runId: admitted.runId, ...(admitted.workspaceDir ? { workspaceDir: admitted.workspaceDir } : {}) };
      journal.operation(canonicalJson([ctx.agentId, ctx.sessionId, "session-end"]), { session_key: ctx.sessionKey }, () =>
        this.captureEnqueue(original, "session-end", {
          lifecycle: { reason: ["new", "reset", "idle", "daily", "compaction", "deleted", "shutdown", "restart", "unknown"].includes(event.reason) ? event.reason : "unknown" },
        }));
      void this.drain();
    } catch (error) { this.warn(error); }
  }
  /** One tool call: the host result, or `{ success: false, error, http_status? }`; never throws. */
  async callTool(ctx, method, properties, required, args) {
    args = args && typeof args === "object" && !Array.isArray(args) ? args : {};
    if (required.some((key) => args[key] === undefined || args[key] === null || args[key] === "")) return { success: false, error: "invalid_arguments" };
    const payload = Object.fromEntries(Object.entries(args).filter(([key]) => Object.hasOwn(properties, key)));
    if (method === "remember" && typeof ctx?.sessionId === "string" && ctx.sessionId) payload.session_id = ctx.sessionId;
    const response = await this.client.call(method, payload, { signal: ctx?.signal });
    return response.ok ? response.result : failed(response);
  }
  tools(ctx) {
    return TOOLS.map(([method, name, description, properties, required]) => ({
      name, label: name, description,
      parameters: { type: "object", additionalProperties: false, properties, required },
      execute: async (_toolCallId, args) => {
        if (this.closed) return toolResult({ success: false, error: "provider_disabled" });
        return toolResult(await this.callTool(ctx, method, properties, required, args));
      },
    }));
  }
  async open({ context, purpose } = {}) {
    let closed = false;
    const generation = this.leaseGeneration;
    const check = () => { if (closed || this.closed || generation !== this.leaseGeneration) throw new Error("provider_lease_closed"); context?.assertCurrent?.(); };
    const call = async (method, args) => {
      const response = await this.client.call(method, args, { signal: context?.signal });
      check();
      return response;
    };
    return { provider: {
      capabilities: { sources: ["memory"], pagination: false, candidates: [], projectFilter: false },
      // Health does no I/O; each request reports its own failure.
      health: async () => { check(); return { status: "ok", details: { purpose: purpose || "default" } }; },
      search: async (request) => {
        check();
        if (request.cursor || request.activeProjectKeys?.length || request.sources?.some((source) => source !== "memory") || (request.minScore !== undefined && request.minScore !== 0)) throw new Error("unsupported_search_filter");
        const query = redactForEgress(String(request.query ?? "")).trim();
        if (!query) throw new Error("invalid_arguments");
        const response = await call("search", { query: query.slice(0, MAX_QUERY_CHARS), limit: Math.min(50, Math.max(1, request.maxResults || 10)) });
        if (!response.ok) throw new Error(safeError(response.error));
        const rows = (Array.isArray(response.result.results) ? response.result.results : []).filter((row) => describe(row) && typeof row.id === "string" && row.id);
        return { hits: rows.map((row) => ({
          reference: { providerId: "backplane-memory", id: row.id },
          excerpt: row.content.trim(), source: describe(row).join("; "), citations: [],
          automaticRecall: { eligible: true },
        })), coverage: "complete" };
      },
      get: async ({ reference, from, lines }) => {
        check();
        if (reference?.providerId !== "backplane-memory" || typeof reference.id !== "string" || !reference.id || from !== undefined || lines !== undefined || reference.fragment) throw new Error("invalid_reference");
        const response = await call("get", { id: reference.id });
        if (!response.ok) {
          if (response.status === 404) return { status: "not_found" };
          throw new Error(safeError(response.error));
        }
        if (typeof response.result.record?.content !== "string") throw new Error("invalid_response");
        return { status: "ok", reference, text: response.result.record.content, truncated: false };
      },
      close: async () => { closed = true; },
    } };
  }
  async closeSearchLeases() {
    // Host manager maintenance/reload revokes leases, not plugin delivery ownership.
    this.leaseGeneration += 1;
  }
  flushPlan() {
    if (this.closed || this.config.enabled === false) return null;
    return {
      persistenceToolNames: [TOOL_NAMES.remember],
      lookupToolNames: [TOOL_NAMES.search, TOOL_NAMES.get, TOOL_NAMES.recent],
      prompt: `Before compaction, if this conversation produced something worth keeping across sessions — where something lives, how an operation is done, or what you did — save it once with ${TOOL_NAMES.remember} (kind fact, procedure, worklog or note). Check ${TOOL_NAMES.search} first to avoid duplicates; search/get/recent are not persistence. Do not save raw conversation or speculation. If there is nothing new to keep, finish with NO_REPLY.`,
      systemPrompt: "This is the Backplane memory flush before compaction. Most conversations need nothing remembered. Finish with NO_REPLY after saving or when there is nothing to save. Failure does not block compaction.",
    };
  }
  async drain() {
    if (this.closed || this.config.enabled === false) return;
    // Work queued while a pass is running gets one more pass instead of waiting for the timer.
    this.drainRequested = true;
    if (this.running) return this.running;
    this.running = (async () => {
      while (this.drainRequested && !this.closed) {
        this.drainRequested = false;
        await this.deliverOnce();
      }
    })().catch((error) => this.warn(error)).finally(() => { this.running = null; });
    return this.running;
  }
  async deliverOnce() {
    const journal = this.journalForUse();
    for (const row of journal.due()) {
      if (this.closed) return;
      const hook = row.path.split("/").at(-1);
      let response;
      if (row.state === "host_accepted") response = await this.client.request("/capture/v1/status", { event_ids: [row.event_id], protocol: CAPTURE_PROTOCOL }, { label: "capture status" });
      else response = await this.client.request(row.path, JSON.parse(row.payload), { label: `capture ${hook}` });
      if (this.closed) return;
      if (!response.ok) {
        const terminal = TERMINAL_STATUS.has(response.status);
        journal.fail(row.event_id, safeError(response.error), { terminal });
        // A rejected row fails alone; anything retryable holds later rows in order.
        if (terminal) continue;
        return;
      }
      if (row.state === "host_accepted") {
        const item = Array.isArray(response.result?.items) ? response.result.items.find((entry) => entry?.event_id === row.event_id) : undefined;
        if (item?.status === "canonical_committed") journal.settle(row.event_id, "canonical_committed", { status: item.status });
        else if (item?.status === "rejected") journal.settle(row.event_id, "rejected", { status: item.status, error_code: safeError(item.error_code) });
        // Still spooled on the host (e.g. the gateway is offline): ask again later without spending retries.
        else if (item?.status === "host_accepted") journal.settle(row.event_id, "host_accepted", { status: item.status }, { delay: STATUS_POLL_MS });
        else journal.fail(row.event_id, "capture_status_unknown");
      } else if (["accepted", "duplicate"].includes(response.status) && response.event_id === row.event_id) {
        journal.settle(row.event_id, "host_accepted", { status: response.status });
      } else {
        journal.fail(row.event_id, "invalid_response");
        this.warn("invalid_capture_receipt");
        return;
      }
    }
  }
  start() {
    if (this.closed || this.config.enabled === false) return;
    this.journalForUse();
    this.timer ||= setInterval(() => { void this.drain(); }, 1000);
    this.timer.unref();
    void this.drain();
  }
  async stop() {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.timer); this.timer = null;
    this.client.close();
    await this.running;
    this.journal?.close(); this.journal = null;
  }
}

export const createMemoryService = (api) => new MemoryService(api);
