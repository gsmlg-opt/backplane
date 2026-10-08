const D = Deno;
const enc = new TextEncoder();
const out = value => {
  try { D.stdout.writeSync(enc.encode(JSON.stringify(value) + "\n")); }
  catch (error) {
    // Host cancellation closes the pipe. There is no recipient left to settle.
    if (error.name === "BrokenPipe") D.exit(0);
    throw error;
  }
};
const pending = new Map();
let iterator = null, nextId = 0, stored = {}, metadata = [];
const fail = message => { throw new Error(message); };
const call = (name, value, rawInput) => {
  if (typeof name !== "string" || name.length === 0) return Promise.reject(new Error("tool name is required"));
  if (pending.size > 0) return Promise.reject(new Error("concurrent nested calls are rejected"));
  const id = String(++nextId);
  out({type:"tool_call", id, name, arguments: rawInput === undefined ? value : undefined, rawInput});
  return new Promise((resolve, reject) => pending.set(id, {resolve, reject}));
};
const stringify = value => typeof value === "string" ? value : JSON.stringify(value) ?? String(value);
const emit = item => out({type:"output", item});
const media = (type, value, detail) => {
  let item;
  if (value && value.type === type && typeof value.data === "string" && typeof value.mimeType === "string") item = {...value};
  else {
    const url = typeof value === "string" ? value : value && value[type + "_url"];
    const match = typeof url === "string" && /^data:([^;,]+);base64,([a-zA-Z0-9+/=]*)$/.exec(url);
    if (!match) throw new Error(type + " requires a base64 data URL or content block");
    item = {type, mimeType:match[1], data:match[2]};
  }
  const selected = detail ?? value?.detail ?? value?._meta?.["codex/imageDetail"];
  if (type === "image" && selected != null) item.detail = selected;
  emit(item);
};
const tools = new Proxy(Object.create(null), {get: (_, name) => {
  const matches = metadata.filter(item => item.name.replaceAll("::", "__") === name || item.name === name || item.tool_name === name);
  if (!matches.length) return undefined;
  if (matches.length > 1) return () => Promise.reject(new Error("normalized tool name is ambiguous; use its canonical name"));
  const tool = matches[0];
  return value => tool.input_kind === "custom" ? call(tool.tool_name || tool.name, undefined, value) : call(tool.tool_name || tool.name, value);
}});
Object.assign(globalThis, {
  tools,
  text: value => emit({type:"text", text:stringify(value)}),
  image: (value, detail) => media("image", value, detail),
  audio: value => media("audio", value),
  generatedImage: value => { media("image", value); if (value.output_hint) emit({type:"text", text:value.output_hint}); },
  notify: value => out({type:"notify", value:stringify(value)}),
  store: (key, value) => {
    if (typeof key !== "string") throw new Error("store key must be a string");
    const snapshot = JSON.parse(JSON.stringify(value));
    Object.defineProperty(stored, key, {value:snapshot, writable:true, enumerable:true, configurable:true}); out({type:"store", key, value:snapshot});
  },
  load: key => Object.hasOwn(stored, key) ? stored[key] : undefined,
  exit: () => { throw {codexExit:true}; },
  yield_control: () => { out({type:"control_yield"}); }
});
const codex = Object.freeze({tool: (name, args) => call(name, args), custom: (name, raw) => call(name, undefined, raw)});
globalThis.console = Object.freeze({log:()=>{}, info:()=>{}, warn:()=>{}, error:()=>{}, debug:()=>{}});
globalThis.fetch = () => Promise.reject(new Error("network access is disabled"));
try { Object.defineProperty(globalThis, "Deno", {value: undefined, configurable: false}); } catch (_) {}
globalThis.codex = codex;
const reportError = error => {
  if (error && error.codexExit) out({type:"complete"});
  else out({type:"error", error:{class:"execution_failure", message:String(error && error.message || error)}});
};
const advance = async value => {
  try {
    const result = await iterator.next(value);
    if (result.done) out({type:"complete", value: result.value});
    else out({type:"yield", value: result.value});
  } catch (error) { reportError(error); }
};
// Decode bytes incrementally. Count each record before decoding/appending, so a
// fragmented or whitespace-only record cannot grow the retained buffer unbounded.
async function* records(stream) {
  const decoder = new TextDecoder("utf-8", {fatal:true});
  let partial = "", bytes = 0;
  for await (const chunk of stream) {
    let start = 0;
    for (let i = 0; i <= chunk.length; i++) {
      if (i !== chunk.length && chunk[i] !== 10) continue;
      const piece = chunk.subarray(start, i);
      bytes += piece.byteLength;
      if (bytes > 1048576) throw {protocolClass:"budget_exceeded", message:"command record exceeds byte limit"};
      partial += decoder.decode(piece, {stream:true});
      if (i !== chunk.length) {
        partial += decoder.decode();
        if (partial.trim()) yield partial;
        partial = ""; bytes = 0;
      }
      start = i + 1;
    }
  }
  partial += decoder.decode();
  if (bytes !== 0) throw {protocolClass:"malformed_result", message:"incomplete command at EOF"};
}
try {
  for await (const line of records(D.stdin.readable)) {
    let command;
    try { command = JSON.parse(line); }
    catch (_) { throw {protocolClass:"malformed_result", message:"invalid command"}; }
    if (command.type === "execute") {
      metadata = command.tools || []; stored = command.stored || {}; globalThis.ALL_TOOLS = Object.freeze(metadata);
      try {
        const F = Object.getPrototypeOf(async function*(){}).constructor;
        const program = new F("codex", "'use strict';\n" + command.code);
        iterator = program(codex); advance(undefined);
      } catch (error) {
        // Compilation has not executed any user effects. Module-only syntax
        // (imports/exports) runs as a data module under the same denied permissions.
        if (error instanceof SyntaxError) {
          import("data:application/javascript," + encodeURIComponent(command.code))
            .then(() => out({type:"complete"}), reportError);
        } else reportError(error);
      }
    } else if (command.type === "resume" && iterator) advance(command.value);
    else if (command.type === "configure") { metadata = command.tools; stored = command.stored; globalThis.ALL_TOOLS = Object.freeze(metadata); }
    else if (command.type === "tool_result") {
      const item = pending.get(command.id); if (!item) continue; pending.delete(command.id);
      command.ok ? item.resolve(command.value) : item.reject(new Error(command.error && command.error.message || "nested tool failed"));
    } else throw {protocolClass:"malformed_result", message:"invalid command type"};
  }
  if (pending.size) throw {protocolClass:"malformed_result", message:"EOF with pending tool calls"};
} catch (error) {
  out({type:"error", error:{class:error.protocolClass || "malformed_result", message:String(error.message || error)}});
  // Exit closes the port and settles host waiters; no pending promise is left alive.
  D.exit(1);
}
