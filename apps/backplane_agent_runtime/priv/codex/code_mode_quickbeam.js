// Trusted bootstrap for one retained cell. No ambient QuickBEAM bridge escapes
// this closure; every public event crosses the bridge as its original JSON.
((entrypointToken) => {
  'use strict';
  const beam = globalThis.Beam;
  const hostCall = beam.call.bind(beam);
  const hostCallSync = beam.callSync.bind(beam);
  if (!delete globalThis.Beam) throw new Error('cannot remove native bridge');
  const encode = JSON.stringify.bind(JSON);
  const decode = JSON.parse.bind(JSON);
  const Generator = Object.getPrototypeOf(async function*(){}).constructor;
  // load_module exposes errors as messages, so exit needs an exact signal that
  // survives that public boundary without depending on Elixir's inspect format.
  const exitMarker = '__backplane_code_mode_exit__:v1';
  let iterator = null, nextId = 0, sequence = 0, revision = 0;
  let stored = {}, metadata = [], phase = 'new', advancing = false;
  let nextTimer = 0, controlStarted = false, bridgeError = null;
  const timers = new Map();

  const publish = event => {
    // Serialize before assigning a sequence: rejected helper arguments must not
    // leave a gap that can strand the host's ordered event queue.
    const json = encode(event);
    const seq = ++sequence;
    return hostCall('host.event', seq, json);
  };
  const background = promise => {
    Promise.resolve(promise).catch(error => { bridgeError = error; });
  };
  const out = event => { background(publish(event)); };
  const stringify = value => typeof value === 'string' ? value : encode(value) ?? String(value);
  const emit = item => out({type:'output', item});
  const call = (name, value, rawInput) => {
    if (typeof name !== 'string' || name.length === 0) return Promise.reject(new Error('tool name is required'));
    const id = String(++nextId);
    return publish({type:'tool_call', id, name, arguments: rawInput === undefined ? value : undefined, rawInput})
      .then(json => {
        const result = decode(json);
        if (!result || result.type !== 'tool_result' || result.id !== id || typeof result.ok !== 'boolean')
          throw new Error('invalid tool result');
        if (result.ok) return result.value;
        throw new Error(result.error && result.error.message || 'nested tool failed');
      });
  };
  const media = (type, value, detail) => {
    let item;
    if (value && value.type === type && typeof value.data === 'string' && typeof value.mimeType === 'string') item = {...value};
    else {
      const url = typeof value === 'string' ? value : value && value[type + '_url'];
      const match = typeof url === 'string' && /^data:([^;,]+);base64,([a-zA-Z0-9+/=]*)$/.exec(url);
      if (!match) throw new Error(type + ' requires a base64 data URL or content block');
      item = {type, mimeType:match[1], data:match[2]};
    }
    const selected = detail ?? value?.detail ?? value?._meta?.['codex/imageDetail'];
    if (type === 'image' && selected != null) item.detail = selected;
    emit(item);
  };
  const tools = new Proxy(Object.create(null), {get: (_, name) => {
    const matches = metadata.filter(item => item.name.replaceAll('::', '__') === name || item.name === name || item.tool_name === name);
    if (!matches.length) return undefined;
    if (matches.length > 1) return () => Promise.reject(new Error('normalized tool name is ambiguous; use its canonical name'));
    const tool = matches[0];
    return value => tool.input_kind === 'custom' ? call(tool.tool_name || tool.name, undefined, value) : call(tool.tool_name || tool.name, value);
  }});
  const codex = Object.freeze({tool: (name, args) => call(name, args), custom: (name, raw) => call(name, undefined, raw)});
  const configure = command => {
    metadata = command.tools || [];
    stored = command.stored || {};
    globalThis.ALL_TOOLS = Object.freeze(metadata);
  };
  const clearTimer = id => {
    const timer = timers.get(id);
    if (!timer) return;
    timer.canceled = true;
    timers.delete(id);
    // This local broker ACK must be synchronous: an async cancellation can lose
    // to an already queued Promise continuation. The broker also closes its wait.
    hostCallSync('host.clear_timer', id);
  };
  const clearTimers = () => {
    for (const id of timers.keys()) clearTimer(id);
  };
  const terminal = event => {
    if (phase === 'done') return Promise.resolve('done');
    // A non-JSON completion value is still an execution error. Do not close the
    // cell until serialization succeeds, so reportError can publish that error.
    const published = publish(event);
    phase = 'done';
    clearTimers();
    return published.then(() => 'done');
  };
  const reportError = error => error && error.codexExit
    ? terminal({type:'complete'})
    : terminal({type:'error', error:{class:'execution_failure', message:String(error && error.message || error)}});
  const controlPump = async () => {
    // Keep exactly one control request alive, including while the generator is
    // yielded or a module awaits a tool. The next poll acknowledges application.
    for (;;) {
      const json = await hostCall('host.control', encode({revision}));
      const command = decode(json);
      if (!command || !Number.isSafeInteger(command.revision) || command.revision < revision ||
          !Array.isArray(command.tools) || !command.stored || typeof command.stored !== 'object' || Array.isArray(command.stored))
        throw new Error('invalid control configuration');
      configure(command);
      revision = command.revision;
    }
  };
  const startControl = () => {
    if (controlStarted) return;
    controlStarted = true;
    controlPump().catch(error => { background(reportError(error)); });
  };
  const advance = async value => {
    if (advancing) throw new Error('cell is already advancing');
    advancing = true;
    phase = 'running';
    try {
      const result = await iterator.next(value);
      if (bridgeError) throw bridgeError;
      if (result.done) return await terminal({type:'complete', value:result.value});
      phase = 'yielded';
      await publish({type:'yield', value:result.value});
      return 'yielded';
    } catch (error) { return await reportError(error); }
    finally { advancing = false; }
  };
  const execute = command => {
    if (phase !== 'new') throw new Error('cell has already executed');
    configure(command);
    globalThis.input = command.input;
    let program;
    try { program = new Generator('codex', "'use strict';\n" + command.code); }
    catch (error) {
      // Only compilation can choose module mode. An exception from running user
      // code must never replay effects through a second execution path.
      if (error instanceof SyntaxError) {
        phase = 'module';
        startControl();
        return 'module';
      }
      return reportError(error);
    }
    iterator = program(codex);
    startControl();
    return advance(undefined);
  };

  // Strict runtimes intentionally omit browser APIs. Provide only the UTF-8
  // encoder used by the existing Code Mode contract, without installing I/O.
  class TextEncoder {
    get encoding() { return 'utf-8'; }
    encode(value = '') {
      const bytes = [];
      for (const char of String(value)) {
        let point = char.codePointAt(0);
        if (point >= 0xd800 && point <= 0xdfff) point = 0xfffd;
        if (point < 0x80) bytes.push(point);
        else if (point < 0x800) bytes.push(0xc0 | point >> 6, 0x80 | point & 63);
        else if (point < 0x10000) bytes.push(0xe0 | point >> 12, 0x80 | point >> 6 & 63, 0x80 | point & 63);
        else bytes.push(0xf0 | point >> 18, 0x80 | point >> 12 & 63, 0x80 | point >> 6 & 63, 0x80 | point & 63);
      }
      return new Uint8Array(bytes);
    }
  }
  Object.assign(globalThis, {
    tools, codex, TextEncoder,
    text: value => emit({type:'text', text:stringify(value)}),
    image: (value, detail) => media('image', value, detail),
    audio: value => media('audio', value),
    generatedImage: value => { media('image', value); if (value.output_hint) emit({type:'text', text:value.output_hint}); },
    notify: value => out({type:'notify', value:stringify(value)}),
    store: (key, value) => {
      if (typeof key !== 'string') throw new Error('store key must be a string');
      const snapshot = decode(encode(value));
      Object.defineProperty(stored, key, {value:snapshot, writable:true, enumerable:true, configurable:true});
      out({type:'store', key, value:snapshot});
    },
    load: key => Object.hasOwn(stored, key) ? stored[key] : undefined,
    exit: () => {
      const error = new Error(exitMarker);
      error.codexExit = true;
      throw error;
    },
    yield_control: () => { out({type:'control_yield'}); },
    setTimeout: (callback, delay = 0, ...args) => {
      if (typeof callback !== 'function') throw new TypeError('timer callback must be a function');
      if (phase === 'done') return 0;
      const milliseconds = Math.min(2147483647, Math.max(0, Math.trunc(Number(delay) || 0)));
      const id = ++nextTimer;
      const timer = {canceled:false};
      hostCallSync('host.start_timer', id, milliseconds);
      timers.set(id, timer);
      Promise.resolve(hostCall('host.timer', id)).then(fired => {
        timers.delete(id);
        if (timer.canceled || phase === 'done') return;
        if (typeof fired !== 'boolean') throw new Error('invalid timer result');
        if (fired) callback(...args);
      }).catch(error => { background(reportError(error)); });
      return id;
    },
    clearTimeout: clearTimer,
    console: Object.freeze({log:()=>{}, info:()=>{}, warn:()=>{}, error:()=>{}, debug:()=>{}}),
    fetch: () => Promise.reject(new Error('network access is disabled'))
  });
  Object.defineProperty(globalThis, 'Deno', {value:undefined, configurable:false});
  // QuickBEAM calls these through evaluated source. The token keeps user
  // callbacks from advancing a yielded cell or finishing a module themselves.
  const entrypoint = callback => (token, json) => {
    if (token !== entrypointToken) throw new Error('invalid Code Mode entrypoint token');
    return callback(decode(json));
  };
  Object.defineProperties(globalThis, {
    __backplaneExecute: {value:entrypoint(execute)},
    __backplaneResume: {value:entrypoint(value => {
      if (phase !== 'yielded' || !iterator) throw new Error('cell is not yielded');
      return advance(value);
    })},
    __backplaneFinishModule: {value:entrypoint(error => {
      if (phase !== 'module') throw new Error('cell is not running a module');
      return error == null || error === exitMarker ? terminal({type:'complete'}) : reportError(error);
    })}
  });
})
