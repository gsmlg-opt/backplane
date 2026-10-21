import { describe, expect, test } from "bun:test";
import { prepare, runProtocol, classify, failureCode, phaseDeadline, validateProof } from "../memory_local_protocol_denial";

const now = Date.parse("2026-10-20T12:00:00Z");
const secret = "synthetic-token-never-disclose";
const ids = {
  primary: "11111111-1111-4111-8111-111111111111",
  isolated: "22222222-2222-4222-8222-222222222222",
  primarySpace: "33333333-3333-4333-8333-333333333333",
  isolatedSpace: "44444444-4444-4444-8444-444444444444",
};
function inputs() {
  const run_id = "protocol-test";
  const fixture = { run_id, hosts: ["primary", "isolated"].map((suffix) => {
    const host_id = ids[suffix as "primary" | "isolated"];
    return { name: `memory-local-${run_id}-${suffix}`, host_id,
      config: `/fixture/${suffix}/host.yaml`, partition: {
        memory_space_id: suffix === "primary" ? ids.primarySpace : ids.isolatedSpace,
        host_id, client_id: `host:${host_id}`, scope: `memory_local_${run_id}_${suffix}`, namespace: "private",
      } };
  }) };
  const identity = { pid: 301, birth: "darwin:1792490000:123456" };
  const proof = { schema: "memory-local-protocol-offline-proof.v1", generated_at: new Date(now).toISOString(),
    run_id, public_url: "http://127.0.0.1:4220", admin_url: "http://127.0.0.1:4221",
    isolated: { host_id: ids.isolated, config: fixture.hosts[1].config, port: 4223,
      recorded_pid: 101, recorded_descendant_pids: [102, 103], recorded_pid_gone: true,
      recorded_descendants_gone: true, no_listeners: true, admin_offline: true },
    primary: { host_id: ids.primary, identity_unchanged: true, before: identity, after: { ...identity } },
    gateway: { identity_unchanged: true, before: { ...identity, pid: 401 }, after: { ...identity, pid: 401 } },
  };
  const yaml = { agent: { host_id: ids.isolated, token: secret, http_bind: "127.0.0.1", http_port: 4223,
    hub_url: "http://localhost:4220" }, memory: { bound_scope: fixture.hosts[1].partition.scope } };
  return { fixture, proof, yaml, publicUrl: proof.public_url, adminUrl: proof.admin_url };
}
const clone = <T>(value: T): T => structuredClone(value);
const prepared = () => prepare(inputs(), now);
type Listener = (event: any) => void;
class FakeSocket {
  readyState = 0;
  listeners = new Map<string, Listener[]>();
  sent: any[] = [];
  closeCalls = 0;
  constructor(public respond: (frame: any[]) => any | undefined = defaultReply) {}
  addEventListener(name: string, fn: Listener) { this.listeners.set(name, [...(this.listeners.get(name) || []), fn]); }
  emit(name: string, event: any = {}) { for (const fn of this.listeners.get(name) || []) fn(event); }
  open() { this.readyState = 1; this.emit("open"); }
  send(raw: string) {
    const frame = JSON.parse(raw); this.sent.push(frame);
    const reply = this.respond(frame);
    if (reply !== undefined) queueMicrotask(() => this.emit("message", { data: typeof reply === "string" ? reply : JSON.stringify(reply) }));
  }
  close() { this.closeCalls++; this.readyState = 3; queueMicrotask(() => this.emit("close")); }
}
function defaultReply(frame: any[]) {
  const [join, ref, topic, event, payload] = frame;
  let response: any = {};
  let status = "ok";
  if (event === "phx_join") response = { selected: "host_memory.v2", limits: { max_changes: 100, max_frame_bytes: 524288 },
    partitions: [{ ...inputs().fixture.hosts[1].partition, current_revision: 0, applied_revision: 0, status: "snapshot_required" }], claims: [] };
  if (event === "phx_join") {
    delete response.partitions[0].host_id; delete response.partitions[0].client_id;
  }
  if (event === "memory_next") {
    status = "error";
    response = { code: payload.protocol === "host_memory.v2" ? "unauthorized" : "unsupported_protocol", retryable: false };
  }
  return [join, ref, topic, "phx_reply", { status, response }];
}
async function fakeRun(respond = defaultReply, overrides: any = {}) {
  const socket = new FakeSocket(respond);
  overrides.configureSocket?.(socket);
  const order: string[] = [];
  const report = await runProtocol(prepared(), {
    now: () => now,
    verifyPortClosed: async () => { order.push("port"); },
    createSocket: (_url: string, options: any) => {
      order.push("socket"); expect(options.headers["X-Backplane-Host-Token"]).toBe(secret);
      queueMicrotask(() => socket.open()); return socket;
    }, ...overrides,
  });
  return { report, socket, order };
}

describe("offline authority preflight", () => {
  test("requires the complete fresh parent proof and matching private fixture/config", () => {
    expect(prepared().socketUrl).toBe(`ws://127.0.0.1:4220/host-agent/socket/websocket?vsn=2.0.0&host_id=${ids.isolated}`);
    const value = inputs();
    expect(() => prepare({ ...value, proof: null }, now)).toThrow("offline_proof_required");
    for (const key of ["recorded_pid_gone", "recorded_descendants_gone", "no_listeners", "admin_offline"]) {
      for (const bad of [false, "true", undefined]) {
        const changed: any = clone(value); changed.proof.isolated[key] = bad;
        expect(() => prepare(changed, now)).toThrow("offline_proof_invalid");
      }
    }
    for (const age of [-1, 120001]) {
      const changed = clone(value); changed.proof.generated_at = new Date(now - age).toISOString();
      expect(() => prepare(changed, now)).toThrow("offline_proof_stale");
    }
    expect(() => prepare(value, now + 120000)).not.toThrow();
  });
  test("rejects mismatched identity, config, port, namespaces and source bindings", () => {
    const mutations = [
      (v: any) => v.proof.primary.identity_unchanged = false,
      (v: any) => v.proof.gateway.after.pid++,
      (v: any) => v.proof.primary.after.birth += "changed",
      (v: any) => delete v.proof.gateway.before.birth,
      (v: any) => v.proof.isolated.recorded_pid = 0,
      (v: any) => v.proof.isolated.recorded_descendant_pids = [101],
      (v: any) => v.proof.isolated.config = "/different/host.yaml",
      (v: any) => v.proof.isolated.host_id = ids.primary,
      (v: any) => v.proof.run_id = "other",
      (v: any) => v.proof.isolated.port = 4222,
      (v: any) => v.yaml.agent.host_id = ids.primary,
      (v: any) => v.yaml.agent.http_port = 4222,
      (v: any) => v.yaml.agent.http_bind = "0.0.0.0",
      (v: any) => v.yaml.memory.bound_scope = "other",
      (v: any) => v.fixture.hosts[1].partition.namespace = "public",
      (v: any) => v.fixture.hosts[1].partition.client_id = "forged",
      (v: any) => v.fixture.hosts[1].partition.memory_space_id = ids.primarySpace,
      (v: any) => v.fixture.hosts[1].config = "relative/host.yaml",
    ];
    for (const mutate of mutations) { const v = inputs(); mutate(v); expect(() => prepare(v, now)).toThrow(); }
  });
  test("rejects remote, credentialed, nonbase and mismatching public/Admin URLs", () => {
    for (const url of ["http://remote.invalid:4220", "http://user:secret@localhost:4220", "https://localhost:4220",
      "http://127.0.0.1:4220/path", "http://localhost:4220?token=secret", "http://localhost:4220#x", "http://localhost:0"]) {
      const v = inputs(); v.publicUrl = url; expect(() => prepare(v, now)).toThrow();
      const a = inputs(); a.adminUrl = url; expect(() => prepare(a, now)).toThrow();
    }
    const v = inputs(); v.yaml.agent.hub_url = "http://remote.invalid:4220";
    expect(() => prepare(v, now)).toThrow();
  });
});

describe("bounded negative protocol exchange", () => {
  test("checks the port immediately before connecting and sends exactly two negative requests", async () => {
    const { report, socket, order } = await fakeRun();
    expect(order).toEqual(["port", "socket"]);
    expect(classify(report)).toBe("passed-protocol-negative-subset");
    expect(socket.sent.map((f) => f[3])).toEqual(["phx_join", "memory_next", "memory_next", "phx_leave"]);
    expect(socket.sent[0][4]).toEqual({ memory_v2: { offers: ["host_memory.v2"], partitions: [] } });
    expect(socket.sent[1][4]).toEqual({ protocol: "host_memory.v2", partition: {
      memory_space_id: ids.primarySpace, scope: inputs().fixture.hosts[0].partition.scope, namespace: "private" }, applied_revision: 0 });
    expect(socket.sent[2][4].protocol).toBe("host_memory.v1");
    expect(socket.sent[2][4].partition.memory_space_id).toBe(ids.isolatedSpace);
    expect(new Set(socket.sent.map((f) => f[1])).size).toBe(4);
    expect(report.probes.map((p: any) => p.code)).toEqual(["unauthorized", "unsupported_protocol"]);
    expect(report.socket).toMatchObject({ leave_attempted: true, leave_reply: true, close_attempted: true, closed: true, cleanup_failed: false });
    expect(report.complete_l13).toBe(false);
    expect(JSON.stringify(report)).not.toContain(secret);
    expect(JSON.stringify(report)).not.toContain("snapshot_required");
  });
  test("never connects if port check fails or proof expires during preflight", async () => {
    let creates = 0;
    for (const mode of ["port", "expired"]) {
      let time = now;
      const report = await runProtocol(prepared(), { now: () => time,
        verifyPortClosed: async () => { if (mode === "port") throw new Error(secret); time += 120001; },
        createSocket: () => { creates++; throw new Error(secret); } });
      expect(report.status).toBe("failed"); expect(JSON.stringify(report)).not.toContain(secret);
    }
    expect(creates).toBe(0);
  });
  test("rejects wrong codes, retryable denials, protected extras, malformed and miscorrelated frames", async () => {
    const mutations = [
      (r: any) => r[4].response.code = "invalid_request",
      (r: any) => r[4].response.retryable = true,
      (r: any) => r[4].response.changes = [{ content: secret }],
      (r: any) => r[4].response.snapshot_id = secret,
      (r: any) => r[4].response.error = secret,
      (r: any) => r[4].status = "ok",
      (r: any) => r[0] = "foreign-join",
      (r: any) => r[1] = "foreign-ref",
      (r: any) => r[2] = "host_agent:other",
      (r: any) => r[3] = "memory_batch",
      (r: any) => r.push(secret),
    ];
    for (const mutate of mutations) {
      const { report, socket } = await fakeRun((frame) => {
        const reply = defaultReply(frame); if (frame[3] === "memory_next") mutate(reply); return reply;
      });
      expect(report.status).toBe("failed"); expect(report.socket.closed).toBe(true);
      expect(socket.sent.at(-1)[3]).toBe("phx_leave"); expect(JSON.stringify(report)).not.toContain(secret);
    }
    const { report } = await fakeRun((f) => f[3] === "memory_next" ? secret : defaultReply(f));
    expect(report.status).toBe("failed"); expect(report.socket.closed).toBe(true);
  });
  test("rejects foreign or protected join inventory and still leaves and closes", async () => {
    for (const mutate of [
      (r: any) => r[4].response.partitions[0].memory_space_id = ids.primarySpace,
      (r: any) => r[4].response.partitions[0].snapshot = { content: secret },
      (r: any) => r[4].response.selected = "host_memory.v1",
      (r: any) => r[4].response.content = secret,
    ]) {
      const { report, socket } = await fakeRun((f) => { const r = defaultReply(f); if (f[3] === "phx_join") mutate(r); return r; });
      expect(report.status).toBe("failed"); expect(socket.sent.map((f) => f[3])).toEqual(["phx_join", "phx_leave"]);
      expect(report.socket.closed).toBe(true); expect(JSON.stringify(report)).not.toContain(secret);
    }
  });
  test("cleanup failure cannot pass even after both correct denials", async () => {
    const { report, socket } = await fakeRun((f) => { const r = defaultReply(f); if (f[3] === "phx_leave") r[4].response = { content: secret }; return r; });
    expect(report.probes).toHaveLength(2); expect(report.socket.cleanup_failed).toBe(true);
    expect(report.status).toBe("failed"); expect(socket.closeCalls).toBe(1);
    expect(JSON.stringify(report)).not.toContain(secret);
    const good = (await fakeRun()).report;
    for (const field of ["closed", "leave_reply"]) expect(classify({ ...good, socket: { ...good.socket, [field]: false } })).toBe("failed");
  });
  test("accepts only Phoenix's empty owned post-leave channel close", async () => {
    for (const mode of ["valid", "foreign_ref", "foreign_topic", "content", "early"]) {
      const { report } = await fakeRun(defaultReply, { configureSocket: (socket: FakeSocket) => {
        socket.addEventListener("message", (event) => {
          const frame = JSON.parse(event.data);
          if (frame[3] !== "phx_reply" || (mode === "early" ? frame[1] !== "2" : frame[1] !== "4")) return;
          const close = [frame[0], frame[0], frame[2], "phx_close", {}];
          if (mode === "foreign_ref") close[1] = "foreign";
          if (mode === "foreign_topic") close[2] = "host_agent:foreign";
          if (mode === "content") close[4] = { content: secret };
          queueMicrotask(() => socket.emit("message", { data: JSON.stringify(close) }));
        });
      } });
      expect(report.status).toBe(mode === "valid" ? "passed-protocol-negative-subset" : "failed");
      expect(report.socket.closed).toBe(true);
      expect(JSON.stringify(report)).not.toContain(secret);
    }
  });
  test("phase deadlines cap at 10 seconds and reserve cleanup within 30 seconds", () => {
    expect(phaseDeadline(now, now, false)).toBe(now + 10000);
    expect(phaseDeadline(now + 24000, now, false)).toBe(now + 25000);
    expect(phaseDeadline(now + 24000, now, true)).toBe(now + 30000);
    expect(() => phaseDeadline(now + 30000, now, true)).toThrow("deadline_exceeded");
    expect(() => validateProof(inputs().proof, prepared(), now + 120001)).toThrow("offline_proof_stale");
    expect(failureCode(new Error(secret))).toBe("driver_failed");
  });
});
