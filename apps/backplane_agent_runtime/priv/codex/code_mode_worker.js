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
let iterator = null, nextId = 0, waiting = false;
const fail = message => { throw new Error(message); };
const call = (name, value, rawInput) => {
  if (typeof name !== "string" || name.length === 0) return Promise.reject(new Error("tool name is required"));
  if (pending.size > 0) return Promise.reject(new Error("concurrent nested calls are rejected"));
  const id = String(++nextId);
  out({type:"tool_call", id, name, arguments: rawInput === undefined ? value : undefined, rawInput});
  return new Promise((resolve, reject) => pending.set(id, {resolve, reject}));
};
const codex = Object.freeze({tool: (name, args) => call(name, args), custom: (name, raw) => call(name, undefined, raw)});
globalThis.console = Object.freeze({log:()=>{}, info:()=>{}, warn:()=>{}, error:()=>{}, debug:()=>{}});
globalThis.fetch = () => Promise.reject(new Error("network access is disabled"));
try { Object.defineProperty(globalThis, "Deno", {value: undefined, configurable: false}); } catch (_) {}
const advance = async value => {
  try {
    const result = await iterator.next(value);
    if (result.done) out({type:"complete", value: result.value});
    else out({type:"yield", value: result.value});
  } catch (error) { out({type:"error", error:{class:"execution_failure", message:String(error && error.message || error)}}); }
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
      try { const F = Object.getPrototypeOf(async function*(){}).constructor; iterator = new F("codex", command.code)(codex); advance(undefined); }
      catch (error) { out({type:"error", error:{class:"execution_failure", message:String(error && error.message || error)}}); }
    } else if (command.type === "resume" && iterator) advance(command.value);
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
