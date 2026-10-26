import assert from "node:assert/strict";
import test from "node:test";
import { mkdtempSync, mkdirSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import plugin, { createMemoryService } from "../openclaw/plugin.mjs";
import { canonicalJson, digest, sourceSnapshot, TOOL_NAMES, uuid } from "../openclaw/contract.mjs";
import { DeliveryJournal } from "../openclaw/journal.mjs";
import { eligibleRows, renderContext } from "../openclaw/context.mjs";
import { auditLegacyPage } from "../openclaw/rollout.mjs";

const accessId = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa";
const binding = { access_id: accessId, authority_version: 1, partition: { memory_space_id: "bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb", scope: "host", namespace: "default" } };
const peer = { protocol: "memory_sources.v1", supported: true, ready: true, binding, binding_fingerprint: digest(binding), capture_binding: binding, capture_binding_fingerprint: digest(binding), capture_ready: true, contracts: ["memory_sources.v1", "openclaw_source.v1", "openclaw_capture.v1"], negotiated: ["memory_commands.v2", "memory_sources.v1", "openclaw_source.v1", "openclaw_capture.v1"] };
const currentRow = (content = "The project uses PostgreSQL.") => ({ id: "cccccccc-1111-4111-8111-cccccccccccc", kind: "memory", content, revision: 2, policy_version: "current_context.v1", lifecycle_state: "current", effective_support: true, trust: "candidate_inference", relevance_accepted: true, source_refs: [], independent_support: true, support_complete: true });

function setup(t, options = {}) {
  const root = mkdtempSync(join(tmpdir(), "backplane-openclaw-test-"));
  const workspace = join(root, "workspace"); mkdirSync(workspace);
  const requests = [], warnings = [], handlers = {}, registrations = {};
  const originalFetch = globalThis.fetch;
  const api = {
    pluginConfig: { native_sync: false, journal_path: join(root, "state", "delivery.sqlite"), bindings: [{ agent_id: "main", memory_access_id: accessId }], ...options },
    config: { plugins: { entries: { "backplane-memory": { hooks: { allowConversationAccess: true } } } } },
    logger: { warn: (warning) => warnings.push(warning) }, runtime: { state: { resolveStateDir: () => root } },
    on: (name, handler, opts) => { handlers[name] = handler; registrations[name] = opts; },
    registerTool: (factory, opts) => { registrations.tools = { factory, opts }; },
    registerMemoryCapability: (capability) => { registrations.capability = capability; }, registerService: (service) => { registrations.service = service; }, lifecycle: { onDispose: (dispose) => { registrations.dispose = dispose; } },
  };
  let responder;
  globalThis.fetch = async (url, init) => {
    const args = JSON.parse(init.body), path = new URL(url).pathname;
    requests.push({ path, args });
    if (responder) { const override = await responder(path, args); if (override) return override; }
    let result;
    if (path.endsWith("/source_capabilities")) result = peer;
    else if (path.endsWith("/recall")) result = { results: [currentRow()] };
    else if (path.endsWith("/get")) result = { record: currentRow() };
    else if (path.endsWith("/forget")) result = { forgotten: true };
    else if (path === "/capture/v1/status") result = { protocol: "openclaw_capture.v1", items: args.event_ids.map((event_id) => ({ event_id, status: "canonical_committed" })) };
    else if (path.startsWith("/capture/")) return { ok: true, status: 202, json: async () => ({ ok: true, status: "accepted", event_id: args.event_id }) };
    else if (/source_(mutate|reconcile|status)$/.test(path)) result = { protocol: "memory_sources.v1", event_id: args.event_id, status: "committed", ...(args.entry_id ? { canonical_id: currentRow().id } : {}) };
    else throw new Error("unexpected_test_path");
    return { ok: true, status: 200, json: async () => ({ ok: true, result }) };
  };
  const service = createMemoryService(api), active = { value: true };
  const assertActive = () => { if (!active.value) throw new Error("revoked"); };
  const ctx = { agentId: "main", sessionId: "session-one", sessionKey: "agent:main:main", runId: "run-one", workspaceDir: workspace, memoryAudience: { kind: "owner-private", agentId: "main" }, sandboxed: false, assertMemoryAudienceCurrent: assertActive, assertInvocationCurrent: assertActive, toolAuthority: { assertActive, allows: () => true }, hookInvocation: { assertActive } };
  t.after(async () => { await service.stop(); globalThis.fetch = originalFetch; rmSync(root, { recursive: true, force: true }); });
  return { api, service, ctx, root, workspace, requests, warnings, active, handlers, registrations, respond: (fn) => { responder = fn; } };
}

test("portable canonical hashing uses UTF8 key ordering and safe integers", () => {
  assert.equal(canonicalJson({ "𐀀": 1, "": 2 }), '{"":2,"𐀀":1}');
  assert.throws(() => canonicalJson(Number.MAX_SAFE_INTEGER + 1), /not_portable_json/);
  assert.throws(() => canonicalJson("\ud800"), /invalid_unicode/);
  const commands = sourceSnapshot({ integration: "openclaw" }, [{ entry_id: uuid(), content: "完整结论。", type: "semantic", provenance: {} }], 1);
  assert.deepEqual(commands.map((item) => item.phase), ["begin", "page", "commit"]);
  assert.equal(commands[0].snapshot_hash, commands[1].page_hash);
});

test("journal restart preserves envelopes and rolls back failed batch/cursor admission", (t) => {
  const root = mkdtempSync(join(tmpdir(), "openclaw-journal-")); t.after(() => rmSync(root, { recursive: true, force: true }));
  const path = join(root, "journal.sqlite"), eventId = uuid(), payload = { event_id: eventId, captured_at: "2026-10-26T00:00:00Z", source_sequence: 1 };
  let journal = new DeliveryJournal(path, { profile: "test" }, { maxEvents: 2 });
  journal.enqueue(eventId, "/capture", payload, binding); const saved = journal.row(eventId); journal.close();
  journal = new DeliveryJournal(path, { profile: "test" }, { maxEvents: 2 });
  assert.equal(journal.row(eventId).payload, saved.payload); assert.equal(journal.row(eventId).digest, saved.digest);
  assert.equal(journal.enqueue(eventId, "/capture", payload, binding), eventId);
  assert.throws(() => journal.enqueue(eventId, "/capture", { ...payload, source_sequence: 2 }, binding), /immutable_event_conflict/);
  assert.throws(() => journal.transaction(() => { journal.set("cursor", 7); journal.enqueue(uuid(), "/capture", {}, binding); journal.enqueue(uuid(), "/capture", {}, binding); }), /delivery_journal_full/);
  assert.equal(journal.get("cursor"), undefined); assert.equal(journal.due().length, 1); journal.close();
});

test("actual SQLite page exhaustion atomically rejects cursor and event, then retry survives reopen", (t) => {
  const root = mkdtempSync(join(tmpdir(), "openclaw-journal-full-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const path = join(root, "journal.sqlite"), admittedId = uuid(), pendingId = uuid();
  let journal = new DeliveryJournal(path, { profile: "disk-ceiling" });
  t.after(() => journal.close());
  journal.enqueue(admittedId, "/capture", { event_id: admittedId, content: "Already admitted." }, binding);
  const admitted = { ...journal.row(admittedId) };
  const ceiling = journal.db.prepare("PRAGMA max_page_count").get().max_page_count;
  const pages = journal.db.prepare("PRAGMA page_count").get().page_count;
  journal.db.exec(`PRAGMA max_page_count=${pages}`);
  const payload = { event_id: pendingId, content: "Bounded storage fixture. ".repeat(10000) };
  const admit = () => journal.transaction(() => {
    journal.set("disk_cursor", 2);
    journal.enqueue(pendingId, "/capture", payload, binding);
  });
  assert.throws(admit, (error) => error.errcode === 13 && /full/i.test(error.message));
  assert.equal(journal.get("disk_cursor"), undefined);
  assert.equal(journal.row(pendingId), undefined);
  assert.deepEqual({ ...journal.row(admittedId) }, admitted);
  journal.db.exec(`PRAGMA max_page_count=${ceiling}`);
  admit();
  const retried = { ...journal.row(pendingId) };
  assert.equal(journal.get("disk_cursor"), 2);
  journal.close();
  journal = new DeliveryJournal(path, { profile: "disk-ceiling" });
  assert.deepEqual({ ...journal.row(admittedId) }, admitted);
  assert.deepEqual({ ...journal.row(pendingId) }, retried);
  assert.equal(journal.get("disk_cursor"), 2);
});

test("separate profiles keep independent journals and source namespaces without implying access isolation", async (t) => {
  const { api, service, ctx, root, requests } = setup(t, { journal_path: undefined, profile_id: "primary" });
  const secondaryApi = { ...api, pluginConfig: { ...api.pluginConfig, profile_id: "secondary" } };
  const secondary = createMemoryService(secondaryApi);
  t.after(() => secondary.stop());
  await Promise.all([
    service.beforePrompt({ prompt: "Primary profile evidence.", messages: [] }, ctx),
    secondary.beforePrompt({ prompt: "Secondary profile evidence.", messages: [] }, ctx),
  ]);
  const primaryId = service.journal.installationId, secondaryId = secondary.journal.installationId;
  assert.notEqual(primaryId, secondaryId);
  assert.notEqual(service.namespace(ctx), secondary.namespace(ctx));
  assert.equal(service.config.bindings[0].memory_access_id, secondary.config.bindings[0].memory_access_id);
  const profileMessages = (journal) => journal.db.prepare("SELECT payload FROM delivery WHERE path LIKE '%/message'").all().map((row) => JSON.parse(row.payload));
  assert.deepEqual(profileMessages(service.journal).map((row) => row.content), ["Primary profile evidence."]);
  assert.deepEqual(profileMessages(secondary.journal).map((row) => row.content), ["Secondary profile evidence."]);
  assert.ok(requests.filter((row) => row.path.endsWith("/message")).every((row) => row.args.profile_id === (row.args.content.startsWith("Primary") ? service.namespace(ctx) : secondary.namespace(ctx))));
  await service.stop();
  const reopened = createMemoryService(api);
  t.after(() => reopened.stop());
  assert.equal(reopened.journalForUse().installationId, primaryId);
  assert.equal(secondary.journal.installationId, secondaryId);
  assert.deepEqual(profileMessages(reopened.journal).map((row) => row.content), ["Primary profile evidence."]);
  const conflicting = createMemoryService({ ...secondaryApi, pluginConfig: { ...secondaryApi.pluginConfig, journal_path: join(root, "plugins", "backplane-memory", "primary", "delivery.sqlite") } });
  t.after(() => conflicting.stop());
  assert.throws(() => conflicting.journalForUse(), /journal_identity_changed/);
  assert.equal(reopened.journal.installationId, primaryId);
});

test("registration declares precise executable tools and supported hooks", async (t) => {
  const { api, registrations, handlers } = setup(t); plugin.register(api);
  assert.equal(registrations.tools.factory.contextVersion, 2);
  assert.deepEqual(registrations.tools.opts.names.sort(), Object.values(TOOL_NAMES).sort());
  assert.deepEqual(Object.keys(handlers).sort(), ["agent_end", "before_prompt_build", "session_end"]);
  assert.equal(registrations.before_prompt_build.requiresToolAuthority, true);
  assert.equal(typeof registrations.capability.providerRuntime.open, "function"); await registrations.dispose();
});

test("missing conversation grant leaves tools independent and zero automatic hooks/egress", async (t) => {
  const { api, handlers, registrations, requests, warnings } = setup(t);
  api.config.plugins.entries["backplane-memory"].hooks.allowConversationAccess = false; plugin.register(api);
  assert.deepEqual(handlers, {}); assert.ok(registrations.tools); assert.equal(requests.length, 0);
  assert.match(warnings.at(-1), /conversation_access_required/); await registrations.dispose();
});

test("disabled provider advertises no active behavior", (t) => {
  const { api, registrations, handlers } = setup(t); api.pluginConfig.enabled = false; plugin.register(api);
  assert.deepEqual(registrations, {}); assert.deepEqual(handlers, {});
});

test("audience/sandbox/cross-agent/tool denial happens before I/O", async (t) => {
  const { service, ctx, requests, active } = setup(t);
  for (const patch of [{ memoryAudience: undefined }, { memoryAudience: { kind: "conversation", agentId: "main", sessionKey: ctx.sessionKey, sessionId: ctx.sessionId } }, { memoryAudience: { kind: "owner-private", agentId: "other" } }, { agentId: "other" }, { sandboxed: true }, { toolAuthority: { assertActive() {}, allows: () => false } }, { assertMemoryAudienceCurrent: undefined }]) await service.beforePrompt({ prompt: "secret", messages: [] }, { ...ctx, ...patch });
  active.value = false; await service.beforePrompt({ prompt: "secret", messages: [] }, ctx); assert.equal(requests.length, 0);
});

test("capture keeps original input and current suffix separate, including empty assistant and retries", async (t) => {
  const { service, ctx, requests } = setup(t);
  const history = [{ role: "user", content: "old question" }, { role: "assistant", content: "old answer" }], event = { prompt: "current question", messages: history };
  await service.beforePrompt(event, ctx); await service.beforePrompt(event, ctx);
  const end = { success: true, messages: [...history, { role: "user", content: "MODEL ONLY RECALL\ncurrent question" }, { role: "assistant", content: "new answer" }] };
  await service.agentEnd(end, ctx); await service.agentEnd(end, ctx);
  const first = requests.filter((row) => row.path.endsWith("/message"));
  assert.deepEqual(first.map((row) => row.args.content), ["current question", "new answer"]);
  assert.ok(first.every((row) => row.args.session_id === ctx.sessionId && row.args.run_id === ctx.runId && row.args.agent_id === ctx.agentId));
  const nextCtx = { ...ctx, runId: "run-two" }, nextHistory = [...history, { role: "user", content: "current question" }, { role: "assistant", content: "new answer" }];
  await service.beforePrompt({ prompt: "next question", messages: nextHistory }, nextCtx);
  await service.agentEnd({ messages: [...nextHistory, { role: "user", content: "next question" }] }, nextCtx);
  const last = requests.filter((row) => row.path.endsWith("/message")).at(-1);
  assert.equal(last.args.content, "next question"); assert.equal(last.args.session_id, ctx.sessionId); assert.equal(last.args.run_id, "run-two"); assert.notEqual(first[0].args.occurrence_id, last.args.occurrence_id);
});

test("missing/changed boundary and mutated immutable input cannot capture borrowed history", async (t) => {
  const { service, ctx, requests, warnings } = setup(t);
  await service.agentEnd({ messages: [{ role: "assistant", content: "old" }] }, ctx);
  await service.beforePrompt({ prompt: "one", messages: [{ role: "user", content: "history" }] }, ctx);
  const count = requests.filter((row) => row.path.endsWith("/message")).length;
  await service.beforePrompt({ prompt: "changed", messages: [{ role: "user", content: "history" }] }, ctx);
  await service.agentEnd({ messages: [{ role: "user", content: "compacted" }, { role: "assistant", content: "not attributable" }] }, ctx);
  assert.equal(requests.filter((row) => row.path.endsWith("/message")).length, count);
  assert.ok(warnings.some((warning) => warning.includes("immutable_turn_conflict"))); assert.ok(warnings.some((warning) => warning.includes("capture_boundary_unavailable")));
});

test("trusted memory maintenance skips automatic conversation hooks but retains provider persistence", async (t) => {
  const { service, ctx, requests } = setup(t);
  const maintenance = { ...ctx, trigger: "memory", memoryFlush: { flushId: "host-flush-one" } };
  await service.beforePrompt({ prompt: "A synthetic maintenance instruction.", messages: [] }, maintenance);
  await service.agentEnd({ success: true, messages: [{ role: "user", content: "A synthetic maintenance instruction." }, { role: "assistant", content: "NO_REPLY" }] }, maintenance);
  assert.equal(requests.length, 0);
  const receipt = await service.mutate(maintenance, "save", { fact_key: "maintenance-fixture", content: "A supported provider candidate." }, "flush-save-one");
  assert.ok(receipt.event_id);
  assert.equal(requests.some((row) => row.path.startsWith("/capture/")), false);
  assert.ok(requests.some((row) => row.path.endsWith("/source_mutate") && row.args.provenance.role === "assistant"));
});

test("synthetic origin and privacy survive without inventing human confirmation", async (t) => {
  const { service, ctx, requests } = setup(t);
  await service.beforePrompt({ prompt: "remember <private>secret</private> public", messages: [] }, { ...ctx, inputProvenance: { kind: "internal_system", sourceTool: "maintenance" } });
  const row = requests.find((request) => request.path.endsWith("/message"));
  assert.equal(row.args.role, "user"); assert.equal(row.args.input_provenance.kind, "internal_system"); assert.doesNotMatch(row.args.content, /secret/);
  assert.equal(row.args.completeness.original_length, [...row.args.content].length); assert.equal(JSON.stringify(requests).includes("<private>"), false);
});

test("native edit preserves identity and failed inventory cannot mass-withdraw", async (t) => {
  const { service, ctx, workspace, requests } = setup(t, { native_sync: true });
  writeFileSync(join(workspace, "USER.md"), "User prefers concise explanations."); writeFileSync(join(workspace, "MEMORY.md"), "Project uses PostgreSQL.");
  await service.beforePrompt({ prompt: "database", messages: [] }, ctx);
  const native = requests.filter((row) => row.path.endsWith("/source_mutate")); assert.equal(native.length, 2); assert.ok(native.every((row) => row.args.provenance.document_complete === true));
  const first = native.find((row) => row.args.source.target === "memory");
  writeFileSync(join(workspace, "MEMORY.md"), "Project uses PostgreSQL 17."); await service.beforePrompt({ prompt: "database", messages: [] }, { ...ctx, runId: "run-two" });
  const edited = requests.filter((row) => row.path.endsWith("/source_mutate") && row.args.source.target === "memory").at(-1);
  assert.equal(edited.args.entry_id, first.args.entry_id); assert.ok(edited.args.revision > first.args.revision); assert.notEqual(edited.args.provenance.document_revision, first.args.provenance.document_revision);
  const before = requests.filter((row) => row.path.endsWith("/source_mutate")).length;
  unlinkSync(join(workspace, "USER.md")); symlinkSync("/unreadable", join(workspace, "USER.md")); writeFileSync(join(workspace, "MEMORY.md"), "");
  await service.beforePrompt({ prompt: "database", messages: [] }, { ...ctx, runId: "run-three" });
  assert.equal(requests.filter((row) => row.path.endsWith("/source_mutate")).length, before);
  unlinkSync(join(workspace, "USER.md")); await service.beforePrompt({ prompt: "database", messages: [] }, { ...ctx, runId: "run-four" });
  assert.equal(requests.filter((row) => row.path.endsWith("/source_mutate") && row.args.operation === "withdraw").length, 2);
});

test("provider save/correct/withdraw use exact IDs and stable host flush identity", async (t) => {
  const { service, ctx, requests } = setup(t), flushCtx = { ...ctx, memoryFlush: { flushId: "actual-flush-one" } };
  const tools = Object.fromEntries(service.tools(flushCtx).map((tool) => [tool.name, tool]));
  const saved = (await tools[TOOL_NAMES.save].execute("call-one", { content: "Candidate conclusion.", fact_key: "fact-one" })).details;
  const again = (await tools[TOOL_NAMES.save].execute("call-two", { content: "Candidate conclusion.", fact_key: "fact-one" })).details;
  assert.equal(saved.event_id, again.event_id); assert.equal(saved.entry_id, again.entry_id);
  await assert.rejects(tools[TOOL_NAMES.save].execute("call-three", { content: "Changed conclusion.", fact_key: "fact-one" }), /immutable_event_conflict/);
  const corrected = (await tools[TOOL_NAMES.correct].execute("correct-one", { entry_id: saved.entry_id, content: "Corrected candidate." })).details; assert.equal(corrected.entry_id, saved.entry_id);
  await tools[TOOL_NAMES.withdraw].execute("withdraw-one", { entry_id: saved.entry_id });
  await assert.rejects(tools[TOOL_NAMES.forget].execute("forget-one", { id: currentRow().id }), /explicit_global_forget_required/);
  await tools[TOOL_NAMES.forget].execute("forget-two", { id: currentRow().id, confirm_global: true }); assert.equal(requests.filter((row) => row.path.endsWith("/forget")).length, 1);
  const plan = service.flushPlan(); assert.deepEqual(plan.persistenceToolNames, [TOOL_NAMES.save, TOOL_NAMES.correct]); assert.match(plan.prompt, /NO_REPLY/); assert.match(plan.prompt, /not persistence/);
});

test("lost ACK replays an identical immutable delivery", async (t) => {
  const { service, ctx, respond, requests } = setup(t); let fail = true;
  respond((path) => { if (path.endsWith("/source_mutate") && fail) { fail = false; throw new TypeError("simulated lost ACK"); } });
  const saved = await service.mutate(ctx, "save", { content: "Durable candidate." }, "actual-call"); assert.equal(saved.status, "local_pending");
  service.journal.db.prepare("UPDATE delivery SET next_at=0").run(); await service.drain(); assert.equal(service.journal.row(saved.event_id).state, "canonical_committed");
  const calls = requests.filter((request) => request.path.endsWith("/source_mutate")); assert.equal(calls.length, 2); assert.equal(canonicalJson(calls[0].args), canonicalJson(calls[1].args));
});

test("old hosts refuse without append-only fallback and late revocation cannot release data", async (t) => {
  const { service, ctx, respond, requests, active } = setup(t); await service.peer(service.authorize(ctx));
  respond((path) => path.endsWith("/source_capabilities") ? { ok: true, status: 200, json: async () => ({ ok: true, result: { ...peer, contracts: ["memory_sources.v1", "hermes_capture.v1"] } }) } : null);
  await assert.rejects(service.mutate(ctx, "save", { content: "No fallback." }, "call"), /unsupported_capability/); assert.equal(requests.some((row) => row.path.endsWith("/remember")), false); assert.equal(service.journal.status().local_pending, 0);
  respond((path) => { if (path.endsWith("/recall")) active.value = false; }); await assert.rejects(service.read(ctx, "recall", { query: "project" }), /revoked/);
});

test("final budget counts full entries, labels and references; irrelevant and stale return zero", () => {
  const rows = [currentRow("A full conclusion with its qualifications."), { ...currentRow("第二条完整结论。"), id: uuid() }];
  assert.equal(renderContext(rows, 128), ""); const large = renderContext(rows, 2000); assert.match(large, /A full conclusion with its qualifications\./); assert.ok(Buffer.byteLength(large) <= 2000);
  assert.deepEqual(eligibleRows({ results: [{ ...rows[0], relevance_accepted: false }] }), []); assert.equal(renderContext([], 2000), ""); assert.deepEqual(eligibleRows({ stale: true, results: rows }), []);
});

test("provider runtime is caller-bound, offers safe host health and closes only its lease", async (t) => {
  const { service, ctx } = setup(t), context = { authority: { kind: "session", sessionId: ctx.sessionId, sessionKey: ctx.sessionKey, sandboxed: false, audience: ctx.memoryAudience }, assertCurrent: ctx.assertInvocationCurrent };
  const { provider } = await service.open({ agentId: "main", context }); const search = await provider.search({ query: "database" }); assert.equal(search.hits[0].reference.providerId, "backplane-memory");
  const record = await provider.get({ reference: { providerId: "backplane-memory", id: currentRow().id } }); assert.equal(record.status, "ok");
  await assert.rejects(provider.search({ query: "database", minScore: 0.5 }), /unsupported_search_filter/); await provider.close(); await assert.rejects(provider.search({ query: "database" }), /provider_lease_closed/);
  const host = await service.open({ agentId: "main", context: { authority: { kind: "host", operation: "status" }, assertCurrent() {} }, purpose: "status" }); assert.equal((await host.provider.health()).status, "degraded"); await assert.rejects(host.provider.search({ query: "database" }), /audience_binding_unavailable/);
});

test("session closure only closes an admitted exact session without reading transcript", async (t) => {
  const { service, ctx, requests } = setup(t); await service.beforePrompt({ prompt: "hello", messages: [] }, ctx); let read = false;
  const endCtx = { agentId: ctx.agentId, sessionId: ctx.sessionId, sessionKey: ctx.sessionKey, endedTranscript: { available: true, readTail: () => { read = true; throw new Error("forbidden"); } } };
  await service.sessionEnd({ sessionId: ctx.sessionId, reason: "reset" }, endCtx); await service.sessionEnd({ sessionId: ctx.sessionId, reason: "reset" }, endCtx); await service.sessionEnd({ sessionId: "unadmitted" }, { ...endCtx, sessionId: "unadmitted" });
  assert.equal(requests.filter((request) => request.path.endsWith("/session-end")).length, 1); assert.equal(read, false);
});

test("malformed privacy blocks fail closed with zero conversation body egress", async (t) => {
  const { service, ctx, requests } = setup(t);
  for (const [index, prompt] of ["</private>secret<private>", "<private><private>secret</private></private>", "<private secret"].entries()) {
    await service.beforePrompt({ prompt, messages: [] }, { ...ctx, runId: `malformed-${index}` });
  }
  assert.equal(requests.some((request) => request.path.endsWith("/message") || request.path.endsWith("/recall")), false);
});

test("read-only Backplane access can recall without source write readiness", async (t) => {
  const { service, ctx, respond, requests } = setup(t);
  respond((path) => path.endsWith("/source_capabilities") ? { ok: true, status: 200, json: async () => ({ ok: true, result: { ...peer, ready: false, capture_ready: false } }) } : null);
  const result = await service.read(ctx, "recall", { query: "database" });
  assert.equal(result.results[0].id, currentRow().id);
  await assert.rejects(service.mutate(ctx, "save", { content: "not granted" }, "write"), /source_unavailable/);
  assert.equal(requests.some((request) => request.path.endsWith("/source_mutate")), false);
});

test("hook recall and capture honor independent finalized tool permissions", async (t) => {
  const { service, ctx, requests } = setup(t);
  const readOnly = { ...ctx, toolAuthority: { assertActive() {}, allows: (name) => name === TOOL_NAMES.search } };
  const block = await service.beforePrompt({ prompt: "database", messages: [] }, readOnly);
  assert.match(block.prependContext, /PostgreSQL/);
  assert.equal(requests.some((request) => request.path.startsWith("/capture/")), false);
  requests.length = 0;
  const writeOnly = { ...ctx, runId: "write-run", toolAuthority: { assertActive() {}, allows: (name) => name === TOOL_NAMES.save } };
  assert.equal(await service.beforePrompt({ prompt: "database", messages: [] }, writeOnly), undefined);
  assert.ok(requests.some((request) => request.path.endsWith("/message")));
  assert.equal(requests.some((request) => request.path.endsWith("/recall")), false);
});

test("provider provisional references never masquerade as readable canonical UUIDs", async (t) => {
  const { service, ctx, respond, requests } = setup(t);
  respond((path) => path.endsWith("/recall") ? { ok: true, status: 200, json: async () => ({ ok: true, result: { results: [], provisional_results: [{ ...currentRow(), provisional: true, authority: "provisional" }] } }) } : null);
  const { provider } = await service.open({ agentId: "main", context: { authority: { kind: "session", sessionId: ctx.sessionId, sessionKey: ctx.sessionKey, sandboxed: false, audience: ctx.memoryAudience }, assertCurrent: ctx.assertInvocationCurrent } });
  const search = await provider.search({ query: "database" });
  assert.match(search.hits[0].reference.id, /^pending:/);
  const before = requests.length;
  await assert.rejects(provider.get({ reference: search.hits[0].reference }), /invalid_reference/);
  assert.equal(requests.length, before);
});

test("manager cleanup revokes old leases while new recall, hooks and admitted delivery survive", async (t) => {
  const { service, ctx, requests } = setup(t);
  const context = { authority: { kind: "session", sessionId: ctx.sessionId, sessionKey: ctx.sessionKey, sandboxed: false, audience: ctx.memoryAudience }, assertCurrent: ctx.assertInvocationCurrent };
  const first = (await service.open({ agentId: "main", context })).provider;
  await service.beforePrompt({ prompt: "database", messages: [] }, ctx);
  const rows = service.journal.db.prepare("SELECT event_id,payload,state FROM delivery ORDER BY sequence").all();
  assert.ok(rows.length > 0);
  assert.ok(rows.some((row) => row.state === "host_accepted"));
  await service.closeSearchLeases();
  await assert.rejects(first.search({ query: "database" }), /provider_lease_closed/);
  assert.equal(service.closed, false);
  assert.deepEqual(service.journal.db.prepare("SELECT event_id,payload,state FROM delivery ORDER BY sequence").all(), rows);
  const second = (await service.open({ agentId: "main", context })).provider;
  assert.equal((await second.search({ query: "database" })).hits[0].reference.id, currentRow().id);
  const next = { ...ctx, runId: "after-manager-cleanup" };
  assert.match((await service.beforePrompt({ prompt: "database", messages: [] }, next)).prependContext, /PostgreSQL/);
  assert.ok(requests.some((row) => row.args.run_id === next.runId && row.path.endsWith("/message")));
});

test("legacy audit is bounded, resumable and cannot guess an import identity", async () => {
  const calls = [], id = currentRow().id;
  const client = { capabilities: async () => peer, call: async (_agent, method, args) => {
    calls.push({ method, args });
    return method === "list" ? { authority: "canonical", results: [{ id }] } : { authority: "canonical", record: { id, provenance: { agent_id: "openclaw", session_id: "old-run-id" } } };
  } };
  const page = await auditLegacyPage(client, { agentId: "main", accessId, limit: 1 });
  assert.equal(page.records[0].id, id); assert.equal(page.records[0].stored_session_id, "old-run-id"); assert.equal(page.records[0].session_attribution, "not_reconstructed");
  assert.deepEqual(page.automatic_import_candidates, []); assert.equal(page.next_cursor.offset, 1);
  await auditLegacyPage(client, { agentId: "main", accessId, limit: 1, cursor: page.next_cursor });
  assert.equal(calls[2].args.offset, 1);
  await assert.rejects(auditLegacyPage(client, { agentId: "main", accessId, cursor: { offset: 1, binding_fingerprint: "changed" } }), /audit_binding_changed/);
  assert.ok(calls.every((call) => ["list", "get"].includes(call.method)));
});
