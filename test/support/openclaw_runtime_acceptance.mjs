/** JSON-lines driver for the pinned, real OpenClaw gateway. Fixture data only. */
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdir, readFile, writeFile, cp, rm } from 'node:fs/promises';
import { appendFileSync, existsSync, readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import { dirname, resolve, join } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const SESSION_READ_CHANGED = 'SessionEntryChangedDuringReadError: Session entry changed during read';
async function sendChatWithRecovery(dispatch, args, { maxAttempts = 6, deadlineMs = 5000, backoffMs = 250 } = {}) {
  const immutable = Object.freeze(structuredClone(args));
  const deadline = Date.now() + deadlineMs, rejections = [];
  for (let attempt = 1; ; attempt++) {
    try {
      const sent = await dispatch.request('chat.send', immutable);
      return { sent, admission: { attempts: attempt, rejections } };
    } catch (error) {
      // Pinned host session reads can be invalidated by post-ready recovery,
      // before chat admission. Public chat.send dedupes this immutable key/input.
      // This exact error has no retryable metadata; no other rejection is retried.
      if (error?.gatewayCode !== 'UNAVAILABLE' || error?.message !== SESSION_READ_CHANGED) throw error;
      rejections.push({ reason: 'session_entry_changed_during_read', gateway_code: 'UNAVAILABLE', retryable_metadata: error.retryable === true });
      const pause = Math.min(backoffMs * 2 ** (attempt - 1), 1000);
      if (attempt >= maxAttempts || Date.now() + pause > deadline) {
        const exhausted = Object.assign(new Error(SESSION_READ_CHANGED), { gatewayCode: 'UNAVAILABLE', qualificationAdmission: { attempts: attempt, rejections } });
        if (typeof error.retryable === 'boolean') exhausted.retryable = error.retryable;
        throw exhausted;
      }
      await new Promise((r) => setTimeout(r, pause));
    }
  }
}
if (process.argv.includes('--chat-admission-self-test')) {
  const args = { sessionKey: 'agent:main:fixture', message: 'Immutable fixture.', idempotencyKey: 'fixture-run' };
  const raced = () => Object.assign(new Error(SESSION_READ_CHANGED), { gatewayCode: 'UNAVAILABLE' });
  const seen = [];
  const retry = await sendChatWithRecovery({ request: async (method, input) => { seen.push({ method, input }); if (seen.length === 1) throw raced(); return { runId: input.idempotencyKey }; } }, args, { backoffMs: 0 });
  assert.equal(retry.admission.attempts, 2); assert.equal(retry.admission.rejections.length, 1);
  assert.equal(seen[0].input, seen[1].input); assert.deepEqual(seen[0].input, args); assert.ok(Object.isFrozen(seen[0].input));
  for (const error of [Object.assign(new Error('Other unavailable'), { gatewayCode: 'UNAVAILABLE', retryable: true }), Object.assign(new Error(SESSION_READ_CHANGED), { gatewayCode: 'INVALID_REQUEST' }), new Error(SESSION_READ_CHANGED)]) {
    let attempts = 0;
    await assert.rejects(sendChatWithRecovery({ request: async () => { attempts++; throw error; } }, args, { backoffMs: 0 }), (actual) => actual === error);
    assert.equal(attempts, 1);
  }
  let attempts = 0;
  await assert.rejects(sendChatWithRecovery({ request: async () => { attempts++; throw raced(); } }, args, { maxAttempts: 3, backoffMs: 0 }), (error) => error.message === SESSION_READ_CHANGED && error.qualificationAdmission.attempts === 3);
  assert.equal(attempts, 3);
  attempts = 0;
  await assert.rejects(sendChatWithRecovery({ request: async () => { attempts++; throw raced(); } }, args, { deadlineMs: 0, backoffMs: 1 }), (error) => error.qualificationAdmission.attempts === 1);
  assert.equal(attempts, 1);
  attempts = 0;
  const accepted = await sendChatWithRecovery({ request: async () => { attempts++; return { runId: 'accepted', status: 'in_flight' }; } }, args);
  assert.equal(attempts, 1); assert.equal(accepted.admission.attempts, 1); assert.deepEqual(accepted.admission.rejections, []);
  process.stdout.write(JSON.stringify({ ok: true, admission_cases: 7, immutable_same_key: true, unrelated_errors_retried: false, accepted_responses_retried: false }) + '\n');
  process.exit(0);
}

/** Emit only fixed classifications, never an SDK error's text, details, stack or payload. */
function safeFailure(error, stage, operation) {
  const internal = new Set(['unsupported_openclaw_version', 'runtime_timeout', 'gateway_exited', 'gateway_connect_failed', 'gateway_connect_timeout', 'gateway_startup_probe_invalid', 'gateway_agent_admission_refused', 'gateway_agent_roster_invalid', 'conversation_connect_failed', 'conversation_connect_timeout', 'invalid_native_path', 'invalid_native_content', 'invalid_flush_mode', 'invalid_concurrent_turns', 'concurrent_model_overlap_timeout', 'concurrent_model_request_invalid', 'unknown_operation']);
  const gatewayCodes = new Set(['INVALID_REQUEST', 'UNAVAILABLE', 'UNAUTHORIZED', 'FORBIDDEN', 'NOT_LINKED', 'NOT_PAIRED', 'CLIENT_TIMEOUT']);
  const systemCodes = new Set(['ERR_SQLITE_ERROR', 'ERR_SQLITE_BUSY', 'ENOENT', 'EACCES', 'ENOSPC', 'ECONNREFUSED', 'ECONNRESET', 'EPIPE']);
  const text = typeof error?.message === 'string' ? error.message : '';
  const gatewayCode = gatewayCodes.has(error?.gatewayCode) ? error.gatewayCode : gatewayCodes.has(error?.code) ? error.code : undefined;
  const knownMessages = new Map([
    [SESSION_READ_CHANGED, ['session_entry_changed_during_read', SESSION_READ_CHANGED]],
    ['session changed before chat.send; retry the request', ['session_mutation_authorization_changed', 'session changed before chat.send; retry the request']],
    ['Session settings changed before send. Retry.', ['session_settings_changed', 'Session settings changed before send. Retry.']],
    ['active branch changed; review and retry', ['active_leaf_changed', 'active branch changed; review and retry']],
    ['session routing changed; review and retry', ['session_routing_changed', 'session routing changed; review and retry']],
    ['Session changed before native confirmation. Retry.', ['session_changed_before_native_confirmation', 'Session changed before native confirmation. Retry.']],
    ['Session storage changed while starting work. Retry.', ['session_storage_changed', 'Session storage changed while starting work. Retry.']],
    ['Session preparation changed; retry.', ['session_preparation_changed', 'Session preparation changed; retry.']],
  ]);
  const known = knownMessages.get(text) || (/^Session "[^"\r\n]{1,512}" changed while starting work\. Retry\.$/.test(text) ? ['session_incarnation_changed', 'Session "<redacted>" changed while starting work. Retry.'] : undefined);
  const details = error?.details && typeof error.details === 'object' && !Array.isArray(error.details) ? error.details : undefined;
  const detailValues = {
    code: new Set(['SESSION_MUTATION_AUTHORIZATION_CHANGED']),
    reason: new Set(['session-settings-changed', 'active-leaf-changed', 'session-routing-changed']),
    method: new Set(['chat.send']),
  };
  const safeDetails = details ? Object.fromEntries(Object.entries(detailValues).filter(([key]) => Object.hasOwn(details, key)).map(([key, values]) => [key, values.has(details[key]) ? details[key] : '<unrecognized>'])) : undefined;
  const detailClass = { 'SESSION_MUTATION_AUTHORIZATION_CHANGED': 'session_mutation_authorization_changed', 'session-settings-changed': 'session_settings_changed', 'active-leaf-changed': 'active_leaf_changed', 'session-routing-changed': 'session_routing_changed' };
  const failureClass = known?.[0] || detailClass[safeDetails?.code] || detailClass[safeDetails?.reason] || 'unclassified';
  const operations = new Set(['boot', 'turn', 'snapshot', 'status', 'native', 'reset', 'restart', 'reload', 'flush', 'stop', 'concurrent_turns']);
  let code = internal.has(text) ? text : gatewayCode ? `gateway_${gatewayCode.toLowerCase()}` : systemCodes.has(error?.code) ? error.code.toLowerCase() : error?.name === 'SyntaxError' ? 'runtime_invalid_json' : error?.name === 'TypeError' ? 'runtime_type_error' : 'runtime_operation_failed';
  const reasons = [
    ['pending_final_delivery', /pending.{0,40}final|final.{0,40}pending/i],
    ['session_lifecycle_changed', /session.{0,50}(?:changed|reset|replaced)|lifecycle.{0,30}changed/i],
    ['gateway_draining', /draining|shutting down|restart fence/i],
    ['request_timeout', /timed?\s*out|timeout/i],
    ['transport_closed', /websocket|not connected|disconnected|connection.{0,20}closed/i],
    ['session_busy', /busy|already.{0,20}(?:active|running)|in.?flight/i],
    ['payload_limit', /too large|maximum.{0,20}(?:size|length)|payload.{0,20}limit/i],
    ['authorization_denied', /unauthorized|forbidden|denied|missing.{0,20}scope/i],
    ['sqlite_schema_missing', /no such table/i],
    ['sqlite_locked', /database is locked|SQLITE_BUSY/i],
  ];
  const reason = reasons.find(([, pattern]) => pattern.test(text))?.[0] || 'unclassified';
  const safeStage = /^[a-z_.]+$/.test(stage) ? stage : 'operation';
  return { code, message: `${code}:${safeStage}:${reason}`, stage: safeStage, reason, failure_class: failureClass,
    ...(operations.has(operation) ? { operation } : {}),
    ...(gatewayCode ? { gateway_message: known?.[1] || '<unrecognized>' } : {}),
    ...(gatewayCode && safeDetails && Object.keys(safeDetails).length ? { gateway_details: safeDetails } : {}),
    ...(gatewayCode ? { gateway_code: gatewayCode } : {}),
    ...(typeof error?.requestSent === 'boolean' ? { request_sent: error.requestSent } : {}),
    ...(typeof error?.retryable === 'boolean' ? { retryable: error.retryable } : {}),
    ...(Number.isInteger(error?.qualificationAdmission?.attempts) && error.qualificationAdmission.attempts >= 1 && error.qualificationAdmission.attempts <= 6 ? { admission_attempts: error.qualificationAdmission.attempts, pre_admission_rejections: error.qualificationAdmission.rejections.length } : {}) };
}
if (process.argv.includes('--diagnostics-self-test')) {
  const secret = 'fixture-secret-do-not-emit';
  const cases = [
    [Object.assign(new Error(`INVALID_REQUEST ${secret}`), { gatewayCode: 'INVALID_REQUEST' }), 'gateway_invalid_request'],
    [Object.assign(new Error(`gateway request timed out ${secret}`), { code: 'CLIENT_TIMEOUT', requestSent: true }), 'gateway_client_timeout'],
    [new TypeError(secret), 'runtime_type_error'],
    [Object.assign(new Error(`no such table: ${secret}`), { code: 'ERR_SQLITE_ERROR' }), 'err_sqlite_error'],
    [new Error(secret), 'runtime_operation_failed'],
  ];
  for (const [error, expected] of cases) {
    const result = safeFailure(error, 'turn.chat_send', 'turn');
    if (result.code !== expected || JSON.stringify(result).includes(secret)) throw new Error('diagnostics_self_test_failed');
    assert.equal(result.operation, 'turn');
  }
  const lifecycle = [
    [SESSION_READ_CHANGED, {}, 'session_entry_changed_during_read'],
    ['session changed before chat.send; retry the request', { code: 'SESSION_MUTATION_AUTHORIZATION_CHANGED', method: 'chat.send' }, 'session_mutation_authorization_changed'],
    ['Session settings changed before send. Retry.', { reason: 'session-settings-changed' }, 'session_settings_changed'],
    ['active branch changed; review and retry', { reason: 'active-leaf-changed' }, 'active_leaf_changed'],
    ['session routing changed; review and retry', { reason: 'session-routing-changed' }, 'session_routing_changed'],
    ['Session changed before native confirmation. Retry.', {}, 'session_changed_before_native_confirmation'],
    ['Session storage changed while starting work. Retry.', {}, 'session_storage_changed'],
    ['Session preparation changed; retry.', {}, 'session_preparation_changed'],
    [`Session "${secret}" changed while starting work. Retry.`, {}, 'session_incarnation_changed'],
  ];
  for (const [message, details, expected] of lifecycle) {
    const error = Object.assign(new Error(message), { gatewayCode: 'INVALID_REQUEST', details: { ...details, sessionKey: secret, prompt: secret, token: secret }, stack: secret });
    const result = safeFailure(error, 'rpc.chat_send', 'turn');
    assert.equal(result.failure_class, expected); assert.equal(result.gateway_code, 'INVALID_REQUEST');
    assert.ok(!JSON.stringify(result).includes(secret));
    assert.deepEqual(result.gateway_details || {}, details);
    if (expected === 'session_incarnation_changed') assert.equal(result.gateway_message, 'Session "<redacted>" changed while starting work. Retry.');
  }
  const unknown = safeFailure(Object.assign(new Error(`Session settings changed before send. Retry. ${secret}`), { gatewayCode: 'INVALID_REQUEST', details: { code: secret, reason: secret, method: secret, sessionKey: secret } }), secret, secret);
  assert.equal(unknown.gateway_message, '<unrecognized>'); assert.equal(unknown.failure_class, 'unclassified');
  assert.equal(unknown.stage, 'operation'); assert.equal(unknown.operation, undefined);
  assert.deepEqual(unknown.gateway_details, { code: '<unrecognized>', reason: '<unrecognized>', method: '<unrecognized>' });
  assert.ok(!JSON.stringify(unknown).includes(secret));
  const typed = safeFailure(Object.assign(new Error(secret), { gatewayCode: 'INVALID_REQUEST', details: { code: 'SESSION_MUTATION_AUTHORIZATION_CHANGED', method: 'chat.send', sessionKey: secret } }), 'rpc.chat_send', 'turn');
  assert.equal(typed.failure_class, 'session_mutation_authorization_changed'); assert.equal(typed.gateway_message, '<unrecognized>');
  assert.ok(!JSON.stringify(typed).includes(secret));
  process.stdout.write(JSON.stringify({ ok: true, diagnostic_cases: cases.length + lifecycle.length + 2, raw_errors_emitted: false, dynamic_identities_redacted: true, typed_refusals_distinguished: true }) + '\n');
  process.exit(0);
}

const fixture = JSON.parse(await readFile(process.env.OPENCLAW_LIVE_FIXTURE, 'utf8'));
const root = resolve(fixture.root);
const runtime = resolve(process.env.OPENCLAW_RUNTIME);
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const version = JSON.parse(await readFile(join(runtime, 'package.json'), 'utf8')).version;
if (version !== '2026.10.7') throw new Error('unsupported_openclaw_version');
const { GatewayClient } = await import(pathToFileURL(join(runtime, 'dist/plugin-sdk/gateway-runtime.js')));
const token = 'isolated-fixture-token-not-a-user-credential';
const requests = [], events = [];
let server, gateway, client, conversationClient, cfg, env, script = {}, last = {}, logs = '', stopped = false, modelBarrier;
let stage = 'operation';
async function rpc(dispatch, method, params) {
  stage = `rpc.${method.replaceAll('.', '_')}`;
  return dispatch.request(method, params);
}
const delay = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitFor(check, timeout = 45000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { const result = await check(); if (result) return result; await delay(50); }
  throw new Error('runtime_timeout');
}
async function waitForAgentAdmission() {
  let probes = 0;
  // /readyz and the listener can be healthy while agent database inspection is pending.
  // The public startup probe settles that inspection; agents.list distinguishes a
  // successful writable admission from a terminal inspection/ownership refusal.
  return waitFor(async () => {
    stage = 'startup.probe';
    if (gateway.exitCode !== null || gateway.signalCode !== null) throw new Error('gateway_exited');
    const response = await fetch(`http://127.0.0.1:${cfg.gateway.port}/startupz`, { signal: AbortSignal.timeout(5000) });
    const startup = await response.json(); probes++;
    if (response.status === 503 && startup.ok === false && startup.status === 'starting') return false;
    if (response.status !== 200 || startup.ok !== true || startup.status !== 'started') throw new Error('gateway_startup_probe_invalid');
    const roster = await rpc(client, 'agents.list', {});
    const agentIds = [fixture.agent_id, 'other', 'shared'];
    const agents = agentIds.map((id) => roster.agents?.find((agent) => agent.id === id));
    if (agents.some((agent) => !agent)) throw new Error('gateway_agent_roster_invalid');
    if (agents.some((agent) => agent.admissionRefusal && agent.admissionRefusal.code !== 'agent-database-inspection-pending')) throw new Error('gateway_agent_admission_refused');
    if (agents.some((agent) => agent.admissionRefusal)) return false;
    return { startupProbe: '/startupz', admissionMethod: 'agents.list', agentIds, writable: true, probes };
  });
}
async function freePort() {
  const s = createServer(); await new Promise((r) => s.listen(0, '127.0.0.1', r));
  const port = s.address().port; await new Promise((r) => s.close(r)); return port;
}
function modelReply(body) {
  const isFlush = body.messages?.some((m) => JSON.stringify(m.content).includes('This is the Backplane provider-owned memory flush'));
  const plan = isFlush ? script.flush : script;
  const seen = body.messages?.filter((m) => m.role === 'tool').length || 0;
  // Each request consumes one ordered fixture tool. Tool authority is still enforced by the real host.
  if (plan?.tools?.length) {
    const tool = plan.tools.shift();
    const visible = body.tools?.map((t) => t.function?.name) || [];
    const name = visible.includes(tool.name) ? tool.name : visible.includes('tool_call') ? 'tool_call' : tool.name;
    const args = name === 'tool_call' ? { id: tool.name, args: tool.args || {} } : tool.args || {};
    return { delta: { tool_calls: [{ index: 0, id: 'fixture_' + randomUUID(), type: 'function', function: { name, arguments: JSON.stringify(args) } }] }, finish: 'tool_calls', isFlush, seen, requestedTool: tool.name };
  }
  return { delta: { content: plan?.responseText ?? (isFlush ? 'NO_REPLY' : 'Fixture acknowledgement.') }, finish: 'stop', isFlush, seen };
}
async function startModel() {
  server = createServer(async (req, res) => {
    try {
      let raw = ''; for await (const chunk of req) raw += chunk;
      const body = raw ? JSON.parse(raw) : {};
      if (req.url?.endsWith('/models')) { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ data: [{ id: 'fixture' }] })); return; }
      const response = modelReply(body);
      const request = { url: req.url, body, response, receivedAt: new Date().toISOString() };
      requests.push(request);
      if (modelBarrier) await modelBarrier.arrive(body, request, requests.length - 1);
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
      const id = 'fixture-' + randomUUID();
      for (const [delta, finish] of [[{ role: 'assistant', content: '' }, null], [response.delta, null], [{}, response.finish]]) {
        const promptTokens = script.usageTokens ?? 100;
        res.write('data: ' + JSON.stringify({ id, object: 'chat.completion.chunk', created: 1, model: 'fixture', choices: [{ index: 0, delta, finish_reason: finish }], usage: { prompt_tokens: promptTokens, completion_tokens: 10, total_tokens: promptTokens + 10 } }) + '\n\n');
      }
      res.end('data: [DONE]\n\n');
    } catch { res.writeHead(500); res.end('fixture_model_error'); }
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
}
async function startGateway(options = {}) {
  if (!cfg) {
    await mkdir(root, { recursive: true });
    await mkdir(join(root, 'workspace'), { recursive: true });
    await mkdir(join(root, 'shared-workspace'), { recursive: true });
    await cp(fixture.package_path || join(repo, 'integrations/memory/openclaw'), join(root, 'extension'), { recursive: true });
    await mkdir(join(root, 'observer'), { recursive: true });
    await writeFile(join(root, 'observer/package.json'), JSON.stringify({ name: 'qualification-observer', version: '1.0.0', type: 'module', openclaw: { extensions: ['./plugin.mjs'] } }));
    await writeFile(join(root, 'observer/openclaw.plugin.json'), JSON.stringify({ id: 'qualification-observer', name: 'Qualification Observer', configSchema: { type: 'object', properties: {} } }));
    await writeFile(join(root, 'observer/plugin.mjs'), `import {appendFileSync} from 'node:fs';export default {id:'qualification-observer',register(api){for(const name of ['before_prompt_build','agent_end','session_end'])api.on(name,(event,ctx)=>{let current=false;try{ctx.assertMemoryAudienceCurrent?.();current=typeof ctx.assertMemoryAudienceCurrent==='function'}catch{}appendFileSync(${JSON.stringify(join(root, 'contexts.jsonl'))},JSON.stringify({hook:name,sessionId:ctx.sessionId,sessionKey:ctx.sessionKey,agentId:ctx.agentId,runId:ctx.runId,memoryAudience:ctx.memoryAudience,sandboxed:ctx.sandboxed,trigger:ctx.trigger,inputProvenance:ctx.inputProvenance,current,prompt:event.prompt,toolAuthority:!!ctx.toolAuthority,flushId:ctx.memoryFlush?.flushId})+'\\n')},name==='before_prompt_build'?{requiresToolAuthority:true}:undefined)}};`);
    await startModel();
    cfg = {
      logging: { file: join(root, 'runtime.log') },
      gateway: { mode: 'local', port: await freePort(), bind: 'loopback', auth: { mode: 'token', token }, controlUi: { enabled: false } },
      update: { checkOnStart: false }, browser: { enabled: false }, discovery: { mdns: { mode: 'off' } }, env: { shellEnv: { enabled: false } },
      agents: { ownership: 'explicit', defaults: { systemAgent: { agentId: fixture.agent_id }, workspace: join(root, 'workspace'), skipBootstrap: true, maxConcurrent: 2, model: { primary: 'fixture/fixture' }, modelPolicy: { allow: ['fixture/fixture'] }, compaction: { memoryFlush: { enabled: false } } }, entries: { [fixture.agent_id]: { workspace: join(root, 'workspace') }, other: {}, shared: { workspace: join(root, 'shared-workspace') } } },
      models: { providers: { fixture: { baseUrl: `http://127.0.0.1:${server.address().port}/v1`, apiKey: 'fixture-only', api: 'openai-completions', request: { allowPrivateNetwork: true }, models: [{ id: 'fixture', name: 'Fixture', contextWindow: 32768, maxTokens: 1024 }] } } },
      plugins: { allow: ['backplane-memory', 'qualification-observer'], load: { paths: [join(root, 'extension'), join(root, 'observer')] }, slots: { memory: 'backplane-memory' }, entries: { 'qualification-observer': { enabled: true, hooks: { allowConversationAccess: true } }, 'backplane-memory': { enabled: true, hooks: { allowConversationAccess: true }, config: {
        base_url: fixture.host_url, profile_id: fixture.profile_id || 'qualification', journal_path: join(root, 'delivery.sqlite'),
        bindings: [{ agent_id: fixture.agent_id, memory_access_id: fixture.access_id }, { agent_id: 'shared', memory_access_id: fixture.access_id }], native_sync: fixture.native_sync !== false,
        token_budget: fixture.token_budget || 2000, timeout_ms: fixture.timeout_ms || 5000,
      } } } },
    };
  }
  if (options.conversationAccess === 'missing') delete cfg.plugins.entries['backplane-memory'].hooks.allowConversationAccess;
  else if (options.conversationAccess !== undefined) cfg.plugins.entries['backplane-memory'].hooks.allowConversationAccess = options.conversationAccess;
  if (options.enabled !== undefined) cfg.plugins.entries['backplane-memory'].config.enabled = options.enabled;
  if (options.denyTools !== undefined) cfg.tools = { deny: options.denyTools };
  if (options.flush !== undefined) cfg.agents.defaults.compaction.memoryFlush = { enabled: options.flush, forceFlushTranscriptBytes: 1 };
  await writeFile(join(root, 'config.json'), JSON.stringify(cfg));
  env = { ...process.env, PATH: dirname(process.execPath) + ':' + process.env.PATH, OPENCLAW_STATE_DIR: join(root, 'state'), OPENCLAW_CONFIG_PATH: join(root, 'config.json'), OPENCLAW_GATEWAY_TOKEN: token, NO_COLOR: '1' };
  logs = '';
  gateway = spawn(process.execPath, [join(runtime, 'openclaw.mjs'), 'gateway', 'run', '--verbose'], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  for (const stream of [gateway.stdout, gateway.stderr]) stream.on('data', (chunk) => { logs += chunk; appendFileSync(join(root, 'gateway.log'), chunk); });
  await waitFor(() => { if (gateway.exitCode !== null) throw new Error('gateway_exited'); return logs.includes('http server listening'); }, 45000);
  await new Promise((resolveHello, reject) => {
    client = new GatewayClient({ url: `ws://127.0.0.1:${cfg.gateway.port}`, token, clientName: 'cli', mode: 'cli', role: 'operator', scopes: ['operator.admin', 'operator.read', 'operator.write'], env,
      onEvent: (event) => events.push(event), onHelloOk: resolveHello, onConnectError: () => reject(new Error('gateway_connect_failed')) });
    client.start(); setTimeout(() => reject(new Error('gateway_connect_timeout')), 15000).unref();
  });
  const admission = await waitForAgentAdmission();
  const registry = await rpc(client, 'plugins.inspect', { pluginId: 'backplane-memory' });
  return { version, root, gatewayPort: cfg.gateway.port, loader: { ready: true, actualPackage: true, registry, admission }, ...snapshot() };
}
async function haltGateway({ abrupt = false } = {}) {
  await conversationClient?.stop(); conversationClient = null;
  await client?.stop(); client = null;
  if (gateway && gateway.exitCode === null && gateway.signalCode === null) {
    const exited = new Promise((r) => gateway.once('exit', r)); gateway.kill(abrupt ? 'SIGKILL' : 'SIGTERM');
    const timer = setTimeout(() => gateway.kill('SIGKILL'), 10000); await exited; clearTimeout(timer);
  }
  gateway = null;
}
function snapshot() {
  stage = 'snapshot.plugin_journal';
  let journal = { deliveries: [], sources: [], meta: [], turns: [] };
  if (existsSync(join(root, 'delivery.sqlite'))) {
    const db = new DatabaseSync(join(root, 'delivery.sqlite'), { readOnly: true });
    try {
      journal = {
        deliveries: db.prepare('SELECT * FROM delivery ORDER BY sequence').all().map((r) => ({ ...r, payload: JSON.parse(r.payload), binding: JSON.parse(r.binding), receipt: r.receipt ? JSON.parse(r.receipt) : null })),
        sources: db.prepare('SELECT * FROM sources').all(),
        meta: db.prepare('SELECT * FROM meta').all().map((r) => ({ key: r.key, value: JSON.parse(r.value) })),
        turns: db.prepare('SELECT * FROM turns').all().map((r) => ({ ...r, payload: JSON.parse(r.payload) })),
      };
    } finally { db.close(); }
  }
  const actualContext = existsSync(join(root, 'contexts.jsonl')) ? readFileSync(join(root, 'contexts.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line)) : [];
  stage = 'snapshot.runtime_sessions';
  const runtimeSessions = [];
  for (const agentId of [fixture.agent_id, 'other', 'shared']) {
    const file = join(root, 'state', 'agents', agentId, 'agent', 'openclaw-agent.sqlite');
    if (!existsSync(file)) continue;
    const db = new DatabaseSync(file, { readOnly: true });
    try {
      for (const row of db.prepare('SELECT session_key,entry_json FROM session_nodes').all()) {
        const entry = JSON.parse(row.entry_json);
        runtimeSessions.push({ agentId, sessionKey: row.session_key, sessionId: entry.sessionId, lifecycleRevision: entry.lifecycleRevision, compactionCount: entry.compactionCount, memoryFlush: entry.memoryFlush });
      }
    } finally { db.close(); }
  }
  return { ...last, agentId: last.agentId || fixture.agent_id, journal, requests, events, actualContext, runtimeSessions, diagnostics: logs.split('\n').filter((line) => /backplane-memory|memory.flush|memory-flush/.test(line)) };
}
async function callerClient(caller) {
  if (caller !== 'conversation') return client;
  if (!conversationClient) await new Promise((resolveHello, reject) => {
    conversationClient = new GatewayClient({ url: `ws://127.0.0.1:${cfg.gateway.port}`, token, clientName: 'cli', mode: 'cli', role: 'operator', scopes: ['operator.read', 'operator.write'], env,
      onEvent: (event) => events.push(event), onHelloOk: resolveHello, onConnectError: () => reject(new Error('conversation_connect_failed')) });
    conversationClient.start(); setTimeout(() => reject(new Error('conversation_connect_timeout')), 15000).unref();
  });
  return conversationClient;
}
async function turn(params) {
  const requestOffset = requests.length, eventOffset = events.length;
  script = { tools: structuredClone(params.tools || []), responseText: params.responseText, flush: params.flushScript, usageTokens: params.usageTokens };
  const sessionKey = params.sessionKey || `agent:${params.agentId || fixture.agent_id}:main`;
  const dispatch = await callerClient(params.caller);
  stage = 'rpc.chat_send';
  const { sent, admission } = await sendChatWithRecovery(dispatch, { sessionKey, message: params.prompt, idempotencyKey: randomUUID() });
  stage = 'turn.wait_terminal';
  const terminal = await waitFor(() => events.slice(eventOffset).find((e) => e.event === 'chat' && e.payload?.runId === sent.runId && ['final', 'error', 'aborted'].includes(e.payload?.state)), 90000);
  const history = await rpc(client, 'chat.history', { sessionKey, limit: 200 });
  last = { sessionId: history.sessionId, sessionKey, runId: sent.runId, agentId: params.agentId || fixture.agent_id };
  const actual = requests.slice(requestOffset);
  return { ...snapshot(), admission, requests: actual, events: events.slice(eventOffset), terminal, history, finalPrompt: actual.at(-1)?.body?.messages || [], toolResults: history.messages?.filter((m) => ['tool', 'toolResult'].includes(m.role)) || [], modelToolResults: actual.flatMap((r) => r.body.messages?.filter((m) => m.role === 'tool') || []) };
}
function concurrentModelBarrier(turns) {
  const arrivals = [];
  let releasedAt, failure, release;
  const ready = new Promise((r) => { release = r; });
  const fail = (code) => { failure ||= code; release(); };
  const timer = setTimeout(() => fail('concurrent_model_overlap_timeout'), 30000);
  return {
    async arrive(body, request, requestIndex) {
      const userText = (body.messages || []).filter((message) => message.role === 'user').map((message) => typeof message.content === 'string' ? message.content : JSON.stringify(message.content));
      const matching = turns.filter((turn) => userText.some((text) => text.includes(turn.prompt)));
      if (matching.length !== 1 || arrivals.some((arrival) => arrival.agentId === matching[0].agentId)) fail('concurrent_model_request_invalid');
      else {
        arrivals.push({ agentId: matching[0].agentId, sessionKey: matching[0].sessionKey, requestIndex, receivedAt: request.receivedAt });
        if (arrivals.length === 2) { releasedAt = new Date().toISOString(); clearTimeout(timer); release(); }
      }
      await ready;
      if (failure) throw new Error(failure);
    },
    evidence: () => ({ model_requests: arrivals.length, held_until_both: arrivals.length === 2 && Boolean(releasedAt) && !failure, arrivals, releasedAt, ...(failure ? { error: failure } : {}) }),
    close() { clearTimeout(timer); if (!releasedAt && !failure) fail('concurrent_model_overlap_timeout'); },
  };
}
async function concurrentTurns(params) {
  if (!Array.isArray(params.turns) || params.turns.length !== 2 || params.tools || params.flushScript || modelBarrier) throw new Error('invalid_concurrent_turns');
  const turns = params.turns.map((turn) => ({ ...turn, sessionKey: turn.sessionKey || `agent:${turn.agentId}:qualification-overlap-${randomUUID()}` }));
  if (new Set(turns.map((turn) => turn.agentId)).size !== 2 || new Set(turns.map((turn) => turn.sessionKey)).size !== 2 || turns.some((turn) => ![fixture.agent_id, 'shared'].includes(turn.agentId) || !turn.sessionKey.startsWith(`agent:${turn.agentId}:`) || typeof turn.prompt !== 'string' || !turn.prompt.trim() || turn.tools || turn.caller || turn.flushScript) || turns[0].prompt.includes(turns[1].prompt) || turns[1].prompt.includes(turns[0].prompt)) throw new Error('invalid_concurrent_turns');
  const requestOffset = requests.length, eventOffset = events.length;
  script = { tools: [], responseText: params.responseText || 'Fixture concurrent acknowledgement.' };
  const barrier = concurrentModelBarrier(turns); modelBarrier = barrier;
  stage = 'concurrent.turns';
  try {
    // Dispatch both actual chat requests before awaiting either; the model holds
    // its first response until the other agent reaches actual HTTP generation.
    const completed = await Promise.allSettled(turns.map(async (turn) => {
      const { sent, admission } = await sendChatWithRecovery(client, { sessionKey: turn.sessionKey, message: turn.prompt, idempotencyKey: randomUUID() });
      const terminal = await waitFor(() => events.slice(eventOffset).find((event) => event.event === 'chat' && event.payload?.runId === sent.runId && ['final', 'error', 'aborted'].includes(event.payload?.state)), 90000);
      const history = await client.request('chat.history', { sessionKey: turn.sessionKey, limit: 200 });
      return { agentId: turn.agentId, prompt: turn.prompt, sessionKey: turn.sessionKey, sessionId: history.sessionId, runId: sent.runId, admission, terminal, history, events: events.slice(eventOffset).filter((event) => event.payload?.runId === sent.runId) };
    }));
    const state = snapshot();
    const results = completed.map((result, index) => result.status === 'fulfilled' ? { ...result.value, actualContext: state.actualContext.filter((ctx) => ctx.runId === result.value.runId) } : { ...turns[index], error: safeFailure(result.reason, 'concurrent.turn', 'concurrent_turns') });
    return { ...state, turns: results, overlap: barrier.evidence(), requests: requests.slice(requestOffset), events: events.slice(eventOffset) };
  } finally { barrier.close(); modelBarrier = undefined; }
}
async function operation(p) {
  switch (p.op) {
    case 'boot': return startGateway(p);
    case 'turn': return turn(p);
    case 'concurrent_turns': return concurrentTurns(p);
    case 'snapshot': case 'status': return snapshot();
    case 'native': {
      if (!['USER.md', 'MEMORY.md'].includes(p.path)) throw new Error('invalid_native_path');
      const file = join(root, 'workspace', p.path);
      if (p.content === null) await rm(file, { force: true }); else if (typeof p.content === 'string') await writeFile(file, p.content); else throw new Error('invalid_native_content');
      return { path: p.path, exists: p.content !== null };
    }
    case 'reset': {
      const previous = { ...last };
      const result = await rpc(client, 'sessions.reset', { key: p.sessionKey || last.sessionKey || `agent:${fixture.agent_id}:main` });
      return { ...snapshot(), previous, reset: result };
    }
    case 'restart': await haltGateway({ abrupt: p.abrupt === true }); return startGateway(p);
    case 'reload': {
      const result = await rpc(client, 'plugins.reload', { plugins: [{ pluginId: 'backplane-memory' }] });
      const admission = await waitForAgentAdmission();
      return { ...snapshot(), reload: result, admission };
    }
    case 'flush': {
      const modes = ['save', 'persistence', 'lookup', 'noop', 'denied'];
      if (!modes.includes(p.mode)) throw new Error('invalid_flush_mode');
      await haltGateway(); await startGateway({ flush: true, denyTools: p.mode === 'denied' ? ['backplane_memory_save', 'backplane_memory_correct'] : [] });
      // The compatible model reports synthetic near-window usage to the real host.
      // The next public chat.send must traverse the host's actual beforeCompaction flow.
      const sessionKey = p.sessionKey || `agent:${fixture.agent_id}:qualification-flush-${randomUUID()}`;
      const seed = await turn({ sessionKey, prompt: `Synthetic context-pressure fixture ${fixture.marker}; no new durable fact.`, usageTokens: 30000 });
      const tools = p.mode === 'save' || p.mode === 'persistence' ? [{ name: 'backplane_memory_save', args: p.args || { fact_key: 'flush-fixture', content: `Fixture ${fixture.marker}: provider flush fact.` } }] : p.mode === 'lookup' ? [{ name: 'backplane_memory_search', args: { query: fixture.marker } }] : [];
      const result = await turn({ prompt: p.prompt || `Continue fixture ${fixture.marker}.`, sessionKey, flushScript: { tools, responseText: p.mode === 'lookup' ? 'Lookup completed without persistence.' : 'NO_REPLY' } });
      return { ...result, flushObserved: result.requests.some((r) => r.response.isFlush), requestedMode: p.mode, trigger: { method: 'synthetic-model-usage-preflight', reportedPromptTokens: 30000, seedSessionId: seed.sessionId } };
    }
    case 'stop': await haltGateway(); if (server) await new Promise((r) => server.close(r)); server = null; stopped = true; return { stopped: true };
    default: throw new Error('unknown_operation');
  }
}
const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
try {
  for await (const line of lines) {
    let p;
    try { stage = 'operation.parse'; p = JSON.parse(line); stage = 'operation.dispatch'; const result = await operation(p); stage = 'operation.encode'; process.stdout.write(JSON.stringify({ id: p.id, ok: true, result }) + '\n'); }
    catch (error) { const safe = safeFailure(error, stage, p?.op); process.stderr.write(safe.message + '\n'); process.stdout.write(JSON.stringify({ id: p?.id, ok: false, error: safe }) + '\n'); }
    if (stopped) break;
  }
} finally { await haltGateway(); if (server) await new Promise((r) => server.close(r)); }
// The public SDK retains shared worker pools; this dedicated fixture owns this process.
process.exit(0);
