#!/usr/bin/env bun
/** Two negative sync probes only. Never starts a host, requests an authorized batch, or sends an ACK. */
import { execFile } from "node:child_process";
import { constants } from "node:fs";
import { lstat, mkdir, open, readFile, realpath } from "node:fs/promises";
import { dirname, isAbsolute, join, resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "..");
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PROOF_SCHEMA = "memory-local-protocol-offline-proof.v1";
class CheckFailed extends Error {}
function requireCheck(value: unknown, code: string): asserts value {
  if (!value) throw new CheckFailed(code);
}
function record(value: any): value is Record<string, any> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function exact(value: any, keys: string[], code: string) {
  requireCheck(record(value) && Object.keys(value).sort().join(",") === [...keys].sort().join(","), code);
}
const positive = (value: any) => Number.isSafeInteger(value) && value > 0;
const revision = (value: any) => Number.isSafeInteger(value) && value >= 0;
function baseUrl(value: any): string {
  try {
    const url = new URL(value);
    requireCheck(typeof value === "string" && url.protocol === "http:" &&
      ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname) && !url.username && !url.password &&
      url.pathname === "/" && !url.search && !url.hash && Number(url.port || 80) > 0, "loopback_base_required");
    return url.origin;
  } catch { throw new CheckFailed("loopback_base_required"); }
}
function wirePartition(host: any) {
  const { memory_space_id, scope, namespace } = host.partition;
  return { memory_space_id, scope, namespace };
}
export function prepare(input: any, now: number) {
  const fixture = input.fixture;
  requireCheck(record(fixture) && typeof fixture.run_id === "string" && /^[a-z0-9][a-z0-9-]{0,49}$/.test(fixture.run_id) &&
    Array.isArray(fixture.hosts) && fixture.hosts.length === 2, "fixture_invalid");
  const hosts = ["primary", "isolated"].map((suffix) => {
    const host = fixture.hosts.find((h: any) => h?.name === `memory-local-${fixture.run_id}-${suffix}`);
    const p = host?.partition;
    requireCheck(record(host) && UUID.test(host.host_id) && record(p) && UUID.test(p.memory_space_id) &&
      p.host_id === host.host_id && p.client_id === `host:${host.host_id}` && p.namespace === "private" &&
      p.scope === `memory_local_${fixture.run_id}_${suffix}` && typeof host.config === "string" &&
      isAbsolute(host.config) && resolve(host.config) === host.config &&
      host.config.endsWith(`/${suffix}/host.yaml`), "fixture_invalid");
    return { host_id: host.host_id, config: host.config, partition: wirePartition(host) };
  });
  const [primary, isolated] = hosts;
  requireCheck(primary.host_id !== isolated.host_id && primary.partition.memory_space_id !== isolated.partition.memory_space_id &&
    dirname(dirname(primary.config)) === dirname(dirname(isolated.config)), "fixture_invalid");
  const publicUrl = baseUrl(input.publicUrl), adminUrl = baseUrl(input.adminUrl);
  requireCheck(publicUrl !== adminUrl && ![publicUrl, adminUrl].some((u) => new URL(u).port === "4223"), "endpoint_conflict");
  const agent = input.yaml?.agent;
  requireCheck(record(agent) && agent.host_id === isolated.host_id && agent.http_port === 4223 &&
    ["127.0.0.1", "localhost", "::1"].includes(agent.http_bind) &&
    typeof agent.token === "string" && agent.token.length > 0 && agent.token.length <= 4096 &&
    !/[\r\n\0]/.test(agent.token) && input.yaml?.memory?.bound_scope === isolated.partition.scope,
  "host_config_mismatch");
  requireCheck(new URL(baseUrl(agent.hub_url)).port === new URL(publicUrl).port, "host_config_mismatch");
  const socket = new URL(publicUrl);
  socket.protocol = "ws:";
  socket.pathname = "/host-agent/socket/websocket";
  socket.search = new URLSearchParams({ vsn: "2.0.0", host_id: isolated.host_id }).toString();
  const prepared = { runId: fixture.run_id, primary, isolated, publicUrl, adminUrl,
    socketUrl: socket.toString(), token: agent.token, proof: input.proof };
  validateProof(input.proof, prepared, now);
  return prepared;
}
export function validateProof(proof: any, prepared: any, now: number) {
  requireCheck(record(proof), "offline_proof_required");
  const code = "offline_proof_invalid";
  exact(proof, ["schema", "generated_at", "run_id", "public_url", "admin_url", "isolated", "primary", "gateway"], code);
  requireCheck(proof.schema === PROOF_SCHEMA && proof.run_id === prepared.runId &&
    baseUrl(proof.public_url) === prepared.publicUrl && baseUrl(proof.admin_url) === prepared.adminUrl, code);
  requireCheck(typeof proof.generated_at === "string" && /^\d{4}-\d\d-\d\dT.*Z$/.test(proof.generated_at), code);
  const age = now - Date.parse(proof.generated_at);
  requireCheck(Number.isFinite(age) && age >= 0 && age <= 120000, "offline_proof_stale");
  const isolated = proof.isolated;
  exact(isolated, ["host_id", "config", "port", "recorded_pid", "recorded_descendant_pids", "recorded_pid_gone",
    "recorded_descendants_gone", "no_listeners", "admin_offline"], code);
  requireCheck(isolated.host_id === prepared.isolated.host_id && isolated.config === prepared.isolated.config &&
    isolated.port === 4223 && positive(isolated.recorded_pid) && Array.isArray(isolated.recorded_descendant_pids) &&
    isolated.recorded_descendant_pids.every(positive) &&
    new Set([isolated.recorded_pid, ...isolated.recorded_descendant_pids]).size === isolated.recorded_descendant_pids.length + 1 &&
    ["recorded_pid_gone", "recorded_descendants_gone", "no_listeners", "admin_offline"].every((key) => isolated[key] === true), code);
  for (const name of ["primary", "gateway"]) {
    const entry = proof[name];
    exact(entry, name === "primary" ? ["host_id", "identity_unchanged", "before", "after"] : ["identity_unchanged", "before", "after"], code);
    requireCheck(entry.identity_unchanged === true && (name !== "primary" || entry.host_id === prepared.primary.host_id), code);
    for (const identity of [entry.before, entry.after]) {
      exact(identity, ["pid", "birth"], code);
      requireCheck(positive(identity.pid) && typeof identity.birth === "string" &&
        /^(darwin:\d+:\d+|proc:\d+)$/.test(identity.birth), code);
    }
    requireCheck(entry.before.pid === entry.after.pid && entry.before.birth === entry.after.birth &&
      ![isolated.recorded_pid, ...isolated.recorded_descendant_pids].includes(entry.after.pid), code);
  }
  requireCheck(proof.primary.after.pid !== proof.gateway.after.pid, code);
}
export function phaseDeadline(now: number, started: number, cleanup: boolean) {
  const deadline = Math.min(now + 10000, started + (cleanup ? 30000 : 25000));
  requireCheck(deadline > now, "deadline_exceeded");
  return deadline;
}
export function failureCode(error: unknown): string {
  return error instanceof CheckFailed ? error.message : "driver_failed";
}
function bounded<T>(promise: Promise<T>, deadline: number, now: () => number): Promise<T> {
  const remaining = deadline - now();
  if (remaining <= 0) return Promise.reject(new CheckFailed("deadline_exceeded"));
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new CheckFailed("deadline_exceeded")), remaining);
    promise.then((value) => { clearTimeout(timer); resolve(value); }, (error) => { clearTimeout(timer); reject(error); });
  });
}
function joinReply(payload: any, prepared: any) {
  exact(payload, ["status", "response"], "reply_invalid");
  requireCheck(payload.status === "ok", "join_rejected");
  const r = payload.response;
  exact(r, ["selected", "limits", "partitions", "claims"], "join_invalid");
  exact(r.limits, ["max_changes", "max_frame_bytes"], "join_invalid");
  requireCheck(r.selected === "host_memory.v2" && positive(r.limits.max_changes) && r.limits.max_changes <= 100 &&
    positive(r.limits.max_frame_bytes) && r.limits.max_frame_bytes <= 524288 && Array.isArray(r.claims) &&
    r.claims.length === 0 && Array.isArray(r.partitions) && r.partitions.length === 1, "join_invalid");
  const p = r.partitions[0];
  exact(p, ["memory_space_id", "scope", "namespace", "current_revision", "applied_revision", "status"], "join_invalid");
  requireCheck(Object.entries(prepared.isolated.partition).every(([key, value]) => p[key] === value) &&
    revision(p.current_revision) && revision(p.applied_revision) && p.applied_revision <= p.current_revision &&
    ["ready", "snapshot_required"].includes(p.status), "join_invalid");
}
function denialReply(payload: any, expectedCode: string) {
  exact(payload, ["status", "response"], "reply_invalid");
  exact(payload.response, ["code", "retryable"], "denial_invalid");
  requireCheck(payload.status === "error" && payload.response.code === expectedCode && payload.response.retryable === false, "denial_invalid");
}
function leaveReply(payload: any) {
  exact(payload, ["status", "response"], "leave_invalid");
  exact(payload.response, [], "leave_invalid");
  requireCheck(payload.status === "ok", "leave_invalid");
}

type SocketLike = {
  readyState: number;
  addEventListener: (name: string, listener: (event: any) => void) => void;
  send: (value: string) => void;
  close: () => void;
};
class Exchange {
  ref = 0;
  joinRef = "1";
  pending: any = null;
  fatal: CheckFailed | null = null;
  opened = false;
  closed = false;
  leaveReplied = false;
  channelClosed = false;
  openPromise: Promise<void>;
  closedPromise: Promise<void>;
  constructor(public socket: SocketLike, public topic: string, public now: () => number) {
    let openResolve!: () => void, openReject!: (error: Error) => void, closedResolve!: () => void;
    this.openPromise = new Promise((resolve, reject) => { openResolve = resolve; openReject = reject; });
    this.closedPromise = new Promise((resolve) => { closedResolve = resolve; });
    socket.addEventListener("open", () => { this.opened = true; openResolve(); });
    socket.addEventListener("close", () => {
      this.closed = true; closedResolve();
      openReject(new CheckFailed("socket_closed")); this.pending?.reject(new CheckFailed("socket_closed"));
    });
    socket.addEventListener("error", () => {
      const error = new CheckFailed("socket_error"); this.fatal = error; openReject(error); this.pending?.reject(error);
    });
    socket.addEventListener("message", (event) => {
      try {
        requireCheck(typeof event.data === "string" && event.data.length <= 65536, "frame_invalid");
        let frame;
        try { frame = JSON.parse(event.data); } catch { throw new CheckFailed("frame_invalid"); }
        requireCheck(Array.isArray(frame) && frame.length === 5, "frame_invalid");
        // Phoenix.Socket.encode_close/3 follows a successful leave reply with this exact empty frame.
        if (frame[3] === "phx_close") {
          requireCheck(this.leaveReplied && !this.channelClosed && frame[0] === this.joinRef &&
            frame[1] === this.joinRef && frame[2] === this.topic, "frame_correlation_failed");
          exact(frame[4], [], "frame_invalid");
          this.channelClosed = true;
          return;
        }
        requireCheck(this.pending && frame[0] === this.joinRef &&
          frame[1] === this.pending.ref && frame[2] === this.topic && frame[3] === "phx_reply", "frame_correlation_failed");
        this.pending.validate(frame[4]);
        if (this.pending.event === "phx_leave") this.leaveReplied = true;
        this.pending.resolve();
      } catch (error) {
        this.fatal = error instanceof CheckFailed ? error : new CheckFailed("frame_invalid");
        this.pending?.reject(this.fatal);
      }
    });
  }
  async request(event: string, payload: any, validate: (reply: any) => void, deadline: number, cleanup = false) {
    if (this.fatal && !cleanup) throw this.fatal;
    requireCheck(this.socket.readyState === 1 && !this.pending, "socket_not_ready");
    const ref = String(++this.ref);
    const reply = new Promise<void>((resolve, reject) => { this.pending = { ref, event, validate, resolve, reject }; });
    try {
      this.socket.send(JSON.stringify([this.joinRef, ref, this.topic, event, payload]));
      await bounded(reply, deadline, this.now);
    } finally { this.pending = null; }
  }
}
function newReport(prepared: any, started: number): any {
  return { schema: "memory-local-protocol-denial.v1", started_at: new Date(started).toISOString(), run_id: prepared.runId,
    fixture_ids: { primary_host_id: prepared.primary.host_id, isolated_host_id: prepared.isolated.host_id,
      primary_memory_space_id: prepared.primary.partition.memory_space_id, isolated_memory_space_id: prepared.isolated.partition.memory_space_id },
    status: "failed", complete_l13: false, scope: "owned_socket_lifecycle_only", probes: [],
    socket: { created: false, opened: false, joined: false, leave_attempted: false, leave_reply: false,
      close_attempted: false, closed: false, cleanup_failed: false },
    parent_postconditions_required: ["isolated_admin_offline", "primary_identity_unchanged", "gateway_identity_unchanged"],
    limits: { same_space_grants: "not_tested", revocation: "not_tested", facade_protected_cache: "not_tested" } };
}
export function classify(report: any) {
  const s = report.socket;
  return !report.failure && report.probes.length === 2 &&
    report.probes[0].code === "unauthorized" && report.probes[1].code === "unsupported_protocol" &&
    report.probes.every((p: any) => p.retryable === false && p.response_content_present === false) &&
    s.created && s.opened && s.joined && s.leave_attempted && s.leave_reply && s.close_attempted && s.closed && !s.cleanup_failed
    ? "passed-protocol-negative-subset" : "failed";
}
export async function runProtocol(prepared: any, deps: {
  now: () => number;
  verifyPortClosed: (deadline: number) => Promise<void>;
  createSocket: (url: string, options: any) => SocketLike;
}) {
  const started = deps.now(), report = newReport(prepared, started);
  let exchange: Exchange | undefined, socket: SocketLike | undefined, joinSent = false;
  try {
    validateProof(prepared.proof, prepared, deps.now());
    await bounded(deps.verifyPortClosed(phaseDeadline(deps.now(), started, false)), phaseDeadline(deps.now(), started, false), deps.now);
    validateProof(prepared.proof, prepared, deps.now());
    phaseDeadline(deps.now(), started, false);
    socket = deps.createSocket(prepared.socketUrl, { headers: { "X-Backplane-Host-Token": prepared.token } });
    report.socket.created = true;
    exchange = new Exchange(socket, `host_agent:${prepared.isolated.host_id}`, deps.now);
    await bounded(exchange.openPromise, phaseDeadline(deps.now(), started, false), deps.now);
    report.socket.opened = true;
    joinSent = true;
    await exchange.request("phx_join", { memory_v2: { offers: ["host_memory.v2"], partitions: [] } },
      (reply) => joinReply(reply, prepared), phaseDeadline(deps.now(), started, false));
    report.socket.joined = true;
    for (const [name, protocol, partition, code] of [
      ["foreign_partition", "host_memory.v2", prepared.primary.partition, "unauthorized"],
      ["unsupported_protocol", "host_memory.v1", prepared.isolated.partition, "unsupported_protocol"],
    ] as const) {
      await exchange.request("memory_next", { protocol, partition, applied_revision: 0 },
        (reply) => denialReply(reply, code), phaseDeadline(deps.now(), started, false));
      report.probes.push({ name, code, retryable: false, response_content_present: false });
    }
  } catch (error) { report.failure = failureCode(error); }
  finally {
    if (socket) {
      try {
        if (joinSent && exchange && socket.readyState === 1) {
          report.socket.leave_attempted = true;
          await exchange.request("phx_leave", {}, leaveReply, phaseDeadline(deps.now(), started, true), true);
          report.socket.leave_reply = true;
        }
      } catch (error) { report.socket.cleanup_failed = true; report.socket.cleanup_failure = failureCode(error); }
      finally {
        report.socket.close_attempted = true;
        try {
          socket.close();
          requireCheck(exchange, "socket_cleanup_unproven");
          await bounded(exchange.closedPromise, phaseDeadline(deps.now(), started, true), deps.now);
          report.socket.closed = exchange.closed;
        } catch (error) { report.socket.cleanup_failed = true; report.socket.cleanup_failure = failureCode(error); }
        if (!report.socket.leave_reply || !report.socket.closed) report.socket.cleanup_failed = true;
        if (exchange?.fatal && !report.failure) report.failure = failureCode(exchange.fatal);
      }
    }
  }
  report.status = classify(report);
  report.elapsed_ms = Math.max(0, deps.now() - started);
  return report;
}

function verifyPortClosed(deadline: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const timeout = deadline - Date.now();
    if (timeout <= 0) return reject(new CheckFailed("deadline_exceeded"));
    execFile("lsof", ["-nP", "-iTCP:4223", "-sTCP:LISTEN", "-t"], { timeout, maxBuffer: 65536 }, (error, stdout, stderr) => {
      if (stdout.trim()) reject(new CheckFailed("isolated_port_listening"));
      else if (error && (error as any).code === 1 && !stderr.trim()) resolve();
      else reject(new CheckFailed("isolated_port_check_unproven"));
    });
  });
}
async function privateText(path: string) {
  const info = await lstat(path);
  requireCheck(info.isFile() && !info.isSymbolicLink() && info.size <= 1048576 &&
    (info.mode & 0o077) === 0 && info.uid === process.getuid?.(), "private_input_required");
  return readFile(path, "utf8");
}
async function writeEvidence(report: any): Promise<string> {
  let path = ROOT;
  for (const name of [".devenv", "memory-local-evidence"]) {
    path = join(path, name);
    await mkdir(path, { mode: 0o700 }).catch((error) => { if (error.code !== "EEXIST") throw error; });
    const info = await lstat(path);
    requireCheck(info.isDirectory() && !info.isSymbolicLink() && info.uid === process.getuid?.(), "evidence_directory_unsafe");
  }
  const dir = join(path, `protocol-denial-${Date.now()}-${crypto.randomUUID()}`);
  await mkdir(dir, { mode: 0o700 });
  const target = join(dir, "report.json");
  const file = await open(target, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600);
  try { await file.writeFile(JSON.stringify(report, null, 2) + "\n"); } finally { await file.close(); }
  return target;
}
const HELP = `Usage: bun scripts/memory_local_protocol_denial.ts --fixture FILE --offline-proof FILE
  [--public-url http://127.0.0.1:4220] [--admin-url http://127.0.0.1:4221]

Inputs must be owned regular private files (mode0600), not symlinks.
No host lifecycle actions, grants, revocations, authorized batches or ACKs.
Parent must generate the proof immediately before execution; maximum age120s.
The driver checks port4223 again immediately before its owned WebSocket opens.
Evidence uses a new mode0700 directory/mode0600 report under .devenv/memory-local-evidence.
Parent must separately verify Admin offline and primary/gateway identities unchanged afterward.
Passing this subset never marks complete_l13 true.

Offline proof schema (replace fixture IDs, config, real process identities and time):
${JSON.stringify({ schema: PROOF_SCHEMA, generated_at: "YYYY-MM-DDTHH:mm:ss.sssZ", run_id: "RUN_ID",
  public_url: "http://127.0.0.1:4220", admin_url: "http://127.0.0.1:4221",
  isolated: { host_id: "ISOLATED_UUID", config: "/absolute/isolated/host.yaml", port: 4223,
    recorded_pid: 101, recorded_descendant_pids: [102], recorded_pid_gone: true,
    recorded_descendants_gone: true, no_listeners: true, admin_offline: true },
  primary: { host_id: "PRIMARY_UUID", identity_unchanged: true,
    before: { pid: 201, birth: "darwin:SECONDS:MICROS" }, after: { pid: 201, birth: "darwin:SECONDS:MICROS" } },
  gateway: { identity_unchanged: true,
    before: { pid: 301, birth: "darwin:SECONDS:MICROS" }, after: { pid: 301, birth: "darwin:SECONDS:MICROS" } },
}, null, 2)}
Linux process birth uses proc:TICKS instead of darwin:SECONDS:MICROS.
`;
async function main() {
  if (process.argv.slice(2).length === 1 && process.argv[2] === "--help") { console.log(HELP); return; }
  let report: any;
  try {
    const args = process.argv.slice(2), options: Record<string, string> = {};
    for (let i = 0; i < args.length; i += 2) {
      requireCheck(["--fixture", "--offline-proof", "--public-url", "--admin-url"].includes(args[i]) &&
        !options[args[i]] && typeof args[i + 1] === "string" && !args[i + 1].startsWith("--"), "arguments_invalid");
      options[args[i]] = args[i + 1];
    }
    requireCheck(options["--fixture"] && options["--offline-proof"], "arguments_invalid");
    const fixturePath = resolve(options["--fixture"]);
    const fixture = JSON.parse(await privateText(fixturePath));
    const proof = JSON.parse(await privateText(resolve(options["--offline-proof"])));
    const isolatedConfig = fixture.hosts?.find((h: any) => h?.name === `memory-local-${fixture.run_id}-isolated`)?.config;
    requireCheck(typeof isolatedConfig === "string" && isAbsolute(isolatedConfig), "fixture_invalid");
    const configText = await privateText(isolatedConfig);
    const prepared = prepare({ fixture, proof, yaml: Bun.YAML.parse(configText),
      publicUrl: options["--public-url"] || "http://127.0.0.1:4220",
      adminUrl: options["--admin-url"] || "http://127.0.0.1:4221" }, Date.now());
    requireCheck(await realpath(isolatedConfig) === isolatedConfig &&
      await realpath(fixturePath) === join(dirname(dirname(isolatedConfig)), "fixture.json"), "fixture_path_mismatch");
    report = await runProtocol(prepared, { now: Date.now, verifyPortClosed,
      createSocket: (url, options) => new WebSocket(url, options) as SocketLike });
  } catch (error) {
    report = { schema: "memory-local-protocol-denial.v1", status: "failed", failure: failureCode(error), complete_l13: false,
      scope: "owned_socket_lifecycle_only", socket: { created: false }, probes: [] };
  }
  try {
    const evidence_file = await writeEvidence(report);
    console.log(JSON.stringify({ status: report.status, complete_l13: false, evidence_file }));
  } catch { console.log(JSON.stringify({ status: "failed", failure: "evidence_write_failed", complete_l13: false })); process.exitCode = 1; }
  if (report.status !== "passed-protocol-negative-subset") process.exitCode = 1;
}
if (import.meta.main) await main();
