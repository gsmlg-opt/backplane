import assert from "node:assert/strict";
import test from "node:test";
import plugin from "../openclaw/plugin.mjs";

function setup(fallback = true) {
  const handlers = {};
  const warnings = [];
  plugin.register({
    pluginConfig: { fallback_on_error: fallback },
    on: (name, handler) => { handlers[name] = handler; },
    logger: { warn: (message) => warnings.push(message) },
    registerMemoryCapability: () => {},
  });
  return { handlers, warnings };
}

for (const code of ["invalid_arguments", "memory_scope_mismatch"]) {
  test(`HTTP ${code} remains fail-open with safe status and error diagnostics`, async () => {
    const { handlers, warnings } = setup();
    globalThis.fetch = async () => ({
      ok: false, status: 400,
      json: async () => ({ ok: false, error: code, detail: "private-secret" }),
    });
    assert.equal(await handlers.before_agent_start({ prompt: "private-secret" }), undefined);
    assert.equal(warnings.length, 1);
    assert.match(warnings[0], /HTTP 400/);
    assert.ok(warnings[0].includes(code));
    assert.doesNotMatch(warnings[0], /private-secret/);
  });
}

test("protocol failures are diagnosed instead of reported as empty recall", async () => {
  for (const body of [{ ok: false, error: "invalid_scope" }, [],
                      { ok: true, result: "private-secret" }]) {
    const { handlers, warnings } = setup();
    globalThis.fetch = async () => ({ ok: true, json: async () => body });
    assert.equal(await handlers.before_agent_start({ prompt: "fact" }), undefined);
    assert.equal(warnings.length, 1);
    assert.doesNotMatch(warnings[0], /private-secret/);
  }
});

test("strict HTTP failures never expose provider error details", async () => {
  const { handlers } = setup(false);
  globalThis.fetch = async () => ({
    ok: false, status: 403,
    json: async () => ({ error: "private-secret" }),
    text: async () => "private-secret",
  });
  await assert.rejects(handlers.before_agent_start({ prompt: "fact" }), (error) => {
    assert.match(error.message, /HTTP 403/);
    assert.doesNotMatch(error.message, /private-secret/);
    return true;
  });
});

test("recalled provisional memories are marked without relabeling canonical entries", async () => {
  const { handlers } = setup();
  globalThis.fetch = async () => ({
    ok: true,
    json: async () => ({ ok: true, result: { results: [
      { content: "canonical fact", authority: "canonical" },
      { content: "pending flag", provisional: true },
      { content: "pending authority", authority: "provisional" },
    ] } }),
  });
  const context = await handlers.before_agent_start({ prompt: "fact" });
  assert.match(context.prependContext, /Memory 1: canonical fact/);
  assert.match(context.prependContext, /\[pending local memory\] pending flag/);
  assert.match(context.prependContext, /\[pending local memory\] pending authority/);
});
