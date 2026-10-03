import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const messages = ['', 'invalid syntax', 'unsupported feature', 'integer out of range', 'unknown export', 'invalid buffer', 'resource limit', 'invalid operand stack', 'divide by zero', 'integer overflow', 'invalid or duplicate reference', 'argument mismatch', 'exhausted fuel', 'executed unreachable', 'memory out of bounds', 'invalid memory limits', 'immutable global', 'interpreter error', 'export kind mismatch', 'invalid alignment', 'host import failed', 'invalid resume', 'invocation already suspended', 'host value type mismatch', 'undefined element', 'indirect call type mismatch', 'invalid table limits', 'element out of bounds', 'invalid conversion to integer', 'instance not initialized'];

// Typed forwarding bindings retain the provider's signature and load generation.
/** @type {WeakMap<Function, {params: number[], results: number, valid: () => boolean}>} */
const functionTypes = new WeakMap();
const resourceTypes = new WeakMap();
let invocationDepth = 0;
const maxInvocationDepth = 128;

/** Load the native interpreter. Guest source is never handed to WebAssembly. */
export async function createInterpreter(binary = new URL('./build/wiw-opt.wasm', import.meta.url)) {
  const { instance } = await WebAssembly.instantiate(await readFile(binary));
  const e = /** @type {{memory: WebAssembly.Memory, load: (p: number, n: number) => number, initialize: () => number, invoke: (p: number, n: number, args: number, count: number) => number, error_code: () => number, error_offset: () => number, host_base: () => number, result_count: () => number, set_fuel: (fuel: number) => void, guest_memory_base: () => number, guest_memory_pages: () => number, guest_memory_present: () => number, get_global: (p: number, n: number) => number, set_global: (p: number, n: number, value: number) => number, import_count: () => number, import_info: (index: number) => number, function_params: (index: number) => number, function_results: (index: number) => number, export_function: (p: number, n: number) => number, pending_import: () => number, pending_args: () => number, resume: (value: number, failed: number) => number, grow_guest_memory: (delta: number) => number, invoke64: (p: number, n: number, args: number, count: number) => bigint, resume64: (value: bigint, failed: number) => bigint, result_type: () => number, function_param_type: (index: number, slot: number) => number, function_result_type: (index: number) => number, global_type: (p: number, n: number) => number, get_global64: (p: number, n: number) => bigint, set_global64: (p: number, n: number, value: bigint) => number}} */ (instance.exports);
  let loaded = false;
  let invoking = false;
  let generation = 0;
  /** @type {{module: string, name: string, params: number[], results: number, callback: Function}[]} */
  let bindings = [];
  let resources = [];
  let exportedResources = new Map();
  let tableFunctions = new Map();
  let foreignFunctions = new Map();
  const owner = {};

  function ensure(/** @type {number} */ required) {
    if (required > e.memory.buffer.byteLength) e.memory.grow(Math.ceil((required - e.memory.buffer.byteLength) / 65536));
  }
  function write(/** @type {string} */ text, /** @type {number} */ at) {
    const bytes = text instanceof Uint8Array ? text : new TextEncoder().encode(text);
    const required = at + bytes.length;
    ensure(required);
    new Uint8Array(e.memory.buffer, at, bytes.length).set(bytes);
    return bytes.length;
  }
  function check(/** @type {number} */ code) {
    if (code) throw new Error(`${messages[code] ?? 'interpreter error'} at byte ${Math.max(0, e.error_offset() - 4096)}`);
  }
  function requireLoaded() {
    if (!loaded) throw new Error('no loaded module');
  }
  function i32(/** @type {number} */ value) {
    if (!Number.isInteger(value) || value < -2147483648 || value > 4294967295) {
      throw new Error('value must be an i32 integer');
    }
  }
  function memoryRange(/** @type {number} */ offset, /** @type {number} */ length) {
    requireLoaded();
    if (!e.guest_memory_present()) throw new Error('no guest memory');
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 ||
        offset + length > e.guest_memory_pages() * 65536) throw new Error('memory out of bounds');
    return e.guest_memory_base() + offset;
  }
  function requireIdle() {
    if (invoking) throw new Error('interpreter is already invoking');
  }
  function u32(/** @type {number} */ value) {
    if (!Number.isInteger(value) || value < 0 || value > 4294967295) {
      throw new Error('value must be an unsigned i32 integer');
    }
  }
  function readText(/** @type {number} */ p, /** @type {number} */ n) {
    return new TextDecoder('utf-8', {ignoreBOM: true}).decode(new Uint8Array(e.memory.buffer, p, n));
  }
  const scalarNames = [null, 'i32', 'i64', 'f32', 'f64'];
  function decodedValue(/** @type {bigint} */ bits, /** @type {number} */ type) {
    if (!type) return undefined;
    if (type === 1) return Number(BigInt.asIntN(32, bits));
    if (type === 2) return BigInt.asIntN(64, bits);
    const view = new DataView(new ArrayBuffer(8));
    view.setBigInt64(0, bits, true);
    return type === 3 ? view.getFloat32(0, true) : view.getFloat64(0, true);
  }
  function typedValue(/** @type {number | bigint} */ value, /** @type {number} */ type) {
    if (type === 1) { i32(/** @type {number} */ (value)); return BigInt(value); }
    if (type >= 3) {
      if (typeof value !== 'number') throw new Error(`value must be an ${scalarNames[type]} Number`);
      const view = new DataView(new ArrayBuffer(8));
      if (type === 3) view.setFloat32(0, value, true);
      else view.setFloat64(0, value, true);
      return view.getBigInt64(0, true);
    }
    if (typeof value !== 'bigint' || value < -(1n << 63n) || value > (1n << 64n) - 1n) {
      throw new Error('value must be an i64 BigInt integer');
    }
    return value;
  }
  function functionSignature(/** @type {string} */ name) {
    requireLoaded();
    const at = e.host_base();
    const n = write(name, at);
    const index = e.export_function(at, n);
    check(e.error_code());
    return {
      index,
      params: Array.from({ length: e.function_params(index) }, (_, slot) => e.function_param_type(index, slot)),
      results: e.function_result_type(index)
    };
  }
  // Shared state is synchronized at each synchronous guest/host boundary.
  function synchronizeIn() {
    for (const binding of resources) {
      const state = binding.state;
      if (!state.valid()) throw new Error('stale resource binding');
      if (state.kind === 1) {
        const delta = state.pages - e.guest_memory_pages();
        if (delta > 0 && e.grow_guest_memory(delta) < 0) throw new Error('shared memory growth exceeds capacity');
        new Uint8Array(e.memory.buffer, e.guest_memory_base(), state.bytes.length).set(state.bytes);
      } else if (state.kind === 2) {
        new DataView(e.memory.buffer).setBigInt64(e.global_info(binding.index) + 24, state.bits, true);
      } else {
        state.entries.forEach((entry, index) => {
          const target = entry ? tableFunctionIndex(entry) : -1;
          new DataView(e.memory.buffer).setInt32(e.table_base() + index * 4, target, true);
        });
      }
    }
  }
  function synchronizeOut() {
    for (const binding of resources) {
      const state = binding.state;
      if (state.kind === 1) {
        state.pages = e.guest_memory_pages();
        state.bytes = new Uint8Array(e.memory.buffer, e.guest_memory_base(), state.pages * 65536).slice();
      } else if (state.kind === 2) state.bits = new DataView(e.memory.buffer).getBigInt64(e.global_info(binding.index) + 24, true);
      else state.entries = Array.from({length: e.table_size()}, (_, index) => {
        const target = new DataView(e.memory.buffer).getInt32(e.table_base() + index * 4, true);
        return target < 0 ? null : functionReference(target);
      });
    }
  }
  function signatureAt(index) {
    return {params: Array.from({length: e.function_params(index)}, (_, slot) => e.function_param_type(index, slot)), results: e.function_result_type(index)};
  }
  function functionReference(index) {
    if (tableFunctions.has(index)) return tableFunctions.get(index);
    const descriptor = e.function_info(index), view = new DataView(e.memory.buffer);
    if (view.getInt32(descriptor + 8, true) === -1) {
      const binding = bindings[view.getInt32(descriptor + 12, true)];
      const forwarding = binding && functionTypes.get(binding.callback);
      if (forwarding?.reference) {
        const reference = forwarding.reference(); tableFunctions.set(index, reference); return reference;
      }
    }
    const signature = signatureAt(index), currentGeneration = generation;
    const valid = () => e.segments_ready() && generation === currentGeneration;
    const callback = (...args) => {
      requireIdle();
      if (!valid()) throw new Error('stale forwarded function');
      if (invocationDepth >= maxInvocationDepth) throw new Error('forwarding depth limit');
      if (args.length !== signature.params.length) throw new Error('argument mismatch');
      return invokeValues('', args.map((value, slot) => typedValue(value, signature.params[slot])), false, index);
    };
    const raw = args => {
      requireIdle();
      if (!valid()) throw new Error('stale forwarded function');
      if (invocationDepth >= maxInvocationDepth) throw new Error('forwarding depth limit');
      return invokeValues('', args.map(arg => BigInt.asIntN(64, arg.bits)), true, index);
    };
    functionTypes.set(callback, {...signature, valid, raw});
    const reference = {owner, index, callback, signature};
    tableFunctions.set(index, reference);
    return reference;
  }
  function tableFunctionIndex(reference) {
    if (reference.owner === owner) return reference.index;
    if (foreignFunctions.has(reference)) return foreignFunctions.get(reference);
    const {params, results} = reference.signature;
    const at = e.host_base(); ensure(at + params.length);
    new Uint8Array(e.memory.buffer, at, params.length).set(params);
    const slot = bindings.length;
    const index = e.foreign_function(params.length, results, at, slot);
    check(e.error_code());
    bindings.push({module: '<table>', name: String(reference.index), params, results, callback: reference.callback});
    foreignFunctions.set(reference, index); tableFunctions.set(index, reference);
    return index;
  }
  function exportResource(index, kind) {
    const key = `${kind}:${index}`;
    if (exportedResources.has(key)) return exportedResources.get(key);
    const imported = resources.find(binding => binding.index === index && binding.state.kind === kind);
    let state = imported?.state;
    if (!state) {
      const currentGeneration = generation;
      state = {kind, valid: () => loaded && generation === currentGeneration};
      if (kind === 1) Object.assign(state, {pages: e.guest_memory_pages(), maximum: e.memory_max(), bytes: new Uint8Array(e.memory.buffer, e.guest_memory_base(), e.guest_memory_pages() * 65536).slice()});
      else if (kind === 2) {
        const view = new DataView(e.memory.buffer), at = e.global_info(index);
        Object.assign(state, {type: view.getInt32(at + 12, true), mutable: view.getInt32(at + 8, true), bits: view.getBigInt64(at + 24, true)});
      } else Object.assign(state, {maximum: e.table_max(), entries: Array.from({length: e.table_size()}, (_, slot) => {
        const target = new DataView(e.memory.buffer).getInt32(e.table_base() + slot * 4, true);
        return target < 0 ? null : functionReference(target);
      })});
      resources.push({index, state});
    }
    const handle = Object.freeze({kind: ['function', 'memory', 'global', 'table'][kind]});
    resourceTypes.set(handle, state); exportedResources.set(key, handle);
    return handle;
  }
  function drive(/** @type {bigint} */ value, raw = false) {
    while (e.pending_import() >= 0) {
      const binding = bindings[e.pending_import()];
      let result = 0n;
      /** @type {unknown} */
      let failure;
      let failed = false;
      try {
        const view = new DataView(e.memory.buffer);
        const at = e.pending_args();
        const args = binding.params.map((type, index) => decodedValue(view.getBigInt64(at + index * 8, true), type));
        synchronizeOut();
        const forwarding = functionTypes.get(binding.callback);
        const returned = forwarding?.raw ? forwarding.raw(binding.params.map((type, index) => ({type: scalarNames[type], bits: BigInt.asUintN(type === 1 || type === 3 ? 32 : 64, view.getBigInt64(at + index * 8, true))}))) : binding.callback(...args);
        synchronizeIn();
        if (returned && typeof returned.then === 'function') {
          // Consume rejected promises while rejecting asynchronous callbacks for this synchronous ABI.
          Promise.resolve(returned).catch(() => {});
          throw new Error('import callbacks must be synchronous');
        }
        if (binding.results) result = forwarding?.raw ? BigInt.asIntN(64, returned.bits) : typedValue(returned, binding.results);
      } catch (error) { failure = error; failed = true; }
      value = e.resume64(result, failed ? 1 : 0);
      if (failed) {
        const error = new Error(`host import ${binding.module}.${binding.name} failed at byte ${Math.max(0, e.error_offset() - 4096)}`);
        Object.defineProperty(error, 'cause', { value: failure });
        throw error;
      }
      check(e.error_code());
    }
    check(e.error_code());
    return raw ? {type: scalarNames[e.result_type()], bits: BigInt.asUintN(e.result_type() === 1 || e.result_type() === 3 ? 32 : 64, value)} : decodedValue(value, e.result_type());
  }
  // Run either public scalar values or exact raw slots through the same protected invocation.
  function invokeValues(name, values, raw = false, index = undefined) {
      synchronizeIn();
      const at = e.host_base();
      const n = write(name, at);
      const argumentsAt = Math.ceil((at + n) / 8) * 8;
      ensure(argumentsAt + values.length * 8);
      const view = new DataView(e.memory.buffer);
      values.forEach((value, index) => view.setBigInt64(argumentsAt + index * 8, value, true));
      invoking = true;
      invocationDepth++;
      try {
        return drive(index === undefined ? e.invoke64(at, n, argumentsAt, values.length) : e.invoke_index64(index, argumentsAt, values.length), raw);
      } finally {
        // An interrupted host operation must not strand protected execution state.
        if (e.pending_import() >= 0) e.resume64(0n, 1);
        synchronizeOut();
        invocationDepth--;
        invoking = false;
      }
  }
  const api = {
    load(/** @type {string} */ source, /** @type {Record<string, Record<string, Function>>} */ imports = {}, binarySource = false) {
      requireIdle();
      loaded = false;
      generation++;
      bindings = []; resources = []; exportedResources = new Map();
      tableFunctions = new Map(); foreignFunctions = new Map();
      const sourceLength = write(source, 4096);
      check(binarySource ? e.load_binary(4096, sourceLength) : e.load(4096, sourceLength));
      const resolved = [], resourceBindings = [];
      let pages = e.memory_min(), maximum = e.memory_max(), entries = e.table_size(), tableMaximum = e.table_max();
      for (let index = 0; index < e.import_count(); index++) {
        const view = new DataView(e.memory.buffer);
        const at = e.import_info(index);
        const target = view.getInt32(at, true);
        const module = readText(view.getUint32(at + 4, true), view.getUint32(at + 8, true));
        const name = readText(view.getUint32(at + 12, true), view.getUint32(at + 16, true));
        const kind = view.getInt32(at + 24, true);
        const namespace = imports && Object.hasOwn(imports, module) ? imports[module] : undefined;
        const callback = namespace && Object.hasOwn(namespace, name) ? namespace[name] : undefined;
        if (kind) {
          const state = callback && resourceTypes.get(callback);
          if (!state) throw new Error(`missing resource import ${module}.${name}`);
          if (!state.valid() || state.kind !== kind) throw new Error(`import signature mismatch or stale binding ${module}.${name}`);
          if (kind === 1 || kind === 3) {
            const actual = kind === 1 ? state.pages : state.entries.length;
            const minimum = kind === 1 ? pages : entries, requiredMaximum = kind === 1 ? maximum : tableMaximum;
            if (actual < minimum || (requiredMaximum !== -1 && (state.maximum === -1 || state.maximum > requiredMaximum))) throw new Error(`import signature mismatch ${module}.${name}`);
            if (kind === 1) {pages = actual; maximum = state.maximum;}
            else {entries = actual; tableMaximum = state.maximum;}
          } else {
            const globalAt = e.global_info(target);
            if (state.type !== view.getInt32(globalAt + 12, true) || state.mutable !== view.getInt32(globalAt + 8, true)) throw new Error(`import signature mismatch ${module}.${name}`);
          }
          resourceBindings.push({index: target, state});
          resolved.push(null); continue;
        }
        const params = Array.from({ length: e.function_params(target) }, (_, slot) => e.function_param_type(target, slot));
        const results = e.function_result_type(target);
        if (typeof callback !== 'function') throw new Error(`missing function import ${module}.${name}`);
        const signature = functionTypes.get(callback);
        if (signature && (!signature.valid() || signature.params.join(',') !== params.join(',') || signature.results !== results)) {
          throw new Error(`import signature mismatch or stale binding ${module}.${name}`);
        }
        resolved.push({ module, name, params, results, callback });
      }
      bindings = resolved; resources = resourceBindings;
      check(e.prepare_resource_imports(pages, maximum, entries, tableMaximum));
      synchronizeIn();
      if (invocationDepth >= maxInvocationDepth) throw new Error('forwarding depth limit');
      // Start callbacks may inspect initialized resources while invocation/reload remain guarded.
      loaded = true;
      invoking = true;
      invocationDepth++;
      try {
        check(e.initialize());
        drive(0n);
        synchronizeOut();
      } catch (error) {
        if (e.segments_ready()) synchronizeOut();
        loaded = false;
        throw error;
      } finally {
        if (e.pending_import() >= 0) e.resume64(0n, 1);
        invocationDepth--;
        invoking = false;
      }
    },
    loadBinary(bytes, imports = {}) {
      if (!(bytes instanceof Uint8Array)) throw new Error('binary source must be a Uint8Array');
      return api.load(bytes, imports, true);
    },
    invoke(/** @type {string} */ name, /** @type {(number | bigint)[]} */ ...args) {
      requireIdle();
      requireLoaded();
      if (invocationDepth >= maxInvocationDepth) throw new Error('forwarding depth limit');
      if (args.length > 64) throw new Error('too many arguments (maximum 64)');
      const signature = functionSignature(name);
      if (args.length !== signature.params.length) throw new Error('argument mismatch');
      const values = args.map((arg, index) => {
        try { return typedValue(arg, signature.params[index]); }
        catch (error) {
          throw new Error(signature.params[index] === 2 ? 'arguments must be i64 BigInt integers' : signature.params[index] === 1 ? 'arguments must be i32 integers' : `arguments must be ${scalarNames[signature.params[index]]} Numbers`);
        }
      });
      return invokeValues(name, values);
    },
    // Raw scalar slots preserve signaling NaNs and payloads for conformance assertions.
    invokeRaw(name, ...args) {
      requireIdle();
      requireLoaded();
      if (invocationDepth >= maxInvocationDepth) throw new Error('forwarding depth limit');
      const signature = functionSignature(name);
      if (args.length !== signature.params.length) throw new Error('argument mismatch');
      const values = args.map((arg, index) => {
        if (arg.type !== scalarNames[signature.params[index]] || typeof arg.bits !== 'bigint') throw new Error('raw argument type mismatch');
        return BigInt.asIntN(64, arg.bits);
      });
      return invokeValues(name, values, true);
    },
    signature(/** @type {string} */ name) {
      const signature = functionSignature(name);
      return { params: signature.params.map(type => scalarNames[type]), result: scalarNames[signature.results] };
    },
    exportFunction(/** @type {string} */ name) {
      requireLoaded();
      const signature = functionSignature(name);
      const currentGeneration = generation;
      const callback = (/** @type {(number | bigint)[]} */ ...args) => {
        if (!loaded || generation !== currentGeneration) throw new Error('stale forwarded function');
        return api.invoke(name, ...args);
      };
      functionTypes.set(callback, {
        params: signature.params, results: signature.results,
        valid: () => loaded && generation === currentGeneration,
        raw: args => {
          if (!loaded || generation !== currentGeneration) throw new Error('stale forwarded function');
          return api.invokeRaw(name, ...args);
        },
        reference: () => {
          if (!loaded || generation !== currentGeneration) throw new Error('stale forwarded function');
          return functionReference(signature.index);
        }
      });
      return callback;
    },
    exportNamespace() {
      requireLoaded(); synchronizeIn();
      const namespace = Object.create(null);
      for (let index = 0; index < e.exports_count(); index++) {
        const view = new DataView(e.memory.buffer), at = e.export_info(index);
        const name = readText(view.getUint32(at, true), view.getUint32(at + 4, true));
        const target = view.getInt32(at + 8, true), kind = view.getInt32(at + 20, true);
        namespace[name] = kind ? exportResource(target, kind) : api.exportFunction(name);
      }
      return namespace;
    },
    getGlobal(/** @type {string} */ name) {
      synchronizeIn();
      requireLoaded();
      const at = e.host_base();
      const n = write(name, at);
      const type = e.global_type(at, n);
      check(e.error_code());
      const value = e.get_global64(at, n);
      check(e.error_code());
      return decodedValue(value, type);
    },
    setGlobal(/** @type {string} */ name, /** @type {number | bigint} */ value) {
      synchronizeIn();
      requireLoaded();
      const at = e.host_base();
      const n = write(name, at);
      const type = e.global_type(at, n);
      check(e.error_code());
      check(e.set_global64(at, n, typedValue(value, type)));
      synchronizeOut();
    },
    readMemory(/** @type {number} */ offset, /** @type {number} */ length) {
      synchronizeIn();
      const at = memoryRange(offset, length);
      return new Uint8Array(e.memory.buffer, at, length).slice();
    },
    writeMemory(/** @type {number} */ offset, /** @type {Uint8Array} */ bytes) {
      synchronizeIn();
      if (!(bytes instanceof Uint8Array)) throw new Error('memory bytes must be a Uint8Array');
      const at = memoryRange(offset, bytes.length);
      new Uint8Array(e.memory.buffer, at, bytes.length).set(bytes);
      synchronizeOut();
    },
    growMemory(/** @type {number} */ pages) {
      synchronizeIn();
      requireLoaded();
      if (!e.guest_memory_present()) throw new Error('no guest memory');
      u32(pages);
      const result = e.grow_guest_memory(pages);
      synchronizeOut();
      return result;
    },
    setFuel(/** @type {number} */ limit) {
      if (!Number.isInteger(limit) || limit < 0 || limit > 4294967295) {
        throw new Error('fuel must be an unsigned i32 integer');
      }
      e.set_fuel(limit);
    }

  };
  return api;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const file = process.argv[2];
    const name = process.argv[3];
    if (!file || name === undefined) throw new Error('Usage: node wiw.mjs <file.wat> <export> [scalar arguments...]');
    const interpreter = await createInterpreter();
    interpreter.load(await readFile(file, 'utf8'));
    const signature = interpreter.signature(name);
    const args = process.argv.slice(4).map((arg, index) => signature.params[index] === 'i64' ? BigInt(arg.endsWith('n') ? arg.slice(0, -1) : arg) : arg === 'inf' || arg === '+inf' ? Infinity : arg === '-inf' ? -Infinity : Number(arg));
    const value = interpreter.invoke(name, ...args);
    if (value !== undefined) console.log(String(value));
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  }
}
