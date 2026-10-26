import { constants, closeSync, fstatSync, lstatSync, openSync, readFileSync, readdirSync, realpathSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { CAPTURE_PROTOCOL, MAX_CONTENT_BYTES, SOURCE_CAPABILITY, SOURCE_PROTOCOL, TOOL_NAMES, canonicalJson, digest, extractText, isUuid, redactForEgress, sha256, sourceSnapshot, text, uuid } from "./contract.mjs";
import { DeliveryJournal } from "./journal.mjs";
import { MemoryClient, MemoryRequestError, safeError } from "./client.mjs";
import { eligibleRows, renderContext } from "./context.mjs";

export const configSchema = {
  type: "object", additionalProperties: false,
  properties: {
    enabled: { type: "boolean" }, base_url: { type: "string" }, agent_id: { type: "string" },
    profile_id: { type: "string", minLength: 1, maxLength: 128 }, journal_path: { type: "string" },
    token_budget: { type: "integer", minimum: 128, maximum: 32768 },
    min_confidence: { type: "number", description: "Deprecated reserved option; ignored with a diagnostic." },
    fallback_on_error: { type: "boolean" }, timeout_ms: { type: "integer", minimum: 100, maximum: 20000 },
    native_sync: { type: "boolean" },
    bindings: { type: "array", maxItems: 64, items: {
      type: "object", additionalProperties: false, required: ["agent_id", "memory_access_id"],
      properties: { agent_id: { type: "string", minLength: 1 }, memory_access_id: { type: "string", format: "uuid" } },
    } },
  },
};

function configOf(api) {
  const supplied = api.pluginConfig || {};
  const config = { enabled: true, base_url: "http://127.0.0.1:4222", agent_id: "openclaw", profile_id: "default", token_budget: 2000, fallback_on_error: true, timeout_ms: 5000, native_sync: true, bindings: [], ...supplied };
  if (!Number.isInteger(config.token_budget) || config.token_budget < 128 || config.token_budget > 32768 || !Number.isInteger(config.timeout_ms) || config.timeout_ms < 100 || config.timeout_ms > 20000) throw new Error("invalid_config");
  if (!/^[A-Za-z0-9_.-]{1,128}$/.test(config.profile_id) || !Array.isArray(config.bindings) || config.bindings.length > 64 || config.bindings.some((row) => !row || !isUuid(row.memory_access_id) || typeof row.agent_id !== "string" || !row.agent_id)) throw new Error("invalid_bindings");
  if (new Set(config.bindings.map((row) => row.agent_id)).size !== config.bindings.length) throw new Error("ambiguous_bindings");
  if (Object.hasOwn(supplied, "min_confidence")) api.logger?.warn?.("backplane-memory: min_confidence_deprecated; reserved option ignored; canonical relevance policy applies");
  return config;
}
function signature(messages) {
  // A local equality fence, never an occurrence identity or a wire hash. Message
  // tool arguments may contain floats even though the wire contract may not.
  return sha256(JSON.stringify(messages.map((message) => ({ role: message?.role ?? null, content: message?.content ?? null, provenance: message?.provenance ?? null, toolCallId: message?.toolCallId ?? null }))));
}
function provenance(ctx, role, occurrenceId, messageIndex) {
  const value = { session_id: ctx.sessionId, session_key: ctx.sessionKey, role, write_origin: "openclaw.provider", occurrence_id: occurrenceId };
  if (ctx.runId) value.run_id = ctx.runId;
  if (ctx.inputProvenance) value.input_provenance = JSON.parse(canonicalJson(ctx.inputProvenance));
  if (messageIndex !== undefined) value.message_index = messageIndex;
  return value;
}
const toolResult = (result) => ({ content: [{ type: "text", text: JSON.stringify(result) }], details: result });

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
  journalForUse() {
    if (this.closed) throw new Error("provider_disabled");
    if (!this.journal) {
      const root = this.config.journal_path ? null : this.api.runtime?.state?.resolveStateDir?.();
      if (!this.config.journal_path && !root) throw new Error("plugin_state_unavailable");
      const path = this.config.journal_path || join(root, "plugins", "backplane-memory", this.config.profile_id, "delivery.sqlite");
      this.journal = new DeliveryJournal(path, { base_url: this.client.baseUrl, profile_id: this.config.profile_id, bindings: this.config.bindings });
    }
    return this.journal;
  }
  authorize(ctx, { hook = false, tool, provider = false } = {}) {
    const binding = this.config.bindings.find((row) => row.agent_id === ctx?.agentId);
    const guard = () => {
      if (this.closed || this.config.enabled === false) throw new Error("provider_disabled");
      if (!ctx?.agentId || !ctx.sessionId || !ctx.sessionKey || !binding) throw new Error("audience_binding_unavailable");
      if (ctx.sandboxed !== false) throw new Error("sandbox_policy_denied");
      if (ctx.memoryAudience?.kind !== "owner-private") throw new Error("unsupported_memory_audience");
      if (ctx.memoryAudience.agentId !== ctx.agentId) throw new Error("audience_agent_mismatch");
      if (typeof ctx.assertMemoryAudienceCurrent !== "function") throw new Error("audience_authority_unavailable");
      ctx.assertMemoryAudienceCurrent();
      if (provider) ctx.assertInvocationCurrent();
      else if (hook) {
        if (!this.conversationAccess) throw new Error("conversation_access_required");
        if (tool) {
          if (!ctx.toolAuthority || !ctx.hookInvocation) throw new Error("tool_authority_unavailable");
          ctx.toolAuthority.assertActive(); ctx.hookInvocation.assertActive();
          if (!(Array.isArray(tool) ? tool : [tool]).every((name) => ctx.toolAuthority.allows(name))) throw new Error("tool_policy_denied");
        }
      } else {
        if (typeof ctx.assertInvocationCurrent !== "function") throw new Error("invocation_authority_unavailable");
        ctx.assertInvocationCurrent();
      }
    };
    guard();
    return { accessId: binding.memory_access_id, guard, agentId: ctx.agentId, ctx };
  }
  async peer(invocation, { admitOffline = false, capture = false, requireWrite = false } = {}) {
    const journal = this.journalForUse();
    const key = `binding:${invocation.accessId}`;
    let peer;
    try {
      peer = await this.client.capabilities(invocation.agentId, invocation.accessId, invocation.guard, { requireWrite });
      invocation.guard();
      const old = journal.get(key);
      if (old && old.binding_fingerprint !== peer.binding_fingerprint) throw new MemoryRequestError("binding_changed");
      if (capture && (!peer.contracts.includes(CAPTURE_PROTOCOL) || !peer.negotiated.includes(CAPTURE_PROTOCOL) || peer.capture_ready !== true || peer.capture_binding_fingerprint !== peer.binding_fingerprint)) throw new MemoryRequestError("capture_binding_mismatch");
      journal.set(key, peer);
    } catch (error) {
      const transport = !(error instanceof MemoryRequestError) || error.status >= 500;
      if (!admitOffline || !transport) throw error;
      peer = journal.get(key);
      if (!peer) throw new MemoryRequestError("binding_unverified");
      if (requireWrite && peer.ready !== true) throw new MemoryRequestError("source_unavailable");
      if (capture && (peer.capture_ready !== true || peer.capture_binding_fingerprint !== peer.binding_fingerprint)) throw new MemoryRequestError("capture_binding_mismatch");
      invocation.guard();
    }
    return peer;
  }
  namespace(ctx) {
    return `${this.config.profile_id}:${digest({ agent_id: ctx.agentId, workspace: ctx.workspaceDir ? resolve(ctx.workspaceDir) : null })}`;
  }
  source(ctx, target) {
    return { integration: "openclaw", installation_id: this.journalForUse().installationId, profile_id: this.namespace(ctx), target };
  }
  enqueue(method, payload, peer, agentId) {
    const args = { ...payload, memory_access_id: peer.binding.access_id };
    return this.journal.enqueue(payload.event_id, this.client.path(agentId, method), args, { agent_id: agentId, binding: peer.binding, fingerprint: peer.binding_fingerprint });
  }
  capturePayload(ctx, hook, peer, extra = {}) {
    const now = new Date().toISOString();
    return {
      protocol: CAPTURE_PROTOCOL, event_id: uuid(), installation_id: this.journal.installationId,
      profile_id: this.namespace(ctx), source_sequence: this.journal.next(`capture:${ctx.agentId}:${ctx.sessionId}`),
      session_id: ctx.sessionId, session_key: ctx.sessionKey, run_id: ctx.runId,
      agent_id: ctx.agentId, occurred_at: now, captured_at: now, binding_fingerprint: peer.binding_fingerprint,
      ...extra,
    };
  }
  captureEnqueue(ctx, hook, peer, extra) {
    const payload = this.capturePayload(ctx, hook, peer, extra);
    this.journal.enqueue(payload.event_id, `/capture/v1/hooks/openclaw/${hook}`, payload,
      { agent_id: ctx.agentId, binding: peer.binding, fingerprint: peer.binding_fingerprint });
    return payload.event_id;
  }
  async beforePrompt(event, ctx) {
    // The host's detached maintenance input is not an original conversation turn.
    // Its provider-owned tools perform their own audience/policy admission.
    if (ctx.trigger === "memory") return;
    try {
      const prompt = Object.hasOwn(event, "currentUserMessage") ? event.currentUserMessage : event.prompt;
      if (typeof prompt !== "string") throw new Error("capture_boundary_unavailable");
      // Recall and persistence have separate policy admission. Denying a save
      // tool cannot grant capture, nor does it revoke an admitted read tool.
      this.authorize(ctx, { hook: true });
      let captureInvocation;
      try { captureInvocation = this.authorize(ctx, { hook: true, tool: TOOL_NAMES.save }); }
      catch (error) { this.warn(error); }
      if (captureInvocation) {
        try { await this.admitPrompt(event, ctx, prompt, captureInvocation); }
        catch (error) { this.warn(error); }
      }
      const invocation = this.authorize(ctx, { hook: true, tool: TOOL_NAMES.search });
      const journal = this.journalForUse();
      await this.peer(invocation);
      if (!prompt.trim()) return;
      const result = await this.client.call(ctx.agentId, "recall", { query: text(redactForEgress(prompt), 4096), token_budget: this.config.token_budget, limit: 20, memory_access_id: invocation.accessId }, invocation.guard);
      invocation.guard();
      const block = renderContext(eligibleRows(result, { journal, namespace: this.namespace(ctx) }), this.config.token_budget);
      return block ? { prependContext: block } : undefined;
    } catch (error) {
      this.warn(error);
      if (this.config.fallback_on_error === false) throw new Error(safeError(error));
    }
  }
  async admitPrompt(event, ctx, prompt, invocation) {
    if (!ctx.runId || !Array.isArray(event.messages)) throw new Error("capture_boundary_unavailable");
    const wire = redactForEgress(prompt);
    const peer = await this.peer(invocation, { admitOffline: true, capture: true, requireWrite: true });
    invocation.guard();
    const journal = this.journalForUse();
    const identity = canonicalJson([ctx.agentId, ctx.sessionId, ctx.runId]);
    const fence = { history_count: event.messages.length, history_hash: signature(event.messages), prompt_hash: sha256(prompt), inputProvenance: ctx.inputProvenance || null };
    journal.transaction(() => {
      invocation.guard();
      const existing = journal.db.prepare("SELECT payload FROM turns WHERE identity=?").get(identity);
      if (existing) {
        if (canonicalJson(JSON.parse(existing.payload)) !== canonicalJson(fence)) throw new Error("immutable_turn_conflict");
      } else {
        if (!journal.get(`session:${ctx.agentId}:${ctx.sessionId}`)) {
          this.captureEnqueue(ctx, "session-start", peer, {});
          journal.set(`session:${ctx.agentId}:${ctx.sessionId}`, {
            sessionKey: ctx.sessionKey, runId: ctx.runId,
            ...(ctx.workspaceDir ? { workspaceDir: ctx.workspaceDir } : {}), peer,
          });
        }
        if (wire.trim()) {
          text(wire);
          this.captureEnqueue(ctx, "message", peer, {
            role: "user", content: wire, occurrence_id: event.currentUserMessageId || `${ctx.runId}:input`, message_index: event.messages.length,
            ...(ctx.inputProvenance ? { input_provenance: ctx.inputProvenance } : {}),
            completeness: { truncated: false, original_length: [...wire].length, original_sha256: sha256(wire), coverage: "full" },
          });
        }
        journal.db.prepare("INSERT INTO turns(identity,payload) VALUES (?,?)").run(identity, canonicalJson(fence));
      }
    });
    if (this.config.native_sync) {
      try { this.syncNative(ctx, this.authorize(ctx, { hook: true, tool: [TOOL_NAMES.save, TOOL_NAMES.correct, TOOL_NAMES.withdraw] }), peer); }
      catch (error) { this.warn(error); }
    }
    await this.drain();
  }
  async agentEnd(event, ctx) {
    if (ctx.trigger === "memory") return;
    try {
      const invocation = this.authorize(ctx, { hook: true });
      if (!ctx.runId || !Array.isArray(event.messages)) throw new Error("capture_boundary_unavailable");
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
      const peer = await this.peer(invocation, { admitOffline: true, capture: true, requireWrite: true });
      invocation.guard();
      journal.transaction(() => {
        invocation.guard();
        const contentHash = digest(projected);
        const old = journal.get(`terminal:${identity}`);
        if (old && old !== contentHash) throw new Error("immutable_turn_conflict");
        if (turn.completed) return;
        for (const row of projected) this.captureEnqueue(ctx, "message", peer, {
          ...row, occurrence_id: `${ctx.runId}:message:${row.message_index}`,
          completeness: { truncated: false, original_length: [...row.content].length, original_sha256: sha256(row.content), coverage: "full" },
        });
        journal.set(`terminal:${identity}`, contentHash);
        journal.db.prepare("UPDATE turns SET completed=1 WHERE identity=?").run(identity);
      });
      // Native reads run at before_prompt_build, where the finalized tool
      // surface supplies live policy authority. agent_end has no such token.
      await this.drain();
    } catch (error) {
      this.warn(error);
      if (this.config.fallback_on_error === false) throw new Error(safeError(error));
    }
  }
  async sessionEnd(event, ctx) {
    try {
      if (this.closed || !this.config.enabled || !this.conversationAccess) return;
      if (!ctx?.agentId || !ctx.sessionId || !ctx.sessionKey || event?.sessionId !== ctx.sessionId || (event.sessionKey && event.sessionKey !== ctx.sessionKey)) throw new Error("session_identity_unavailable");
      const journal = this.journalForUse();
      const admitted = journal.get(`session:${ctx.agentId}:${ctx.sessionId}`);
      if (!admitted || admitted.sessionKey !== ctx.sessionKey) throw new Error("session_not_admitted");
      // A content-free historical closure of previously admitted work. This does
      // not create authority to read endedTranscript or capture additional text.
      const original = { agentId: ctx.agentId, sessionId: ctx.sessionId, sessionKey: ctx.sessionKey, runId: admitted.runId,
        ...(admitted.workspaceDir ? { workspaceDir: admitted.workspaceDir } : {}) };
      journal.operation(canonicalJson([ctx.agentId, ctx.sessionId, "session-end"]), { session_key: ctx.sessionKey }, () =>
        this.captureEnqueue(original, "session-end", admitted.peer, {
          lifecycle: { reason: ["new", "reset", "idle", "daily", "compaction", "deleted", "shutdown", "restart", "unknown"].includes(event.reason) ? event.reason : "unknown" },
        }));
      await this.drain();
    } catch (error) { this.warn(error); }
  }
  syncNative(ctx, invocation, peer) {
    const namespace = this.namespace(ctx);
    const journal = this.journal;
    const targets = [["user", "USER.md"], ["memory", "MEMORY.md"]];
    try {
      invocation.guard();
      if (!ctx.workspaceDir) throw new Error("native_workspace_unavailable");
      const root = realpathSync(ctx.workspaceDir);
      const rootBefore = statSync(root, { bigint: true });
      const names = readdirSync(root);
      const documents = targets.map(([target, relative]) => {
        invocation.guard();
        const path = join(root, relative);
        let before;
        try { before = lstatSync(path, { bigint: true }); }
        catch (error) {
          if (error.code !== "ENOENT" || names.includes(relative) || readdirSync(root).includes(relative)) throw new Error("native_inventory_unavailable");
          return { target, relative, content: "", exists: false };
        }
        if (!before.isFile() || before.isSymbolicLink() || before.size > BigInt(MAX_CONTENT_BYTES)) throw new Error("native_inventory_unsupported");
        const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
        let bytes, after;
        try { bytes = readFileSync(fd); after = fstatSync(fd, { bigint: true }); }
        finally { closeSync(fd); }
        const final = lstatSync(path, { bigint: true });
        for (const field of ["dev", "ino", "size", "mtimeNs", "ctimeNs"]) if (before[field] !== after[field] || before[field] !== final[field]) throw new Error("native_snapshot_changed");
        const raw = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
        return { target, relative, content: redactForEgress(raw), exists: true };
      });
      const rootAfter = statSync(root, { bigint: true });
      for (const field of ["dev", "ino", "mtimeNs", "ctimeNs"]) if (rootBefore[field] !== rootAfter[field]) throw new Error("native_snapshot_changed");
      journal.transaction(() => {
        invocation.guard();
        for (const document of documents) {
          const source = this.source(ctx, document.target);
          const previous = journal.sources(namespace).find((row) => row.target === document.target && row.kind === "native");
          const hash = sha256(document.content);
          const active = document.exists && Boolean(document.content.trim());
          if (previous && previous.content_hash === hash && Boolean(previous.active) === active) continue;
          const entry_id = previous?.entry_id || uuid();
          const revision = journal.next(`source:${namespace}:${document.target}`);
          const commonProvenance = { ...provenance(ctx, "operator", `${ctx.runId}:native:${document.relative}`), write_origin: "openclaw.native", document_path: document.relative, document_revision: hash, document_sha256: hash, document_complete: true };
          if (active) text(document.content);
          const payload = { protocol: SOURCE_PROTOCOL, source, entry_id, event_id: uuid(), revision,
            operation: active ? "upsert" : "withdraw", type: "semantic", occurred_at: new Date().toISOString(), provenance: commonProvenance,
            ...(active ? { content: document.content } : {}) };
          this.enqueue("source_mutate", payload, peer, ctx.agentId);
          const entries = active ? [{ entry_id, content: document.content, type: "semantic", provenance: commonProvenance }] : [];
          for (const command of sourceSnapshot(source, entries, journal.next(`source:${namespace}:${document.target}`))) this.enqueue("source_reconcile", command, peer, ctx.agentId);
          journal.db.prepare(`INSERT INTO sources(namespace,target,entry_id,revision,active,content_hash,kind) VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(entry_id) DO UPDATE SET revision=excluded.revision,active=excluded.active,content_hash=excluded.content_hash`)
            .run(namespace, document.target, entry_id, revision, active ? 1 : 0, hash, "native");
        }
        journal.set(`native_blocked:${namespace}`, []);
      });
    } catch (error) {
      journal.set(`native_blocked:${namespace}`, targets.map(([target]) => target));
      this.warn(error);
      return { complete: false, error: safeError(error) };
    }
    return { complete: true };
  }
  async read(ctx, method, args, options = {}) {
    const invocation = this.authorize(ctx, options);
    await this.peer(invocation);
    const result = await this.client.call(ctx.agentId, method, { ...args, memory_access_id: invocation.accessId }, invocation.guard, ctx.signal);
    invocation.guard();
    return result;
  }
  status(ctx, options = {}) {
    this.authorize(ctx, options).guard();
    const journal = this.journalForUse();
    const namespace = this.namespace(ctx);
    return { ...journal.status(), source_identities: journal.sources(namespace).map(({ entry_id, target, revision, active, canonical_id, kind }) => ({ entry_id, target, revision, active: active === 1, canonical_id, kind })) };
  }
  async mutate(ctx, action, args, toolCallId) {
    const invocation = this.authorize(ctx);
    const peer = await this.peer(invocation, { admitOffline: true, requireWrite: true });
    const journal = this.journalForUse();
    const namespace = this.namespace(ctx);
    if (!toolCallId || typeof toolCallId !== "string") throw new Error("occurrence_identity_unavailable");
    let entry = args.entry_id ? journal.sources(namespace).find((row) => row.entry_id === args.entry_id) : null;
    if (action !== "save" && (!isUuid(args.entry_id) || !entry)) throw new Error("provider_source_not_found");
    if (entry?.kind !== undefined && entry.kind !== "provider") throw new Error("native_file_owned");
    const content = action === "withdraw" ? undefined : text(redactForEgress(args.content));
    const occurrence = ctx.memoryFlush?.flushId
      ? canonicalJson([ctx.agentId, "flush", ctx.memoryFlush.flushId, action, args.fact_key || args.entry_id || "default"])
      : canonicalJson([ctx.agentId, ctx.sessionId, toolCallId]);
    let entry_id;
    const eventId = journal.operation(occurrence, { action, entry_id: args.entry_id || null, content: content ?? null }, () => {
      invocation.guard();
      ctx.assertInputCommitAllowed?.();
      entry_id = entry?.entry_id || uuid();
      const revision = journal.next(`source:${namespace}:provider`);
      const payload = { protocol: SOURCE_PROTOCOL, source: this.source(ctx, "provider"), entry_id, event_id: uuid(), revision,
        operation: action === "withdraw" ? "withdraw" : "upsert", type: "semantic", occurred_at: new Date().toISOString(),
        provenance: { ...provenance(ctx, "assistant", ctx.memoryFlush?.flushId || toolCallId), tool_call_id: toolCallId },
        ...(content !== undefined ? { content } : {}) };
      this.enqueue("source_mutate", payload, peer, ctx.agentId);
      journal.db.prepare(`INSERT INTO sources(namespace,target,entry_id,revision,active,content_hash,kind) VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(entry_id) DO UPDATE SET revision=excluded.revision,active=excluded.active,content_hash=excluded.content_hash`)
        .run(namespace, "provider", entry_id, revision, action === "withdraw" ? 0 : 1, content ? sha256(content) : null, "provider");
      return payload.event_id;
    });
    await this.drain();
    invocation.guard();
    const row = journal.row(eventId);
    const payload = JSON.parse(row.payload);
    return { event_id: eventId, entry_id: payload.entry_id, status: row.state, ...(row.receipt ? { receipt: JSON.parse(row.receipt) } : {}) };
  }
  tools(ctx) {
    const make = (name, description, properties, required, execute) => ({
      name, label: name, description,
      parameters: { type: "object", additionalProperties: false, properties, required },
      execute: async (toolCallId, args) => {
        try { this.authorize(ctx); return toolResult(await execute(args, toolCallId)); }
        catch (error) { throw new Error(safeError(error)); }
      },
    });
    const string = { type: "string" };
    const id = { type: "string", format: "uuid" };
    return [
      make(TOOL_NAMES.search, "Search authorized current Backplane memory. Failures are errors; pending local results remain provisional.", { query: string }, ["query"], async (args) => {
        const result = await this.read(ctx, "recall", { query: text(redactForEgress(args.query), 4096), token_budget: this.config.token_budget, limit: 20 });
        const rows = eligibleRows(result, { journal: this.journal, namespace: this.namespace(ctx) });
        return {
          results: rows.filter((row) => row.provisional !== true && row.authority !== "provisional"),
          provisional_results: rows.filter((row) => row.provisional === true || row.authority === "provisional"),
          ...Object.fromEntries(["mode", "authority", "consistency", "stale"].filter((key) => result[key] !== undefined).map((key) => [key, result[key]])),
        };
      }),
      make(TOOL_NAMES.get, "Read one exact canonical Backplane memory UUID. Summary, trace and pending IDs are not canonical IDs.", { id }, ["id"], async (args) => {
        if (!isUuid(args.id)) throw new Error("invalid_canonical_id");
        return this.read(ctx, "get", { id: args.id });
      }),
      make(TOOL_NAMES.save, "Durably save a provider-owned candidate fact. Native files remain authoritative and unchanged. fact_key distinguishes facts within a flush and must be stable across retries.", { content: string, fact_key: string }, ["content"], (args, callId) => this.mutate(ctx, "save", args, callId)),
      make(TOOL_NAMES.correct, "Replace an exact provider-owned entry_id returned by save/status. Native-backed entries require editing their native file.", { entry_id: id, content: string }, ["entry_id", "content"], (args, callId) => this.mutate(ctx, "correct", args, callId)),
      make(TOOL_NAMES.withdraw, "Withdraw only one exact provider source contribution. Independently supported canonical facts survive. Native text is unchanged.", { entry_id: id }, ["entry_id"], (args, callId) => this.mutate(ctx, "withdraw", args, callId)),
      make(TOOL_NAMES.forget, "Explicit global forget of one exact canonical UUID, across all source support. Does not edit native files; later reconciliation cannot undo this suppression.", { id, confirm_global: { type: "boolean", const: true } }, ["id", "confirm_global"], async (args) => {
        if (!isUuid(args.id) || args.confirm_global !== true) throw new Error("explicit_global_forget_required");
        return this.read(ctx, "forget", { id: args.id });
      }),
      make(TOOL_NAMES.status, "Report delivery states and exact source identities without memory bodies. Local acceptance is not canonical commit.", {}, [], async () => { await this.drain(); return this.status(ctx); }),
    ];
  }
  async open({ agentId, context, purpose }) {
    const assertSessionCaller = () => {
      context.assertCurrent();
      if (context.authority?.kind !== "session") throw new Error("unsupported_caller_authority");
    };
    const ctx = { agentId, sessionId: context?.authority?.sessionId, sessionKey: context?.authority?.sessionKey,
      memoryAudience: context?.authority?.audience, sandboxed: context?.authority?.sandboxed,
      assertMemoryAudienceCurrent: assertSessionCaller, assertInvocationCurrent: assertSessionCaller, signal: context?.signal };
    const health = async () => {
      context.assertCurrent();
      if (this.closed || this.config.enabled === false) return { status: "unavailable", message: "provider_disabled" };
      // Host status authority has no content grant. Health intentionally does no I/O.
      const configured = this.config.bindings.some((row) => row.agent_id === agentId);
      return { status: configured ? "degraded" : "unavailable", message: configured ? "configured; durable/canonical readiness requires an authorized session probe" : "audience_binding_unavailable", details: { purpose: purpose || "default" } };
    };
    let closed = false;
    const generation = this.leaseGeneration;
    const check = () => { if (closed || this.closed || generation !== this.leaseGeneration) throw new Error("provider_lease_closed"); context.assertCurrent(); };
    return { provider: {
      capabilities: { sources: ["memory"], pagination: false, candidates: [], projectFilter: false },
      health: async () => { check(); return health(); },
      search: async (request) => {
        check();
        if (request.cursor || request.activeProjectKeys?.length || request.sources?.some((source) => source !== "memory") || (request.minScore !== undefined && request.minScore !== 0)) throw new Error("unsupported_search_filter");
        const result = await this.read(ctx, "recall", { query: text(redactForEgress(request.query), 4096), limit: Math.min(100, Math.max(1, request.maxResults || 20)), token_budget: this.config.token_budget }, { provider: true });
        check();
        const eligible = eligibleRows(result, { journal: this.journal, namespace: this.namespace(ctx) });
        const records = eligible.filter((row) => row.kind === "memory" || row.canonical_id || row.provisional === true || row.authority === "provisional");
        return { hits: records.map((row) => ({
          reference: { providerId: "backplane-memory", id: (row.provisional === true || row.authority === "provisional" ? "pending:" : "") + (row.canonical_id || row.id), ...(row.revision !== undefined ? { revision: String(row.revision) } : {}) },
          excerpt: row.content, source: row.provisional || row.authority === "provisional" ? "pending local memory" : row.trust,
          citations: row.source_refs.map((ref) => ({ label: `${ref.source?.integration}:${ref.entry_id}@${ref.source_revision}` })),
          automaticRecall: { eligible: true },
        })), coverage: eligible.length === records.length ? "complete" : "partial" };
      },
      get: async ({ reference, from, lines }) => {
        check();
        if (reference?.providerId !== "backplane-memory" || !isUuid(reference.id) || from !== undefined || lines !== undefined || reference.fragment) throw new Error("invalid_reference");
        try {
          const result = await this.read(ctx, "get", { id: reference.id }, { provider: true });
          check();
          if (!result.record || typeof result.record.content !== "string") throw new Error("invalid_response");
          if (reference.revision !== undefined && String(result.record.revision) !== reference.revision) throw new Error("reference_revision_changed");
          return { status: "ok", reference, text: result.record.content, truncated: false };
        } catch (error) { if (error instanceof MemoryRequestError && error.code === "not_found") return { status: "not_found" }; throw error; }
      },
      close: async () => { closed = true; },
    } };
  }
  async closeSearchLeases() {
    // Host manager maintenance/reload revokes leases, not plugin delivery ownership.
    this.leaseGeneration += 1;
  }
  flushPlan() {
    if (this.closed || !this.config.enabled || !this.config.bindings.length) return null;
    return {
      persistenceToolNames: [TOOL_NAMES.save, TOOL_NAMES.correct], lookupToolNames: [TOOL_NAMES.search, TOOL_NAMES.get, TOOL_NAMES.status],
      prompt: `Before optional compaction, preserve only durable, source-supported new conclusions through ${TOOL_NAMES.save} or correct an exact provider entry with ${TOOL_NAMES.correct}. Use stable fact_key values for separate facts. Search/get may inspect existing facts but are not persistence. Do not copy raw conversations or assistant speculation as established fact. Do not edit native USER.md/MEMORY.md through this provider. If there is nothing new to persist, finish with NO_REPLY.`,
      systemPrompt: "This is the Backplane provider-owned memory flush. Tool policy and caller audience still apply. A local_pending or host_accepted receipt is durable acceptance, not canonical completion. Finish with NO_REPLY after successful persistence or a legitimate no-op. Failure does not promise to block compaction.",
    };
  }
  async drain() {
    if (this.closed || !this.config.enabled) return;
    if (this.running) return this.running;
    this.running = this.deliverOnce().finally(() => { this.running = null; });
    return this.running;
  }
  async deliverOnce() {
    const journal = this.journalForUse();
    for (const row of journal.due()) {
      if (this.closed) return;
      try {
        const admitted = JSON.parse(row.binding);
        const peer = await this.client.capabilities(admitted.agent_id, admitted.binding.access_id, undefined, { requireWrite: true });
        if (peer.binding_fingerprint !== admitted.fingerprint) throw new MemoryRequestError("binding_changed");
        const payload = JSON.parse(row.payload);
        const capture = row.path.startsWith("/capture/");
        if (capture && (peer.capture_ready !== true || peer.capture_binding_fingerprint !== admitted.fingerprint || !peer.negotiated.includes(CAPTURE_PROTOCOL))) throw new MemoryRequestError("capture_binding_mismatch");
        let receipt;
        if (row.state === "host_accepted") {
          if (capture) {
            const response = await this.client.request("/capture/v1/status", { event_ids: [row.event_id], protocol: CAPTURE_PROTOCOL });
            if (response.result?.protocol !== CAPTURE_PROTOCOL) throw new MemoryRequestError("invalid_response");
            const item = response.result.items?.find((item) => item.event_id === row.event_id);
            receipt = { ...item, status: { canonical_committed: "committed", host_accepted: "pending", rejected: "rejected" }[item?.status] };
          } else receipt = await this.client.call(admitted.agent_id, "source_status", { source: payload.source, event_id: row.event_id, memory_access_id: admitted.binding.access_id });
        } else if (capture) {
          const response = await this.client.request(row.path, payload);
          if (!["accepted", "duplicate"].includes(response.status) || response.event_id !== row.event_id) throw new MemoryRequestError("invalid_response");
          receipt = { event_id: row.event_id, status: "pending", authority: "provisional" };
        } else receipt = await this.client.call(admitted.agent_id, row.path.split("/").at(-1), payload);
        if (!capture && receipt.protocol !== SOURCE_PROTOCOL) throw new MemoryRequestError("invalid_response");
        journal.accept(row.event_id, receipt);
      } catch (error) {
        if (this.closed) return;
        const terminal = error instanceof MemoryRequestError && ([400, 401, 403, 404, 409, 422].includes(error.status) || ["binding_changed", "capture_binding_mismatch", "authority_changed", "partition_mismatch"].includes(error.code));
        const deferred = error instanceof MemoryRequestError && ["unsupported_capability", "source_unavailable"].includes(error.code);
        journal.fail(row.event_id, safeError(error).split(" ")[0], { terminal, deferred });
        this.warn(error);
        // A lost acceptance ACK fences later unsent stages; never reorder a snapshot.
        break;
      }
    }
  }
  start() {
    if (this.closed || !this.config.enabled) return;
    this.journalForUse();
    this.timer ||= setInterval(() => { void this.drain().catch((error) => this.warn(error)); }, 1000);
    this.timer.unref();
    void this.drain().catch((error) => this.warn(error));
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
