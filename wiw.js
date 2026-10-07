import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const messages = ['', 'invalid syntax', 'unsupported feature', 'integer out of range', 'unknown export', 'invalid buffer', 'resource limit', 'invalid operand stack', 'divide by zero', 'integer overflow', 'invalid or duplicate reference', 'argument mismatch', 'exhausted fuel', 'executed unreachable', 'memory out of bounds', 'invalid memory limits', 'immutable global', 'interpreter error', 'export kind mismatch', 'invalid alignment', 'host import failed', 'invalid resume', 'invocation already suspended', 'host value type mismatch', 'undefined element', 'indirect call type mismatch', 'invalid table limits', 'element out of bounds', 'invalid conversion to integer', 'instance not initialized', 'table out of bounds', 'null reference', 'cast failure', 'array out of bounds', 'uncaught exception'];
let nextTagIdentity = 1;
const exceptionTypes = new WeakMap();
export class WiwException extends Error {
  constructor() {super('uncaught guest exception'); this.name = 'WiwException';}
}

// Typed forwarding bindings retain the provider's signature and load generation.
/** @type {WeakMap<Function, {params: number[], results: number | number[], valid: () => boolean}>} */
const functionTypes = new WeakMap();
const resourceTypes = new WeakMap();
let invocationDepth = 0;
const maxInvocationDepth = 128;

// Backing memory and address origins stay private to the host adapters.
const engineBackends = new WeakMap();

/** Load the native interpreter. Guest source is never handed to WebAssembly. */
export async function createBootstrapInterpreter(binary = new URL('./build/wiw-opt.wasm', import.meta.url)) {
  const { instance } = await WebAssembly.instantiate(await readFile(binary));
  return wrapInterpreter(instance.exports);
}

/** Create the default runtime: one interpreted WAT copy of wiw above the bootstrap. */
export async function createInterpreter(binary = new URL('./build/wiw-opt.wasm', import.meta.url), options = {}) {
  return createInterpretedInterpreter(binary, options);
}

/** Run a WAT copy of wiw (optimized by default) inside a bootstrap using the same host ABI. */
export async function createInterpretedInterpreter(binary = new URL('./build/wiw-opt.wasm', import.meta.url), options = {}) {
  const parent = await createBootstrapInterpreter(binary);
  const backend = engineBackends.get(parent);
  // Parent ABI calls are implementation work, not guest-to-guest forwarding.
  backend.countsForwardingDepth = false;
  parent.load(options.source ?? await readFile(new URL('./build/wiw-opt.wat', import.meta.url), 'utf8'));
  backend.exports.set_fuel64(BigInt(options.parentFuel ?? ((1n << 64n) - 1n)));
  // The parent holds child arenas as well as the child's full guest-memory capacity.
  backend.exports.enable_interpreter_backing();
  const memoryOffset = backend.memoryOffset + backend.exports.guest_memory_base();
  const exports = {memory: backend.exports.memory};
  for (const [name, value] of Object.entries(backend.exports)) {
    if (typeof value === 'function') exports[name] = (...args) => parent.invoke(name, ...args);
  }
  return wrapInterpreter(exports, {
    memoryOffset,
    ensureMemory(required) {
      const current = backend.exports.guest_memory_pages();
      const needed = Math.ceil(required / 65536);
      if (needed > current && parent.growMemory(needed - current) < 0) throw new Error('resource limit while growing interpreted backing memory');
    }
  });
}

// Numeric pointers remain relative to the engine's own memory at every depth.
function wrapInterpreter(exports, {memoryOffset = 0, ensureMemory} = {}) {
  const e = /** @type {{memory: WebAssembly.Memory, load: (p: number, n: number) => number, initialize: () => number, invoke: (p: number, n: number, args: number, count: number) => number, error_code: () => number, error_offset: () => number, host_base: () => number, result_count: () => number, set_fuel: (fuel: number) => void, guest_memory_base: () => number, guest_memory_pages: () => number, guest_memory_present: () => number, get_global: (p: number, n: number) => number, set_global: (p: number, n: number, value: number) => number, import_count: () => number, import_info: (index: number) => number, function_params: (index: number) => number, function_results: (index: number) => number, export_function: (p: number, n: number) => number, pending_import: () => number, pending_args: () => number, resume: (value: number, failed: number) => number, grow_guest_memory: (delta: number) => number, invoke64: (p: number, n: number, args: number, count: number) => bigint, resume64: (value: bigint, failed: number) => bigint, result_type: (slot: number) => number, function_param_type: (index: number, slot: number) => number, function_result_type: (index: number, slot: number) => number, global_type: (p: number, n: number) => number, argument_high_base: () => number, pending_high_args: () => number, result_high_base: () => number, result_base: () => number, global_high: (p: number, n: number) => bigint, set_global_high: (p: number, n: number, value: bigint) => number, get_global64: (p: number, n: number) => bigint, set_global64: (p: number, n: number, value: bigint) => number}} */ (exports);
  const backend = {exports: e, memoryOffset, countsForwardingDepth: true};
  let loaded = false;
  let invoking = false;
  let generation = 0;
  /** @type {{module: string, name: string, params: number[], results: number | number[], callback: Function}[]} */
  let bindings = [];
  let resources = [];
  let exportedResources = new Map(), exportedFunctions = new Map();
  let tableFunctions = new Map();
  let foreignFunctions = new Map();
  const owner = {};
  const negativeZeroKey = Symbol();
  let externalValues = [null], externalIds = new Map();

  function ensure(/** @type {number} */ required) {
    if (ensureMemory) return ensureMemory(required);
    if (required > e.memory.buffer.byteLength) e.memory.grow(Math.ceil((required - e.memory.buffer.byteLength) / 65536));
  }
  function write(/** @type {string} */ text, /** @type {number} */ at) {
    const bytes = text instanceof Uint8Array ? text : new TextEncoder().encode(text);
    const required = at + bytes.length;
    ensure(required);
    new Uint8Array(e.memory.buffer, memoryOffset + at, bytes.length).set(bytes);
    return bytes.length;
  }
  function check(/** @type {number} */ code) {
    if (code === 34) throw guestException();
    if (code) throw new Error(`${messages[code] ?? 'interpreter error'} at byte ${Math.max(0, e.error_offset() - 4096)}`);
  }
  const importedExceptions = new Map();
  function guestException() {
    const reference = e.exception_reference();
    if (importedExceptions.has(reference)) return importedExceptions.get(reference);
    const view = new DataView(e.memory.buffer, memoryOffset), at = e.exception_info(reference);
    const tag = view.getInt32(at + 8, true), identity = Number(view.getBigUint64(at + 16, true));
    const heap = view.getInt32(e.tag_info(tag) + 24, true), count = view.getInt32(at + 4, true) - 1;
    const params = Array.from({length: count}, (_, slot) => e.value_kind(e.heap_param_type(heap, slot)));
    const args = params.map((type, slot) => {
      const low = view.getBigInt64(at + 32 + slot * 16, true), high = view.getBigUint64(at + 40 + slot * 16, true);
      return rawResult(type === 7 ? BigInt.asUintN(64, low) | (high << 64n) : low, type);
    });
    const exception = new WiwException();
    exceptionTypes.set(exception, {identity, params, args});
    return exception;
  }
  function importException(exception) {
    const {identity, params, args} = exceptionTypes.get(exception);
    const at = e.host_base(); ensure(at + args.length * 8);
    const view = new DataView(e.memory.buffer, memoryOffset);
    args.forEach((arg, slot) => {
      const bits = rawSlot(arg, params[slot]);
      view.setBigInt64(at + slot * 8, BigInt.asIntN(64, bits), true);
      view.setBigInt64(e.argument_high_base() + slot * 8, BigInt.asIntN(64, bits >> 64n), true);
    });
    const reference = e.import_exception(identity, args.length, at);
    importedExceptions.set(reference, exception);
    return reference;
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
    return new TextDecoder('utf-8', {ignoreBOM: true}).decode(new Uint8Array(e.memory.buffer, memoryOffset + p, n));
  }
  const scalarNames = [null, 'i32', 'i64', 'f32', 'f64', 'funcref', 'externref', 'v128', 'anyref', 'exnref'];
  const opaqueReferences = new Map();
  const opaqueReferenceValues = new WeakMap();
  const isHostReference = type => type >= 5 && type !== 7;
  function decodedValue(/** @type {bigint} */ bits, /** @type {number} */ type) {
    if (!type) return undefined;
    if (type === 1) return Number(BigInt.asIntN(32, bits));
    if (type === 2) return BigInt.asIntN(64, bits);
    if (type === 7) return BigInt.asUintN(128, bits);
    if (type === 5) return bits === 0n ? null : functionReference(Number(bits - 1n)).callback;
    if (type === 6) return (bits & 0xc0000000n) ? decodedValue(bits, 8) : externalValues[Number(bits)];
    if (type >= 8) {
      if (bits === 0n) return null;
      if (type === 8 && (bits & 0xe0000000n) === 0x20000000n) return externalValues[Number(bits & 0x1fffffffn)];
      const key = `${type}:${bits}`;
      if (!opaqueReferences.has(key)) {
        const reference = Object.freeze({});
        opaqueReferences.set(key, reference); opaqueReferenceValues.set(reference, {bits, type});
      }
      return opaqueReferences.get(key);
    }
    const view = new DataView(new ArrayBuffer(8));
    view.setBigInt64(0, bits, true);
    return type === 3 ? view.getFloat32(0, true) : view.getFloat64(0, true);
  }
  function typedValue(/** @type {number | bigint} */ value, /** @type {number} */ type) {
    if (type === 7) {
      if (typeof value !== 'bigint' || value < -(1n << 127n) || value > (1n << 128n) - 1n) throw new Error('value must be a v128 BigInt bit pattern');
      return BigInt.asUintN(128, value);
    }
    if (type === 1) { i32(/** @type {number} */ (value)); return BigInt(value); }
    if (type === 5) {
      if (value === null) return 0n;
      const metadata = functionTypes.get(value);
      if (!metadata?.reference || !metadata.valid()) throw new Error('value must be a live wiw function reference or null');
      return BigInt(tableFunctionIndex(metadata.reference()) + 1);
    }
    if (type === 6) {
      if (value === null) return 0n;
      const opaque = opaqueReferenceValues.get(value);
      if (opaque?.type === 8) return opaque.bits;
      const key = Object.is(value, -0) ? negativeZeroKey : value;
      if (!externalIds.has(key)) {
        if (externalValues.length >= 65536) throw new Error('external reference resource limit');
        externalIds.set(key, externalValues.length); externalValues.push(value);
      }
      return BigInt(externalIds.get(key));
    }
    if (type >= 8) {
      if (value === null) return 0n;
      const reference = opaqueReferenceValues.get(value);
      if (!reference && type === 8) return typedValue(value, 6) | 0x20000000n;
      if (!reference || reference.type !== type) throw new Error('value must be a live opaque wiw reference or null');
      return reference.bits;
    }
    if (type === 3 || type === 4) {
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
  function functionSignature(/** @type {string} */ name, includeResults = true) {
    requireLoaded();
    const at = e.host_base();
    const n = write(name, at);
    const index = e.export_function(at, n);
    check(e.error_code());
    return {index, ...signatureAt(index, includeResults)};
  }
  // Reference descriptors carry opaque values; numeric descriptors retain exact bits.
  function rawResult(bits, type) {
    return isHostReference(type) ? {type: scalarNames[type], value: decodedValue(bits, type), ...(type === 8 ? {heap: bits === 0n ? null : (bits & 0x80000000n) ? 'i31' : (bits & 0x40000000n) ? (e.reference_category(e.object_type(bits)) === 22 ? 'struct' : 'array') : 'any'} : {})} :
      {type: scalarNames[type], bits: BigInt.asUintN(type === 7 ? 128 : type === 1 || type === 3 ? 32 : 64, bits)};
  }
  function rawSlot(arg, type) {
    if (arg.type !== scalarNames[type]) throw new Error('raw argument type mismatch');
    if (isHostReference(type)) {
      if (!Object.hasOwn(arg, 'value')) throw new Error('raw reference requires an opaque value');
      return typedValue(arg.value, type);
    }
    if (typeof arg.bits !== 'bigint') throw new Error('raw argument type mismatch');
    return type === 7 ? BigInt.asUintN(128, arg.bits) : BigInt.asIntN(64, arg.bits);
  }
  // Shared state is synchronized at each synchronous guest/host boundary.
  // Type graphs retain nullability and structural heap signatures across independent instances.
  function typeDescription(type, heaps = new Map()) {
    const kind = e.value_kind(type);
    if (!isHostReference(kind)) return {kind};
    const result = {kind, nonnull: Boolean(e.type_nonnull(type)), heap: e.reference_category(type)};
    const index = e.type_heap(type);
    if (index < 0) return result;
    const describeHeap = index => {
      if (heaps.has(index)) return heaps.get(index);
      const view = new DataView(e.memory.buffer, memoryOffset);
      const at = e.heap_info(index);
      const heap = {index, kind: view.getInt32(at, true), final: view.getInt32(at + 12, true), group: [], params: [], results: [], fields: []};
      heaps.set(index, heap);
      const start = view.getInt32(at + 4, true), count = view.getInt32(at + 8, true);
      heap.position = index - start;
      const parent = view.getInt32(at + 16, true);
      heap.parent = parent < 0 ? null : typeDescription(parent, heaps).heap;
      if (heap.kind === 0) {
        heap.params = Array.from({length: e.heap_params(index)}, (_, slot) => typeDescription(e.heap_param_type(index, slot), heaps));
        heap.results = Array.from({length: e.heap_results(index)}, (_, slot) => typeDescription(e.heap_result_type(index, slot), heaps));
      } else {
        const first = view.getInt32(at + 20, true), length = view.getInt32(at + 24, true);
        heap.fields = Array.from({length}, (_, slot) => {
          const field = e.field_info(first + slot);
          return {type: typeDescription(view.getInt32(field, true), heaps), mutable: view.getInt32(field + 4, true)};
        });
      }
      heap.group = Array.from({length: count}, (_, slot) => describeHeap(start + slot));
      return heap;
    };
    result.heap = describeHeap(index);
    return result;
  }
  // Recursive group references compare by their relative positions within paired groups.
  function equalHeap(actual, expected, contexts = []) {
    if (typeof actual === 'number' || typeof expected === 'number') return actual === expected;
    for (const [left, right] of contexts) {
      const a = left.indexOf(actual), b = right.indexOf(expected);
      if (a >= 0 || b >= 0) return a === b && a >= 0;
    }
    if (actual.position !== expected.position || actual.group.length !== expected.group.length) return false;
    contexts.push([actual.group, expected.group]);
    const sameType = (a, b) => a.kind === b.kind && a.nonnull === b.nonnull && (!isHostReference(a.kind) || equalHeap(a.heap, b.heap, contexts));
    const sameVector = (a, b) => a.length === b.length && a.every((type, slot) => sameType(type, b[slot]));
    const result = actual.group.every((a, slot) => {
      const b = expected.group[slot];
      return a.kind === b.kind && a.final === b.final && Boolean(a.parent) === Boolean(b.parent) &&
        (!a.parent || equalHeap(a.parent, b.parent, contexts)) && sameVector(a.params, b.params) && sameVector(a.results, b.results) &&
        a.fields.length === b.fields.length && a.fields.every((field, i) => field.mutable === b.fields[i].mutable && sameType(field.type, b.fields[i].type));
    });
    contexts.pop();
    return result;
  }
  function compatibleType(actual, expected) {
    if (!isHostReference(expected.kind)) return actual.kind === expected.kind;
    if (!isHostReference(actual.kind) || (expected.nonnull && !actual.nonnull)) return false;
    if (typeof expected.heap === 'number') {
      const category = typeof actual.heap === 'number' ? actual.heap : actual.heap.kind === 0 ? 5 : actual.heap.kind === 1 ? 22 : 24;
      if (category === expected.heap) return true;
      if (category === 26) return [16,18,20,22,24].includes(expected.heap);
      if (category === 28) return expected.heap === 5;
      if (category === 30) return expected.heap === 6;
      if (category === 34) return expected.heap === 32;
      return (expected.heap === 16 && [18,20,22,24].includes(category)) || (expected.heap === 18 && [20,22,24].includes(category));
    }
    if (typeof actual.heap === 'number') return actual.heap === (expected.heap.kind === 0 ? 28 : 26);
    for (let heap = actual.heap; heap; heap = heap.parent) if (equalHeap(heap, expected.heap)) return true;
    return false;
  }
  function synchronizeIn() {
    for (const binding of resources) {
      const state = binding.state;
      if (state.kind === 4) continue;
      if (!state.valid()) throw new Error('stale resource binding');
      if (state.kind === 1) {
        const delta = state.pages - e.memory_pages(binding.index);
        if (delta > 0 && e.grow_memory(binding.index, delta) < 0) throw new Error('shared memory growth exceeds capacity');
        new Uint8Array(e.memory.buffer, memoryOffset + e.memory_base(binding.index), state.bytes.length).set(state.bytes);
      } else if (state.kind === 2) {
        const bits = (isHostReference(state.type)) ? typedValue(state.value, state.type) : state.bits;
        const view = new DataView(e.memory.buffer, memoryOffset), at = e.global_info(binding.index);
        view.setBigInt64(at + 24, BigInt.asIntN(64, bits), true);
        view.setBigInt64(at + 72, state.type === 7 ? BigInt.asIntN(64, bits >> 64n) : 0n, true);
      } else {
        const delta = state.entries.length - e.table_size(binding.index);
        if (delta > 0 && e.grow_guest_table(binding.index, delta) < 0) throw new Error('shared table growth exceeds capacity');
        state.entries.forEach((entry, index) => {
          const target = state.type === 5 ? (entry ? tableFunctionIndex(entry) : -1) : Number(typedValue(entry, 6)) - 1;
          new DataView(e.memory.buffer, memoryOffset).setInt32(e.table_base(binding.index) + index * 4, target, true);
        });
      }
    }
  }
  function synchronizeOut() {
    for (const binding of resources) {
      const state = binding.state;
      if (state.kind === 4) continue;
      if (state.kind === 1) {
        state.pages = e.memory_pages(binding.index);
        state.bytes = new Uint8Array(e.memory.buffer, memoryOffset + e.memory_base(binding.index), state.pages * 65536).slice();
      } else if (state.kind === 2) {
        state.bits = new DataView(e.memory.buffer, memoryOffset).getBigInt64(e.global_info(binding.index) + 24, true);
        if (state.type === 7) state.bits = BigInt.asUintN(64, state.bits) | (BigInt.asUintN(64, new DataView(e.memory.buffer, memoryOffset).getBigInt64(e.global_info(binding.index) + 72, true)) << 64n);
        if ((isHostReference(state.type))) state.value = decodedValue(state.bits, state.type);
      } else state.entries = Array.from({length: e.table_size(binding.index)}, (_, index) => {
        const target = new DataView(e.memory.buffer, memoryOffset).getInt32(e.table_base(binding.index) + index * 4, true);
        return state.type === 6 ? decodedValue(BigInt(target + 1), 6) : target < 0 ? null : functionReference(target);
      });
    }
  }
  function resultSignature(index) {
    const count = e.function_results(index);
    return count <= 1 ? e.function_result_type(index, 0) : Array.from({length: count}, (_, slot) => e.function_result_type(index, slot));
  }
  // Copy a fresh bulk snapshot before later ABI calls reuse its host scratch bytes.
  function signatureAt(index, includeResults = true) {
    // Direct native calls are cheaper than filling scratch; bulk queries target interpreted forwarding.
    if (!ensureMemory) return {params: Array.from({length: e.function_params(index)}, (_, slot) => e.function_param_type(index, slot)), results: includeResults ? resultSignature(index) : undefined};
    const at = e.function_signature(index, includeResults ? 1 : 0);
    if (!at) check(e.error_code());
    const view = new DataView(e.memory.buffer, memoryOffset);
    const count = view.getUint32(at, true), results = view.getUint32(at + 4, true);
    const params = Array.from({length: count}, (_, slot) => view.getUint32(at + 8 + slot * 4, true));
    const types = includeResults ? Array.from({length: results}, (_, slot) => view.getUint32(at + 8 + (count + slot) * 4, true)) : [];
    return {params, results: includeResults ? (results > 1 ? types : types[0] ?? 0) : undefined};
  }

  function functionReference(index) {
    if (tableFunctions.has(index)) return tableFunctions.get(index);
    const descriptor = e.function_info(index), view = new DataView(e.memory.buffer, memoryOffset);
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
      if (backend.countsForwardingDepth && invocationDepth >= maxInvocationDepth) throw new Error('forwarding depth limit');
      if (args.length !== signature.params.length) throw new Error('argument mismatch');
      return invokeValues('', args.map((value, slot) => typedValue(value, signature.params[slot])), false, index);
    };
    const raw = args => {
      requireIdle();
      if (!valid()) throw new Error('stale forwarded function');
      if (backend.countsForwardingDepth && invocationDepth >= maxInvocationDepth) throw new Error('forwarding depth limit');
      return invokeValues('', args.map((arg, slot) => rawSlot(arg, signature.params[slot])), true, index);
    };
    functionTypes.set(callback, {...signature, valid, raw, reference: () => reference});
    const reference = {owner, index, callback: exportedFunctions.get(index) ?? callback, signature};
    tableFunctions.set(index, reference);
    return reference;
  }
  function tableFunctionIndex(reference) {
    if (reference.owner === owner) return reference.index;
    if (foreignFunctions.has(reference)) return foreignFunctions.get(reference);
    const {params, results} = reference.signature;
    const at = e.host_base(); ensure(at + params.length * 4);
    new Uint32Array(e.memory.buffer, memoryOffset + at, params.length).set(params);
    const slot = bindings.length;
    const index = e.foreign_function(params.length, Array.isArray(results) ? results[0] : results, at, slot);
    if (index >= 0 && Array.isArray(results)) {
      ensure(at + results.length * 4);
      new Uint32Array(e.memory.buffer, memoryOffset + at, results.length).set(results);
      check(e.foreign_results(index, at, results.length));
    }
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
      if (kind === 4) Object.assign(state, {identity: new DataView(e.memory.buffer, memoryOffset).getInt32(e.tag_info(index) + 16, true), descriptor: typeDescription(e.tag_type(index))});
      else if (kind === 1) Object.assign(state, {addressType: e.memory_width(index), pages: e.memory_pages(index), maximum: e.memory_maximum(index), bytes: new Uint8Array(e.memory.buffer, memoryOffset + e.memory_base(index), e.memory_pages(index) * 65536).slice()});
      else if (kind === 2) {
        const view = new DataView(e.memory.buffer, memoryOffset), at = e.global_info(index);
        Object.assign(state, {type: e.value_kind(view.getInt32(at + 12, true)), descriptor: typeDescription(view.getInt32(at + 12, true)), mutable: view.getInt32(at + 8, true), bits: view.getBigInt64(at + 24, true)});
        if (state.type === 7) state.bits = BigInt.asUintN(64, state.bits) | (BigInt.asUintN(64, view.getBigInt64(at + 72, true)) << 64n);
        if ((isHostReference(state.type))) state.value = decodedValue(state.bits, state.type);
      } else Object.assign(state, {addressType: e.table_address_type(index), type: e.table_type(index), descriptor: typeDescription(new DataView(e.memory.buffer, memoryOffset).getInt32(e.table_info(index) + 16, true)), maximum: e.table_max(index), entries: Array.from({length: e.table_size(index)}, (_, slot) => {
        const target = new DataView(e.memory.buffer, memoryOffset).getInt32(e.table_base(index) + slot * 4, true);
        return e.table_type(index) === 6 ? decodedValue(BigInt(target + 1), 6) : target < 0 ? null : functionReference(target);
      })});
      resources.push({index, state});
    }
    const handle = Object.freeze({kind: ['function', 'memory', 'global', 'table', 'tag'][kind]});
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
        const view = new DataView(e.memory.buffer, memoryOffset);
        const at = e.pending_args();
        const pendingHigh = e.pending_high_args();
        const rawArgs = binding.params.map((type, index) => {
          let bits = view.getBigInt64(at + index * 8, true);
          if (type === 7) bits = BigInt.asUintN(64, bits) | (BigInt.asUintN(64, view.getBigInt64(pendingHigh + index * 8, true)) << 64n);
          return rawResult(bits, type);
        });
        const args = rawArgs.map((value, index) => binding.params[index] === 5 || binding.params[index] === 6 ? value.value : decodedValue(value.bits, binding.params[index]));
        synchronizeOut();
        const forwarding = functionTypes.get(binding.callback);
        const returned = forwarding?.raw ? forwarding.raw(rawArgs) : binding.callback(...args);
        synchronizeIn();
        if (binding.results !== 6 && returned && typeof returned.then === 'function') {
          // Consume rejected promises while rejecting asynchronous callbacks for this synchronous ABI.
          Promise.resolve(returned).catch(() => {});
          throw new Error('import callbacks must be synchronous');
        }
        if (Array.isArray(binding.results)) {
          if (!Array.isArray(returned) || returned.length !== binding.results.length) throw new Error('import result count mismatch');
          const slots = returned.map((value, slot) => forwarding?.raw ? rawSlot(value, binding.results[slot]) : typedValue(value, binding.results[slot]));
          const resultAt = e.pending_args(); ensure(resultAt + slots.length * 8);
          const output = new DataView(e.memory.buffer, memoryOffset);
          slots.forEach((value, slot) => {
            output.setBigInt64(resultAt + slot * 8, BigInt.asIntN(64, value), true);
            output.setBigInt64(e.pending_high_args() + slot * 8, binding.results[slot] === 7 ? BigInt.asIntN(64, value >> 64n) : 0n, true);
          });
          result = slots[0];
        } else if (binding.results) {
          result = forwarding?.raw ? rawSlot(returned, binding.results) : typedValue(returned, binding.results);
          if (binding.results === 7) {
            new DataView(e.memory.buffer, memoryOffset).setBigInt64(e.pending_high_args(), BigInt.asIntN(64, result >> 64n), true);
            result = BigInt.asIntN(64, result);
          }
        }
      } catch (error) { failure = error; failed = true; }
      // Guest exceptions retain their tag identity and unwind through the caller's own handlers.
      if (failed && exceptionTypes.has(failure)) {
        value = e.resume_exception(importException(failure));
        check(e.error_code()); continue;
      }
      // The scalar ABI carries only the low 64 bits; vector high bits live in their separate slots.
      value = e.resume64(BigInt.asIntN(64, result), failed ? 1 : 0);
      if (failed) {
        const error = new Error(`host import ${binding.module}.${binding.name} failed at byte ${Math.max(0, e.error_offset() - 4096)}`);
        Object.defineProperty(error, 'cause', { value: failure });
        throw error;
      }
      check(e.error_code());
    }
    check(e.error_code());
    // The bootstrap avoids scratch metadata work when its native queries cross no interpreted boundary.
    if (!ensureMemory) {
      const count = e.result_count();
      if (count > 1) {
        const view = new DataView(e.memory.buffer, memoryOffset), at = e.result_base();
        return Array.from({length: count}, (_, slot) => {
          let bits = view.getBigInt64(at + slot * 8, true);
          const type = e.result_type(slot);
          if (type === 7) bits = BigInt.asUintN(64, bits) | (view.getBigUint64(e.result_high_base() + slot * 8, true) << 64n);
          return raw ? rawResult(bits, type) : decodedValue(bits, type);
        });
      }
      const type = e.result_type(0);
      if (type === 7) value = BigInt.asUintN(64, value) | (new DataView(e.memory.buffer, memoryOffset).getBigUint64(e.result_high_base(), true) << 64n);
      return raw ? rawResult(value, type) : decodedValue(value, type);
    }
    const info = e.result_info();
    if (!info) check(e.error_code());
    const output = new DataView(e.memory.buffer, memoryOffset);
    const resultCount = output.getUint32(info, true), at = output.getUint32(info + 4, true), highAt = output.getUint32(info + 8, true);
    // Copy kinds and bits before decoding references can issue further metadata queries.
    const types = Array.from({length: Math.max(1, resultCount)}, (_, slot) => output.getUint32(info + 12 + slot * 4, true));
    if (resultCount > 1) {
      const bits = Array.from({length: resultCount}, (_, slot) => {
        const low = output.getBigInt64(at + slot * 8, true);
        return types[slot] === 7 ? BigInt.asUintN(64, low) | (output.getBigUint64(highAt + slot * 8, true) << 64n) : low;
      });
      return bits.map((bits, slot) => raw ? rawResult(bits, types[slot]) : decodedValue(bits, types[slot]));
    }
    const resultType = types[0];
    if (resultType === 7) value = BigInt.asUintN(64, value) | (output.getBigUint64(highAt, true) << 64n);
    return raw ? rawResult(value, resultType) : decodedValue(value, resultType);
  }
  // Run either public scalar values or exact raw slots through the same protected invocation.
  function invokeValues(name, values, raw = false, index = undefined) {
      synchronizeIn();
      const at = e.host_base();
      // Indexed calls already resolved their export and need no second name write.
      const n = index === undefined ? write(name, at) : 0;
      const argumentsAt = Math.ceil((at + n) / 8) * 8;
      ensure(argumentsAt + values.length * 8);
      const view = new DataView(e.memory.buffer, memoryOffset);
      const highAt = values.length ? e.argument_high_base() : 0;
      values.forEach((value, index) => {
        view.setBigInt64(argumentsAt + index * 8, BigInt.asIntN(64, value), true);
        view.setBigInt64(highAt + index * 8, value > 0n ? BigInt.asIntN(64, value >> 64n) : 0n, true);
      });
      invoking = true;
      if (backend.countsForwardingDepth) invocationDepth++;
      try {
        return drive(index === undefined ? e.invoke64(at, n, argumentsAt, values.length) : e.invoke_index64(index, argumentsAt, values.length), raw);
      } finally {
        // An interrupted host operation must not strand protected execution state.
        try {
          if (e.pending_import() >= 0) e.resume64(0n, 1);
          synchronizeOut();
        } finally {
          if (backend.countsForwardingDepth) invocationDepth--;
          invoking = false;
        }
      }
  }
  const api = {
    // Parse and validate a module without imports, resource allocation, segment effects or start execution.
    validate(source, binarySource = false) {
      requireIdle();
      loaded = false;
      generation++;
      const sourceLength = write(source, 4096);
      e.validation_only(1);
      try { check(binarySource ? e.load_binary(4096, sourceLength) : e.load(4096, sourceLength)); }
      finally { e.validation_only(0); }
      return api;
    },
    load(/** @type {string} */ source, /** @type {Record<string, Record<string, Function>>} */ imports = {}, binarySource = false) {
      requireIdle();
      loaded = false;
      generation++;
      bindings = []; resources = []; importedExceptions.clear(); exportedResources = new Map(); exportedFunctions = new Map();
      tableFunctions = new Map(); foreignFunctions = new Map();
      externalValues = [null]; externalIds = new Map();
      const sourceLength = write(source, 4096);
      check(binarySource ? e.load_binary(4096, sourceLength) : e.load(4096, sourceLength));
      for (let index = 0; index < e.tag_count(); index++) e.bind_tag(index, nextTagIdentity++);
      const resolved = [], resourceBindings = [];
      let pages = e.memory_minimum(0), maximum = e.memory_maximum(0), entries = e.table_size(0), tableMaximum = e.table_max(0);
      for (let index = 0; index < e.import_count(); index++) {
        const view = new DataView(e.memory.buffer, memoryOffset);
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
          if (kind === 4) {
            const descriptor = typeDescription(e.tag_type(target));
            if (!compatibleType(state.descriptor, descriptor) || !compatibleType(descriptor, state.descriptor)) throw new Error(`import signature mismatch ${module}.${name}`);
            e.bind_tag(target, state.identity); resourceBindings.push({index: target, state}); resolved.push(null); continue;
          }
          if (kind === 1 || kind === 3) {
            if (state.addressType !== (kind === 1 ? e.memory_width(target) : e.table_address_type(target))) throw new Error(`import signature mismatch ${module}.${name}`);
            const actual = kind === 1 ? state.pages : state.entries.length;
            const minimum = kind === 1 ? e.memory_minimum(target) : e.table_size(target), requiredMaximum = kind === 1 ? e.memory_maximum(target) : e.table_max(target);
            if (kind === 3 && (!compatibleType(state.descriptor, typeDescription(view.getInt32(e.table_info(target) + 16, true))) || !compatibleType(typeDescription(view.getInt32(e.table_info(target) + 16, true)), state.descriptor))) throw new Error(`import signature mismatch ${module}.${name}`);
            if (actual < minimum || (requiredMaximum !== -1 && (state.maximum === -1 || state.maximum > requiredMaximum))) throw new Error(`import signature mismatch ${module}.${name}`);
            if (kind === 1) check(e.bind_guest_memory(target, actual, state.maximum));
            else check(e.bind_guest_table(target, actual, state.maximum));
          } else {
            const globalAt = e.global_info(target);
            if (state.mutable !== view.getInt32(globalAt + 8, true) || !compatibleType(state.descriptor, typeDescription(view.getInt32(globalAt + 12, true))) || (state.mutable && !compatibleType(typeDescription(view.getInt32(globalAt + 12, true)), state.descriptor))) throw new Error(`import signature mismatch ${module}.${name}`);
          }
          resourceBindings.push({index: target, state});
          resolved.push(null); continue;
        }
        const params = Array.from({ length: e.function_params(target) }, (_, slot) => e.function_param_type(target, slot));
        const results = resultSignature(target);
        if (typeof callback !== 'function') throw new Error(`missing function import ${module}.${name}`);
        const signature = functionTypes.get(callback);
        if (signature && (!signature.valid() || signature.params.join(',') !== params.join(',') || JSON.stringify(signature.results) !== JSON.stringify(results) || (signature.descriptor && !compatibleType(signature.descriptor, typeDescription(e.function_heap_type(target)))))) {
          throw new Error(`import signature mismatch or stale binding ${module}.${name}`);
        }
        resolved.push({ module, name, params, results, callback });
      }
      bindings = resolved; resources = resourceBindings;
      const globalAliases = new Map();
      for (const binding of resources) if (binding.state.kind === 2) {
        if (globalAliases.has(binding.state)) e.alias_guest_global(binding.index, globalAliases.get(binding.state));
        else globalAliases.set(binding.state, binding.index);
      }
      const memoryAliases = new Map();
      for (const binding of resources) if (binding.state.kind === 1) {
        if (memoryAliases.has(binding.state)) e.alias_guest_memory(binding.index, memoryAliases.get(binding.state));
        else memoryAliases.set(binding.state, binding.index);
      }
      const tableAliases = new Map();
      for (const binding of resources) if (binding.state.kind === 3) {
        if (tableAliases.has(binding.state)) e.alias_guest_table(binding.index, tableAliases.get(binding.state));
        else tableAliases.set(binding.state, binding.index);
      }
      check(e.prepare_resource_imports(pages, maximum, entries, tableMaximum));
      synchronizeIn();
      if (backend.countsForwardingDepth && invocationDepth >= maxInvocationDepth) throw new Error('forwarding depth limit');
      // Start callbacks may inspect initialized resources while invocation/reload remain guarded.
      loaded = true;
      invoking = true;
      if (backend.countsForwardingDepth) invocationDepth++;
      try {
        check(e.initialize());
        drive(0n);
        synchronizeOut();
      } catch (error) {
        if (e.segments_ready()) synchronizeOut();
        loaded = false;
        throw error;
      } finally {
        try {
          if (e.pending_import() >= 0) e.resume64(0n, 1);
        } finally {
          if (backend.countsForwardingDepth) invocationDepth--;
          invoking = false;
        }
      }
    },
    loadBinary(bytes, imports = {}) {
      if (!(bytes instanceof Uint8Array)) throw new Error('binary source must be a Uint8Array');
      return api.load(bytes, imports, true);
    },
    invoke(/** @type {string} */ name, /** @type {(number | bigint)[]} */ ...args) {
      requireIdle();
      requireLoaded();
      if (backend.countsForwardingDepth && invocationDepth >= maxInvocationDepth) throw new Error('forwarding depth limit');
      if (args.length > 128) throw new Error('too many arguments (maximum 128)');
      const signature = functionSignature(name, false);
      if (args.length !== signature.params.length) throw new Error('argument mismatch');
      const values = args.map((arg, index) => {
        try { return typedValue(arg, signature.params[index]); }
        catch (error) {
          if (signature.params[index] >= 5) throw error;
          throw new Error(signature.params[index] === 2 ? 'arguments must be i64 BigInt integers' : signature.params[index] === 1 ? 'arguments must be i32 integers' : `arguments must be ${scalarNames[signature.params[index]]} Numbers`);
        }
      });
      return invokeValues('', values, false, signature.index);
    },
    // Raw scalar slots preserve signaling NaNs and payloads for conformance assertions.
    invokeRaw(name, ...args) {
      requireIdle();
      requireLoaded();
      if (backend.countsForwardingDepth && invocationDepth >= maxInvocationDepth) throw new Error('forwarding depth limit');
      const signature = functionSignature(name, false);
      if (args.length !== signature.params.length) throw new Error('argument mismatch');
      const values = args.map((arg, index) => {
        return rawSlot(arg, signature.params[index]);
      });
      return invokeValues('', values, true, signature.index);
    },
    signature(/** @type {string} */ name) {
      const signature = functionSignature(name);
      return { params: signature.params.map(type => scalarNames[type]), result: Array.isArray(signature.results) ? signature.results.map(type => scalarNames[type]) : scalarNames[signature.results] };
    },
    exportFunction(/** @type {string} */ name) {
      requireLoaded();
      const signature = functionSignature(name);
      if (exportedFunctions.has(signature.index)) return exportedFunctions.get(signature.index);
      const existing = tableFunctions.get(signature.index);
      if (existing?.owner === owner) return existing.callback;
      const currentGeneration = generation;
      const callback = (/** @type {(number | bigint)[]} */ ...args) => {
        if (!loaded || generation !== currentGeneration) throw new Error('stale forwarded function');
        return api.invoke(name, ...args);
      };
      functionTypes.set(callback, {
        params: signature.params, results: signature.results,
        descriptor: typeDescription(e.function_heap_type(signature.index)),
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
      exportedFunctions.set(signature.index, callback);
      return callback;
    },
    exportNamespace() {
      requireLoaded(); synchronizeIn();
      const namespace = Object.create(null);
      for (let index = 0; index < e.exports_count(); index++) {
        const view = new DataView(e.memory.buffer, memoryOffset), at = e.export_info(index);
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
      let value = e.get_global64(at, n);
      if (type === 7) value = BigInt.asUintN(64, value) | (BigInt.asUintN(64, e.global_high(at, n)) << 64n);
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
      const bits = typedValue(value, type);
      // Foreign function interning uses host scratch; restore the global name afterward.
      write(name, at);
      check(e.set_global64(at, n, BigInt.asIntN(64, bits)));
      if (type === 7) check(e.set_global_high(at, n, BigInt.asIntN(64, bits >> 64n)));
      synchronizeOut();
    },
    readMemory(/** @type {number} */ offset, /** @type {number} */ length) {
      synchronizeIn();
      const at = memoryRange(offset, length);
      return new Uint8Array(e.memory.buffer, memoryOffset + at, length).slice();
    },
    writeMemory(/** @type {number} */ offset, /** @type {Uint8Array} */ bytes) {
      synchronizeIn();
      if (!(bytes instanceof Uint8Array)) throw new Error('memory bytes must be a Uint8Array');
      const at = memoryRange(offset, bytes.length);
      new Uint8Array(e.memory.buffer, memoryOffset + at, bytes.length).set(bytes);
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
  engineBackends.set(api, backend);
  return api;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const arguments_ = process.argv.slice(2);
    const bootstrap = arguments_[0] === '--bootstrap';
    if (bootstrap) arguments_.shift();
    const [file, name, ...values] = arguments_;
    if (!file || name === undefined) throw new Error('Usage: node wiw.js [--bootstrap] <file.wat> <export> [scalar arguments...]');
    const interpreter = await (bootstrap ? createBootstrapInterpreter() : createInterpreter());
    interpreter.load(await readFile(file, 'utf8'));
    const signature = interpreter.signature(name);
    const args = values.map((arg, index) => signature.params[index] === 'i64' ? BigInt(arg.endsWith('n') ? arg.slice(0, -1) : arg) : arg === 'inf' || arg === '+inf' ? Infinity : arg === '-inf' ? -Infinity : Number(arg));
    const value = interpreter.invoke(name, ...args);
    if (value !== undefined) console.log(String(value));
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  }
}
