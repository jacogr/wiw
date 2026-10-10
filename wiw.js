import { readFile } from 'node:fs/promises';
import { AsyncLocalStorage } from 'node:async_hooks';
import { pathToFileURL } from 'node:url';
import { WASI } from 'node:wasi';

const messages = [
  '',
  'invalid syntax',
  'unsupported feature',
  'integer out of range',
  'unknown export',
  'invalid buffer',
  'resource limit',
  'invalid operand stack',
  'divide by zero',
  'integer overflow',
  'invalid or duplicate reference',
  'argument mismatch',
  'exhausted fuel',
  'executed unreachable',
  'memory out of bounds',
  'invalid memory limits',
  'immutable global',
  'interpreter error',
  'export kind mismatch',
  'invalid alignment',
  'host import failed',
  'invalid resume',
  'invocation already suspended',
  'host value type mismatch',
  'undefined element',
  'indirect call type mismatch',
  'invalid table limits',
  'element out of bounds',
  'invalid conversion to integer',
  'instance not initialized',
  'table out of bounds',
  'null reference',
  'cast failure',
  'array out of bounds',
  'uncaught exception'
];
let nextTagIdentity = 1;
const exceptionTypes = new WeakMap();
export class WiwException extends Error {
  // Create the host error used to carry an uncaught tagged guest exception.
  constructor() {
    super('uncaught guest exception');

    this.name = 'WiwException';
  }

  // Compare live tag identity rather than matching payload signatures.
  is(tag) {
    return exceptionData(this, tag).matches;
  }

  // Read a decoded exception argument after checking its tag and index.
  getArg(tag, index) {
    return exceptionArgument(this, tag, index, false);
  }

  // Read an exception argument while preserving its raw value bits.
  getArgRaw(tag, index) {
    return exceptionArgument(this, tag, index, true);
  }
}

// Typed forwarding bindings retain the provider's signature and load generation.
/** @type {WeakMap<Function, {params: number[], results: number | number[], valid: () => boolean}>} */
const functionTypes = new WeakMap();
const resourceTypes = new WeakMap();

// Exception payload snapshots remain private; inspection never touches guest scratch or frame state.
function exceptionData(exception, tag) {
  const data = exceptionTypes.get(exception),
    state = resourceTypes.get(tag);

  // Reject exception objects that have no retained guest payload.
  if (!data) throw new Error('uninitialized wiw exception');

  // Require a tag handle before comparing exception identities.
  if (!state || state.kind !== 4) throw new Error('exception inspection requires a wiw tag');

  // Prevent inspection through a tag from a previous guest generation.
  if (!state.valid()) throw new Error('stale tag binding');

  return { data, matches: data.identity === state.identity };
}

// Check the tag and bounds before returning an exception payload slot.
function exceptionArgument(exception, tag, index, raw) {
  const { data, matches } = exceptionData(exception, tag);

  // Prevent reading a payload through an unrelated tag with a similar signature.
  if (!matches) throw new Error('exception tag mismatch');

  // Check the argument index before accessing the retained payload.
  if (!Number.isInteger(index) || index < 0 || index >= data.args.length)
    throw new Error('exception argument index out of bounds');

  return raw ? { ...data.args[index] } : data.values[index];
}

// Host-defined tags carry a structural signature and an identity independent of any guest load.
export function createTag(parameters = []) {
  // Require an ordered list of tag parameter types.
  if (!Array.isArray(parameters)) throw new Error('tag parameters must be an array');

  // Keep the tag arity representable by the guest ABI.
  if (parameters.length > 65535) throw new Error('too many tag parameters (maximum 65535)');

  const kinds = { i32: 1, i64: 2, f32: 3, f64: 4, funcref: 5, externref: 6, v128: 7, anyref: 8, exnref: 9 };
  const roots = { funcref: 5, externref: 6, anyref: 16, exnref: 32 };
  // Validate each tag parameter name and retain its reference-type constraints.
  const params = Array.from(parameters, (name) => {
    // Reject parameter names that the interpreter cannot encode.
    if (typeof name !== 'string' || !Object.hasOwn(kinds, name))
      throw new Error(`unsupported tag parameter type ${String(name)}`);

    return Object.freeze(
      Object.hasOwn(roots, name) ? { kind: kinds[name], nonnull: false, heap: roots[name] } : { kind: kinds[name] }
    );
  });
  const heap = {
    kind: 0,
    final: 1,
    position: 0,
    parent: null,
    params: Object.freeze(params),
    results: Object.freeze([]),
    fields: Object.freeze([])
  };

  heap.group = Object.freeze([heap]);

  Object.freeze(heap);

  const handle = Object.freeze({ kind: 'tag' });

  resourceTypes.set(handle, {
    kind: 4,
    identity: nextTagIdentity++,

    // Host-defined tags remain valid independently of guest module reloads.
    valid: () => true,
    handle,
    descriptor: Object.freeze({ kind: 5, nonnull: true, heap })
  });

  return handle;
}

const invocationContext = new AsyncLocalStorage();
// Callback scopes authorize their own suspended instance, including across awaits and forwarding cycles.
const callbackContext = new AsyncLocalStorage();

// Read the forwarding depth of the current asynchronous invocation.
const currentDepth = () => invocationContext.getStore() ?? 0;
const asynchronousImports = new WeakSet();
const asynchronousFunctions = new WeakMap();

// Explicitly distinguish an asynchronous externref import from an opaque Promise value.
export function asyncImport(callback) {
  // Require a callable target before marking an import as asynchronous.
  if (typeof callback !== 'function') throw new Error('async import must be a function');

  // Forward the call while retaining explicit asynchronous-import metadata.
  const binding = (...args) => callback(...args);

  asynchronousImports.add(binding);

  const metadata = functionTypes.get(callback);

  // Preserve typed forwarding information when wrapping an existing guest export.
  if (metadata) functionTypes.set(binding, metadata);

  return binding;
}

// Backing memory and address origins stay private to the host adapters.
const engineBackends = new WeakMap();

// Validate resource budgets before allocating either a bootstrap or a self-hosted runtime.
const defaultLimits = Object.freeze({
  functions: 65536,
  exports: 512,
  globals: 512,
  callFrames: 512,
  memoryPages: 2048,
  externalReferences: 65535,
  forwardingDepth: 128
});
const maximumLimits = Object.freeze({
  functions: 131072,
  exports: 16777216,
  globals: 16777216,
  callFrames: 65535,
  memoryPages: 65536,
  externalReferences: 16777215,
  forwardingDepth: 65535
});
// Additional capacities retain the compact default layout and reserve larger arenas on load.
const arenaLimits = Object.freeze({
  instructions: [131072, 16777216],
  operands: [4096, 65535],
  controls: [4096, 65535],
  syntaxDepth: [256, 65535],
  auxiliarySlots: [131072, 16777216],
  imports: [1024, 65536],
  types: [768, 65536],
  indirectTypes: [1024, 65536],
  referenceTypes: [4096, 131072],
  fields: [32768, 16777216],
  tags: [256, 65536],
  memories: [512, 65536],
  tables: [32, 65536],
  tableEntries: [4096, 16777216],
  dataSegments: [128, 65536],
  elementSegments: [128, 65536],
  elementEntries: [4096, 16777216],
  dataBytes: [65536, 268435456],
  resultShapes: [4096, 16777216],
  gcHeapBytes: [16777216, 268435456],
  gcMapBytes: [4194304, 268435456],
  gcTemporaries: [1024, 65535],
  binaryTextBytes: [1048576, 268435456],
  typeComparisonDepth: [1024, 65535],
  parameters: [128, 65535],
  results: [128, 65535],
  locals: [1088, 65535],
  floatLiteralBytes: [8192, 1048576]
});

// Validate requested resource budgets and merge them with the default capacities.
function instanceLimits(options) {
  const requested = options.limits ?? {};

  // Reject malformed capacity options before allocating an interpreter.
  if (typeof requested !== 'object' || requested === null || Array.isArray(requested))
    throw new Error('limits must be an object');

  const limits = {
    ...defaultLimits,
    ...Object.fromEntries(Object.entries(arenaLimits).map(([name, [value]]) => [name, value]))
  };

  // Validate each requested capacity independently before applying any overrides.
  for (const [name, value] of Object.entries(requested)) {
    // Catch misspelled or unsupported capacity names rather than silently ignoring them.
    if (!Object.hasOwn(limits, name)) throw new Error(`unknown limit ${name}`);

    const minimum = arenaLimits[name]?.[0] ?? (['callFrames', 'forwardingDepth'].includes(name) ? 1 : 0);
    const maximum = arenaLimits[name]?.[1] ?? maximumLimits[name];

    // Keep each capacity within the physical representation limits of its arena.
    if (!Number.isInteger(value) || value < minimum || value > maximum) {
      throw new Error(`limit ${name} must be an integer from ${minimum} to ${maximum}`);
    }

    limits[name] = value;
  }

  // Ensure every parameter can occupy a local slot in the guest frame.
  if (limits.parameters > limits.locals) throw new Error('limit parameters must not exceed locals');

  return limits;
}

// Apply validated resource capacities to the interpreter host ABI.
function configureLimits(exports, limits) {
  const status = exports.configure_limits(
    limits.functions,
    limits.exports,
    limits.globals,
    limits.callFrames,
    limits.memoryPages
  );

  // Stop construction if the guest ABI rejects the primary resource budgets.
  if (status) throw new Error(`could not configure interpreter limits: status ${status}`);

  // Apply only enlarged arena capacities, retaining the compact default layout otherwise.
  Object.keys(arenaLimits).forEach((name, index) => {
    // Reserve larger arenas only when their requested capacities differ from the defaults.
    if (limits[name] !== arenaLimits[name][0]) {
      const status = exports.configure_capacity(index, limits[name]);

      // Stop construction if an enlarged arena cannot be configured.
      if (status) throw new Error(`could not configure ${name}: status ${status}`);
    }
  });
}

/** Create a fresh native interpreter from a binary path or a caller-owned compiled bootstrap module. */

/** Guest source is never handed to WebAssembly; compiled modules share code, not instance state. */
export async function createBootstrapInterpreter(
  binary = new URL('./build/wiw-opt.wasm', import.meta.url),
  options = {}
) {
  const limits = instanceLimits(options);
  const instance =
    binary instanceof WebAssembly.Module
      ? new WebAssembly.Instance(binary)
      : (await WebAssembly.instantiate(await readFile(binary))).instance;

  configureLimits(instance.exports, limits);

  return wrapInterpreter(instance.exports, { limits });
}

/** Create the default runtime: one interpreted WAT copy of wiw above the bootstrap. */
export async function createInterpreter(binary = new URL('./build/wiw-opt.wasm', import.meta.url), options = {}) {
  return createInterpretedInterpreter(binary, options);
}

/** Run a WAT copy of wiw (optimized by default) inside a bootstrap using the same host ABI. */
export async function createInterpretedInterpreter(
  binary = new URL('./build/wiw-opt.wasm', import.meta.url),
  options = {}
) {
  const limits = instanceLimits(options);
  const parent = await createBootstrapInterpreter(binary, { limits: options.parentLimits });
  const backend = engineBackends.get(parent);

  // Parent ABI calls are implementation work, not guest-to-guest forwarding.
  backend.countsForwardingDepth = false;

  parent.load(options.source ?? (await readFile(new URL('./build/wiw-opt.wat', import.meta.url), 'utf8')));
  backend.exports.set_fuel64((1n << 64n) - 1n);
  // The parent holds child arenas as well as the child's full guest-memory capacity.
  backend.exports.enable_interpreter_backing();

  const memoryOffset = backend.memoryOffset + backend.exports.guest_memory_base();
  const exports = { memory: backend.exports.memory };

  // Expose the hosted engine ABI by forwarding its functions through the parent interpreter.
  for (const [name, value] of Object.entries(backend.exports)) {
    // Forward callable exports while retaining the backing memory object directly.
    if (typeof value === 'function') exports[name] = (...args) => parent.invoke(name, ...args);
  }

  configureLimits(exports, limits);
  backend.exports.set_fuel64(BigInt(options.parentFuel ?? (1n << 64n) - 1n));

  return wrapInterpreter(exports, {
    memoryOffset,
    limits,

    // Grow the parent guest memory to hold the interpreted engine backing.
    ensureMemory(required) {
      const current = backend.exports.guest_memory_pages();
      const needed = Math.ceil(required / 65536);

      // Report failure when the parent cannot reserve enough memory for the child engine.
      if (needed > current && parent.growMemory(needed - current) < 0)
        throw new Error('resource limit while growing interpreted backing memory');
    }
  });
}

// Numeric pointers remain relative to the engine's own memory at every depth.
function wrapInterpreter(exports, { memoryOffset = 0, ensureMemory, limits } = {}) {
  // Wasm i32 addresses are unsigned even when JavaScript receives a negative Number above 2 GiB.
  const addressExports = Object.fromEntries(
    Object.entries(exports).map(([name, value]) => [
      name,
      typeof value === 'function' &&
      (/(?:_base|_info|_args)$/.test(name) || name === 'error_offset' || name === 'function_signature')
        ? (...args) => value(...args) >>> 0
        : value
    ])
  );
  const e =
    /** @type {{memory: WebAssembly.Memory, load: (p: number, n: number) => number, initialize: () => number, invoke: (p: number, n: number, args: number, count: number) => number, error_code: () => number, error_offset: () => number, host_base: () => number, result_count: () => number, set_fuel: (fuel: number) => void, set_fuel64: (fuel: bigint) => void, guest_memory_base: () => number, guest_memory_pages: () => number, guest_memory_present: () => number, get_global: (p: number, n: number) => number, set_global: (p: number, n: number, value: number) => number, import_count: () => number, import_info: (index: number) => number, function_params: (index: number) => number, function_results: (index: number) => number, export_function: (p: number, n: number) => number, pending_import: () => number, pending_args: () => number, resume: (value: number, failed: number) => number, grow_guest_memory: (delta: number) => number, invoke64: (p: number, n: number, args: number, count: number) => bigint, resume64: (value: bigint, failed: number) => bigint, result_type: (slot: number) => number, function_param_type: (index: number, slot: number) => number, function_result_type: (index: number, slot: number) => number, global_type: (p: number, n: number) => number, argument_high_base: () => number, pending_high_args: () => number, result_high_base: () => number, result_base: () => number, global_high: (p: number, n: number) => bigint, set_global_high: (p: number, n: number, value: bigint) => number, get_global64: (p: number, n: number) => bigint, set_global64: (p: number, n: number, value: bigint) => number}} */ (
      addressExports
    );
  const backend = { exports: e, memoryOffset, countsForwardingDepth: true };
  let loaded = false;
  let invoking = false;
  let activeInvocation;
  let generation = 0;
  /** @type {{module: string, name: string, params: number[], results: number | number[], callback: Function}[]} */
  let bindings = [];
  let resources = [];
  let exportedResources = new Map(),
    exportedFunctions = new Map();
  let tableFunctions = new Map();
  let foreignFunctions = new Map();
  let resourceExports;
  const owner = {};
  const negativeZeroKey = Symbol();
  let externalValues = [null],
    externalIds = new Map();

  // Ensure that the interpreter backing memory covers the requested byte range.
  function ensure(/** @type {number} */ required) {
    // Delegate backing growth to the parent when this engine is self-hosted.
    if (ensureMemory) return ensureMemory(required);

    // Grow native backing memory only when the requested span exceeds the current allocation.
    if (required > e.memory.buffer.byteLength)
      e.memory.grow(Math.ceil((required - e.memory.buffer.byteLength) / 65536));
  }

  // Encode text or copy bytes into checked interpreter scratch memory.
  function write(/** @type {string} */ text, /** @type {number} */ at) {
    const bytes = text instanceof Uint8Array ? text : new TextEncoder().encode(text);
    const required = at + bytes.length;

    ensure(required);
    new Uint8Array(e.memory.buffer, memoryOffset + at, bytes.length).set(bytes);

    return bytes.length;
  }

  // Turn a nonzero interpreter status into a descriptive host error.
  function check(/** @type {number} */ code) {
    // Preserve tagged guest exceptions instead of reducing them to ordinary status errors.
    if (code === 34) throw guestException();

    // Translate remaining nonzero statuses into errors with their guest source offsets.
    if (code)
      throw new Error(`${messages[code] ?? 'interpreter error'} at byte ${Math.max(0, e.error_offset() - 4096)}`);
  }
  const importedExceptions = new Map();

  // Reconstruct a guest exception from its exported tag and payload slots.
  function guestException() {
    const reference = e.exception_reference();
    const previous = importedExceptions.get(reference)?.deref();

    // Reuse a live exception wrapper so repeated propagation preserves host identity.
    if (previous) return previous;

    const view = new DataView(e.memory.buffer, memoryOffset),
      at = e.exception_info(reference);
    const tag = view.getInt32(at + 8, true),
      identity = Number(view.getBigUint64(at + 16, true));
    const heap = view.getInt32(e.tag_info(tag) + 24, true),
      count = view.getInt32(at + 4, true) - 1;
    const params = Array.from({ length: count }, (_, slot) => e.value_kind(e.heap_param_type(heap, slot)));
    // Recover each exception payload slot, including the upper vector half.
    const args = params.map((type, slot) => {
      const low = view.getBigInt64(at + 32 + slot * 16, true),
        high = view.getBigUint64(at + 40 + slot * 16, true);

      return rawResult(type === 7 ? BigInt.asUintN(64, low) | (high << 64n) : low, type);
    });

    return exceptionSnapshot(identity, params, args);
  }

  // Copy typed and raw payloads so mutation of caller descriptors cannot change a later rethrow.
  function exceptionSnapshot(identity, params, args) {
    const exception = new WiwException();
    const snapshots = args.map((arg) => Object.freeze({ ...arg }));
    const values = snapshots.map((arg, index) =>
      isHostReference(params[index]) ? arg.value : decodedValue(arg.bits, params[index])
    );

    exceptionTypes.set(exception, {
      identity,
      params: Object.freeze([...params]),
      args: Object.freeze(snapshots),
      values: Object.freeze(values)
    });

    return exception;
  }

  // Translate a host exception into the guest exception ABI.
  function importException(exception) {
    const { identity, params, args } = exceptionTypes.get(exception);
    // Intern all references before obtaining scratch that foreign-function growth can relocate.
    const bits = args.map((arg, slot) => rawSlot(arg, params[slot]));
    const at = e.host_base(),
      maskAt = at + args.length * 8;
    const words = Math.ceil(args.length / 64);

    ensure(maskAt + Math.max(1, words) * 8);

    const view = new DataView(e.memory.buffer, memoryOffset);
    const high = e.argument_high_base();

    // Write each encoded exception payload slot into the guest import-exception ABI.
    bits.forEach((value, slot) => {
      view.setBigInt64(at + slot * 8, BigInt.asIntN(64, value), true);
      view.setBigInt64(high + slot * 8, BigInt.asIntN(64, value >> 64n), true);
    });

    const mask = params.reduce((bits, type, slot) => (isHostReference(type) ? bits | (1n << BigInt(slot)) : bits), 0n);

    // Publish every exception root-bitmap word, including parameters beyond the first 64 slots.
    for (let word = 0; word < words; word++)
      view.setBigUint64(maskAt + word * 8, BigInt.asUintN(64, mask >> BigInt(word * 64)), true);

    const reference = e.import_exception_bits(identity, args.length, at, maskAt);

    check(e.error_code());
    e.gc_pin(reference, 1);
    importedExceptions.set(reference, new WeakRef(exception));

    return reference;
  }

  // Reject operations before the guest module has been initialized.
  function requireLoaded() {
    // Prevent ABI calls from observing an uninitialized guest module.
    if (!loaded) throw new Error('no loaded module');
  }

  // Require a signed or unsigned i32 representation without silently truncating the value.
  function i32(/** @type {number} */ value) {
    // Accept either signed or unsigned i32 spelling while rejecting truncation or fractional values.
    if (!Number.isInteger(value) || value < -2147483648 || value > 4294967295) {
      throw new Error('value must be an i32 integer');
    }
  }

  // Resolve numeric or exported-name resource selectors before querying canonical records.
  function resourceIndex(selector, kind, count, label) {
    // Resolve named selectors through the guest export namespace.
    if (typeof selector === 'string') {
      // Build the export lookup once for the current load generation.
      if (!resourceExports) {
        resourceExports = new Map();

        // Retain each exported resource name, kind and index for subsequent lookups.
        for (let index = 0; index < e.exports_count(); index++) {
          const at = e.export_info(index),
            view = new DataView(e.memory.buffer, memoryOffset);
          const name = readText(view.getUint32(at, true), view.getUint32(at + 4, true));

          resourceExports.set(name, { index: view.getInt32(at + 8, true), kind: view.getInt32(at + 20, true) });
        }
      }

      const descriptor = resourceExports.get(selector);

      // Report a missing export before accessing its resource descriptor.
      if (!descriptor) throw new Error(`unknown export ${selector}`);

      // Prevent using an export of another resource kind as the requested memory, table or tag.
      if (descriptor.kind !== kind) throw new Error(`export kind mismatch ${selector}`);

      return descriptor.index;
    }

    // Distinguish an absent default resource from an out-of-range selector.
    if (!count && selector === 0) throw new Error(`no guest ${label}`);

    // Check numeric selectors against the current resource count.
    if (!Number.isInteger(selector) || selector < 0 || selector >= count) throw new Error(`invalid ${label} index`);

    return selector;
  }

  // Resolve a guest memory selector to its checked resource index.
  function memoryIndex(memory = 0) {
    requireLoaded();

    return resourceIndex(memory, 1, e.guest_memory_present(), 'memory');
  }

  // Resolve a guest table selector to its checked resource index.
  function tableIndex(table = 0) {
    requireLoaded();

    return resourceIndex(table, 3, e.table_count(), 'table');
  }

  // A supplied tag handle must have a live alias in this loaded module.
  function tagIndex(tag = 0) {
    requireLoaded();

    // Resolve host tag handles by identity rather than by a guest-local numeric index.
    if (typeof tag === 'object' && tag !== null) {
      const state = resourceTypes.get(tag);

      // Reject objects that were not created as wiw tag handles.
      if (!state || state.kind !== 4) throw new Error('value must be a wiw tag');

      // Reject tag handles whose provider has been reloaded.
      if (!state.valid()) throw new Error('stale tag binding');

      // Find the guest tag bound to the host handle's stable identity.
      for (let index = 0; index < e.tag_count(); index++) {
        // Return the matching guest-local tag index without conflating equal signatures.
        if (new DataView(e.memory.buffer, memoryOffset).getInt32(e.tag_info(index) + 16, true) === state.identity)
          return index;
      }

      throw new Error('tag does not belong to loaded module');
    }

    return resourceIndex(tag, 4, e.tag_count(), 'tag');
  }

  // Read the parameter types declared by a guest exception tag.
  function tagParameters(index) {
    const heap = new DataView(e.memory.buffer, memoryOffset).getInt32(e.tag_info(index) + 24, true);

    return Array.from({ length: e.heap_params(heap) }, (_, slot) => e.value_kind(e.heap_param_type(heap, slot)));
  }

  // Host-created exceptions are snapshots; guest allocation occurs only when a callback throws one.
  function createException(tag, args, raw) {
    synchronizeIn();

    const index = tagIndex(tag),
      params = tagParameters(index);

    // Require exactly the payload arity declared by the selected tag.
    if (args.length !== params.length) throw new Error('exception argument mismatch');

    // Validate and retain each exception argument in both raw and decoded forms.
    const payload = args.map((arg, slot) => {
      const bits = raw ? rawSlot(arg, params[slot]) : typedValue(arg, params[slot]);

      // Ask the guest type checker to validate reference-valued exception payloads.
      if (isHostReference(params[slot])) {
        const accepts = e.tag_accepts(index, slot, bits);

        check(e.error_code());

        // Reject a payload reference that does not satisfy the tag's declared type.
        if (!accepts) throw new Error('exception payload type mismatch');
      }

      return rawResult(bits, params[slot]);
    });
    const identity = new DataView(e.memory.buffer, memoryOffset).getInt32(e.tag_info(index) + 16, true);

    return exceptionSnapshot(identity, params, payload);
  }

  // Table64 indices are checked in full before using the bounded physical entry arena.
  function tableEntry(index, table) {
    // Preserve large table64 indices until their logical bounds have been checked.
    if (typeof index === 'bigint') {
      // Prevent BigInt indices from being accepted for a table32 resource.
      if (e.table_address_type(table) !== 2) throw new Error('BigInt indices require table64');

      // Reject negative or oversized table64 indices before narrowing them to the physical slot.
      if (index < 0n || index >= BigInt(e.table_size(table))) throw new Error('table out of bounds');

      return Number(index);
    }

    // Reject unsafe, fractional or out-of-range Number indices before reading the table.
    if (!Number.isSafeInteger(index) || index < 0 || index >= e.table_size(table))
      throw new Error('table out of bounds');

    return index;
  }

  // Preserve nullable and concrete reference types instead of checking only funcref/externref kinds.
  function tableValue(value, table) {
    const type = e.table_type(table);
    const bits = typedValue(value, type);
    const accepts = e.table_accepts(table, bits);

    check(e.error_code());

    // Prevent incompatible references from entering a typed guest table.
    if (!accepts) throw new Error('table element type mismatch');

    return bits;
  }

  // Normalize only checked physical offsets, retaining full-width memory64 bounds checks.
  function memoryRange(offset, length, index) {
    const size = e.memory_pages(index) * 65536;

    // Check memory64 offsets as BigInts before narrowing a physically bounded address.
    if (typeof offset === 'bigint') {
      // Prevent BigInt offsets from being accepted for memory32 resources.
      if (e.memory_width(index) !== 2) throw new Error('BigInt offsets require memory64');

      // Reject negative or out-of-range memory64 offsets before Number conversion.
      if (offset < 0n || offset > BigInt(size)) throw new Error('memory out of bounds');

      offset = Number(offset);
    }

    // Check the complete byte span without allowing unsafe arithmetic or endpoint overflow.
    if (
      !Number.isSafeInteger(offset) ||
      !Number.isSafeInteger(length) ||
      offset < 0 ||
      length < 0 ||
      offset > size ||
      length > size - offset
    )
      throw new Error('memory out of bounds');

    return e.memory_base(index) + offset;
  }

  // Reject mutation while an invocation is active or suspended.
  function requireIdle() {
    // Protect load and collection state from mutation during an active invocation.
    if (invoking) throw new Error('interpreter is already invoking');
  }

  // Authorize nested invocation only from the active callback scope.
  function reentryOwner(asynchronous) {
    // Ordinary top-level calls need no suspended callback scope to authorize entry.
    if (!invoking) return;

    // Search active callback ancestors so forwarding cycles can reenter their own suspended instance.
    for (let scope = callbackContext.getStore(); scope; scope = scope.parent) {
      // Accept only the scope that owns this instance's current invocation.
      if (scope.backend === backend && scope.invocation === activeInvocation && scope.active) {
        // Prevent asynchronous reentry from escaping a synchronous outer invocation.
        if (asynchronous && !scope.asynchronous)
          throw new Error('async reentry requires an asynchronous outer invocation');

        return scope;
      }
    }

    throw new Error('interpreter is already invoking');
  }

  // Require an unsigned 32-bit integer without wrapping the input.
  function u32(/** @type {number} */ value) {
    // Require an exact unsigned i32 value rather than silently wrapping host input.
    if (!Number.isInteger(value) || value < 0 || value > 4294967295) {
      throw new Error('value must be an unsigned i32 integer');
    }
  }

  // Decode a checked UTF-8 byte span from interpreter backing memory.
  function readText(/** @type {number} */ p, /** @type {number} */ n) {
    return new TextDecoder('utf-8', { ignoreBOM: true }).decode(new Uint8Array(e.memory.buffer, memoryOffset + p, n));
  }
  const scalarNames = [null, 'i32', 'i64', 'f32', 'f64', 'funcref', 'externref', 'v128', 'anyref', 'exnref'];
  let opaqueReferences = new Map();
  const opaqueReferenceValues = new WeakMap();

  // Weak caches preserve identity while callers retain a handle, without retaining dead guest objects forever.
  function refreshHostRoots() {
    // Avoid publishing GC roots when no host-held object or exception wrappers exist.
    if (!opaqueReferences.size && !importedExceptions.size) return;

    const alive = new Set(),
      expired = new Set();

    // Retain live opaque wrappers and gather expired handles for unpinning.
    for (const [key, weak] of opaqueReferences) {
      const value = weak.deref();

      // Pin objects whose host wrappers are still reachable.
      if (value) alive.add(opaqueReferenceValues.get(value).bits);
      else {
        // Remove expired opaque wrappers and consider their guest objects for unpinning.
        opaqueReferences.delete(key);
        expired.add(BigInt(key.slice(key.indexOf(':') + 1)));
      }
    }

    // Retain live exception wrappers and remove expired entries from the weak cache.
    for (const [bits, weak] of importedExceptions) {
      // Keep exception payload objects rooted while their host exception remains reachable.
      if (weak.deref()) alive.add(bits);
      else {
        // Remove expired exception wrappers and consider their retained payload roots for unpinning.
        importedExceptions.delete(bits);
        expired.add(bits);
      }
    }

    // Remove guest pins only after all live wrappers have been considered.
    // Preserve a pin when another live wrapper still refers to the same guest object.
    for (const bits of expired) if (!alive.has(bits)) e.gc_pin(bits, 0);
  }

  // Recognize value kinds that require host reference translation.
  const isHostReference = (type) => type >= 5 && type !== 7;

  // Decode a guest value slot, including references and raw vector halves.
  function decodedValue(/** @type {bigint} */ bits, /** @type {number} */ type) {
    // Represent void guest results as undefined.
    if (!type) return undefined;

    // Decode the i32 bit pattern using its signed host representation.
    if (type === 1) return Number(BigInt.asIntN(32, bits));

    // Preserve the full signed i64 value as a BigInt.
    if (type === 2) return BigInt.asIntN(64, bits);

    // Preserve all 128 vector bits without interpreting their lane layout.
    if (type === 7) return BigInt.asUintN(128, bits);

    // Recover function identity through the typed forwarding cache, including null references.
    if (type === 5) return bits === 0n ? null : functionReference(Number(bits - 1n)).callback;

    // Unwrap ordinary externrefs while delegating encoded guest-object references to the opaque path.
    if (type === 6) return bits & 0xc0000000n ? decodedValue(bits, 8) : externalValues[Number(bits)];

    // Decode managed references through generation-bound host wrappers.
    if (type >= 8) {
      // Preserve the guest null-reference value at the host boundary.
      if (bits === 0n) return null;

      // Recover an external value that was wrapped as a guest anyref.
      if (type === 8 && (bits & 0xe0000000n) === 0x20000000n) return externalValues[Number(bits & 0x1fffffffn)];

      const key = `${type}:${bits}`;
      let reference = opaqueReferences.get(key)?.deref();

      // Create and pin a wrapper only when this guest object has no live cached host handle.
      if (!reference) {
        reference = Object.freeze({});

        opaqueReferences.set(key, new WeakRef(reference));
        opaqueReferenceValues.set(reference, { bits, type, generation });
        e.gc_pin(bits, 1);
      }

      return reference;
    }

    const view = new DataView(new ArrayBuffer(8));

    view.setBigInt64(0, bits, true);

    return type === 3 ? view.getFloat32(0, true) : view.getFloat64(0, true);
  }

  // Validate and encode a host value for a declared guest value kind.
  function typedValue(/** @type {number | bigint} */ value, /** @type {number} */ type) {
    // Encode vectors as raw 128-bit patterns rather than scalar numeric values.
    if (type === 7) {
      // Reject vector values that cannot be represented without losing bits.
      if (typeof value !== 'bigint' || value < -(1n << 127n) || value > (1n << 128n) - 1n)
        throw new Error('value must be a v128 BigInt bit pattern');

      return BigInt.asUintN(128, value);
    }

    // Validate i32 values before translating them into the guest's 64-bit host slot.
    if (type === 1) {
      i32(/** @type {number} */ (value));

      return BigInt(value);
    }

    // Encode function references through their provider's typed forwarding metadata.
    if (type === 5) {
      // Encode a null function reference as the guest null slot.
      if (value === null) return 0n;

      const metadata = functionTypes.get(value);

      // Reject stale or untyped functions before interning a guest forwarding binding.
      if (!metadata?.reference || !metadata.valid())
        throw new Error('value must be a live wiw function reference or null');

      return BigInt(tableFunctionIndex(metadata.reference()) + 1);
    }

    // Intern ordinary host values as external references while preserving their identity.
    if (type === 6) {
      // Encode a null external reference without allocating a host reference ID.
      if (value === null) return 0n;

      const opaque = opaqueReferenceValues.get(value);

      // Retain the original guest object when an anyref wrapper is passed through an externref slot.
      if (opaque?.type === 8) {
        // Prevent guest-object handles from surviving a reload into a different heap.
        if (opaque.generation !== generation) throw new Error('stale opaque wiw reference');

        return opaque.bits;
      }

      const key = Object.is(value, -0) ? negativeZeroKey : value;

      // Allocate one external reference ID per distinct host value.
      if (!externalIds.has(key)) {
        // Respect the configured external-reference capacity before allocating a new ID.
        if (externalValues.length > limits.externalReferences) throw new Error('external reference resource limit');

        externalIds.set(key, externalValues.length);
        externalValues.push(value);
      }

      return BigInt(externalIds.get(key));
    }

    // Encode managed guest references while retaining their generation and heap ownership.
    if (type >= 8) {
      // Encode null managed references without requiring an opaque wrapper.
      if (value === null) return 0n;

      const reference = opaqueReferenceValues.get(value);

      // Wrap ordinary host values as external anyrefs when no guest object handle exists.
      if (!reference && type === 8) return typedValue(value, 6) | 0x20000000n;

      // Reject references from another generation or with an incompatible managed kind.
      if (!reference || reference.type !== type || reference.generation !== generation)
        throw new Error('value must be a live opaque wiw reference or null');

      return reference.bits;
    }

    // Encode floating-point arguments through a DataView to preserve their guest-width rounding.
    if (type === 3 || type === 4) {
      // Reject implicit coercion of nonnumeric host values into guest floats.
      if (typeof value !== 'number') throw new Error(`value must be an ${scalarNames[type]} Number`);

      const view = new DataView(new ArrayBuffer(8));

      // Round f32 arguments at their declared width rather than first retaining an f64 encoding.
      if (type === 3) view.setFloat32(0, value, true);
      else view.setFloat64(0, value, true);

      return view.getBigInt64(0, true);
    }

    // Require an exact i64 BigInt bit pattern before writing the guest slot.
    if (typeof value !== 'bigint' || value < -(1n << 63n) || value > (1n << 64n) - 1n) {
      throw new Error('value must be an i64 BigInt integer');
    }

    return value;
  }

  // Resolve an exported function and read its parameter and result kinds.
  function functionSignature(/** @type {string} */ name, includeResults = true) {
    requireLoaded();

    const at = e.host_base();
    const n = write(name, at);
    const index = e.export_function(at, n);

    check(e.error_code());

    return { index, ...signatureAt(index, includeResults) };
  }

  // Reference descriptors carry opaque values; numeric descriptors retain exact bits.
  function rawResult(bits, type) {
    return isHostReference(type)
      ? {
          type: scalarNames[type],
          value: decodedValue(bits, type),
          ...(type === 8
            ? {
                heap:
                  bits === 0n
                    ? null
                    : bits & 0x80000000n
                    ? 'i31'
                    : bits & 0x40000000n
                    ? e.reference_category(e.object_type(bits)) === 22
                      ? 'struct'
                      : 'array'
                    : 'any'
              }
            : {})
        }
      : { type: scalarNames[type], bits: BigInt.asUintN(type === 7 ? 128 : type === 1 || type === 3 ? 32 : 64, bits) };
  }

  // Validate a raw argument slot and normalize its width without decoding it.
  function rawSlot(arg, type) {
    // Require raw slots to match the declared guest kind.
    if (arg.type !== scalarNames[type]) throw new Error('raw argument type mismatch');

    // Validate raw references through opaque values rather than accepting forged pointer bits.
    if (isHostReference(type)) {
      // Require an actual reference value in a raw reference slot.
      if (!Object.hasOwn(arg, 'value')) throw new Error('raw reference requires an opaque value');

      return typedValue(arg.value, type);
    }

    // Require BigInt bits so raw scalar arguments cannot lose integer precision.
    if (typeof arg.bits !== 'bigint') throw new Error('raw argument type mismatch');

    return type === 7 ? BigInt.asUintN(128, arg.bits) : BigInt.asIntN(64, arg.bits);
  }
  // Shared state is synchronized at each synchronous guest/host boundary.

  // Type graphs retain nullability and structural heap signatures across independent instances.
  function typeDescription(type, heaps = new Map()) {
    const kind = e.value_kind(type);

    // Numeric value types need no heap graph or nullability metadata.
    if (!isHostReference(kind)) return { kind };

    const result = { kind, nonnull: Boolean(e.type_nonnull(type)), heap: e.reference_category(type) };
    const index = e.type_heap(type);

    // Abstract reference categories have no concrete heap definition to traverse.
    if (index < 0) return result;

    // Describe a recursive heap type while preserving cycles and group identity.
    const describeHeap = (index) => {
      // Reuse previously described heaps to terminate cycles and preserve recursive group identity.
      if (heaps.has(index)) return heaps.get(index);

      const view = new DataView(e.memory.buffer, memoryOffset);
      const at = e.heap_info(index);
      const heap = {
        index,
        kind: view.getInt32(at, true),
        final: view.getInt32(at + 12, true),
        group: [],
        params: [],
        results: [],
        fields: []
      };

      heaps.set(index, heap);

      const start = view.getInt32(at + 4, true),
        count = view.getInt32(at + 8, true);

      heap.position = index - start;

      const parent = view.getInt32(at + 16, true);

      heap.parent = parent < 0 ? null : typeDescription(parent, heaps).heap;

      // Describe function heap members through their parameter and result signatures.
      if (heap.kind === 0) {
        heap.params = Array.from({ length: e.heap_params(index) }, (_, slot) =>
          typeDescription(e.heap_param_type(index, slot), heaps)
        );
        heap.results = Array.from({ length: e.heap_results(index) }, (_, slot) =>
          typeDescription(e.heap_result_type(index, slot), heaps)
        );
      } else {
        // Describe aggregate heap members through their field types and mutability.
        const first = view.getInt32(at + 20, true),
          length = view.getInt32(at + 24, true);

        // Describe every aggregate field with its type and mutability.
        heap.fields = Array.from({ length }, (_, slot) => {
          const field = e.field_info(first + slot);

          return { type: typeDescription(view.getInt32(field, true), heaps), mutable: view.getInt32(field + 4, true) };
        });
      }

      heap.group = Array.from({ length: count }, (_, slot) => describeHeap(start + slot));

      return heap;
    };

    result.heap = describeHeap(index);

    return result;
  }

  // Recursive group references compare by their relative positions within paired groups.
  function equalHeap(actual, expected, contexts = []) {
    // Compare abstract heap categories directly instead of traversing nonexistent concrete definitions.
    if (typeof actual === 'number' || typeof expected === 'number') return actual === expected;

    // Consult paired recursive groups before recursing into their members again.
    for (const [left, right] of contexts) {
      const a = left.indexOf(actual),
        b = right.indexOf(expected);

      // Resolve recursive backreferences by their relative positions within the paired groups.
      if (a >= 0 || b >= 0) return a === b && a >= 0;
    }

    // Reject recursive groups with incompatible sizes or member positions.
    if (actual.position !== expected.position || actual.group.length !== expected.group.length) return false;

    contexts.push([actual.group, expected.group]);

    // Compare value kind, nullability and heap type within paired recursive groups.
    const sameType = (a, b) =>
      a.kind === b.kind && a.nonnull === b.nonnull && (!isHostReference(a.kind) || equalHeap(a.heap, b.heap, contexts));

    // Compare each corresponding type in two parameter or result lists.
    const sameVector = (a, b) => a.length === b.length && a.every((type, slot) => sameType(type, b[slot]));
    // Compare corresponding recursive group members, including signatures and aggregate fields.
    const result = actual.group.every((a, slot) => {
      const b = expected.group[slot];

      return (
        a.kind === b.kind &&
        a.final === b.final &&
        Boolean(a.parent) === Boolean(b.parent) &&
        (!a.parent || equalHeap(a.parent, b.parent, contexts)) &&
        sameVector(a.params, b.params) &&
        sameVector(a.results, b.results) &&
        a.fields.length === b.fields.length &&
        a.fields.every((field, i) => field.mutable === b.fields[i].mutable && sameType(field.type, b.fields[i].type))
      );
    });

    contexts.pop();

    return result;
  }

  // Check whether an imported resource type satisfies the required guest type.
  function compatibleType(actual, expected) {
    // Numeric imports require an exact value-kind match.
    if (!isHostReference(expected.kind)) return actual.kind === expected.kind;

    // Reject nonreference inputs and nullable providers for nonnull reference requirements.
    if (!isHostReference(actual.kind) || (expected.nonnull && !actual.nonnull)) return false;

    // Match an abstract heap requirement against the provider's concrete or abstract category.
    if (typeof expected.heap === 'number') {
      const category =
        typeof actual.heap === 'number' ? actual.heap : actual.heap.kind === 0 ? 5 : actual.heap.kind === 1 ? 22 : 24;

      // Accept an exact abstract category match immediately.
      if (category === expected.heap) return true;

      // Allow the null-only none type wherever a nullable internal heap reference is expected.
      if (category === 26) return [16, 18, 20, 22, 24].includes(expected.heap);

      // Allow the null-only nofunc type to satisfy a nullable function-reference requirement.
      if (category === 28) return expected.heap === 5;

      // Allow the null-only noextern type to satisfy a nullable external-reference requirement.
      if (category === 30) return expected.heap === 6;

      // Allow the null-only noexn type to satisfy a nullable exception-reference requirement.
      if (category === 34) return expected.heap === 32;

      return (
        (expected.heap === 16 && [18, 20, 22, 24].includes(category)) ||
        (expected.heap === 18 && [20, 22, 24].includes(category))
      );
    }

    // A null-only provider can satisfy the corresponding nullable concrete heap requirement.
    if (typeof actual.heap === 'number') return actual.heap === (expected.heap.kind === 0 ? 28 : 26);

    // Walk the provider's declared heap ancestors to find the required structural supertype.
    for (let heap = actual.heap; heap; heap = heap.parent)
      // Accept the first structurally equivalent heap in the provider's ancestry.
      if (equalHeap(heap, expected.heap)) return true;

    return false;
  }

  // Import the latest memory, global and table state from shared host resource handles.
  function synchronizeIn() {
    // Import the latest state of each bound memory, global or table before guest execution.
    for (const binding of resources) {
      const state = binding.state;

      // Tags carry stable identity and require no mutable resource snapshot.
      if (state.kind === 4) continue;

      // Reject resource bindings whose provider has been reloaded.
      if (!state.valid()) throw new Error('stale resource binding');

      // Copy shared host memory contents after bringing the guest's logical size up to date.
      if (state.kind === 1) {
        const delta = state.pages - e.memory_pages(binding.index);

        // Reject imported growth that cannot fit this interpreter's configured memory capacity.
        if (delta > 0 && e.grow_memory(binding.index, delta) < 0)
          throw new Error('shared memory growth exceeds capacity');

        new Uint8Array(e.memory.buffer, memoryOffset + e.memory_base(binding.index), state.bytes.length).set(
          state.bytes
        );
      } else if (state.kind === 2) {
        // Translate shared global values into the guest's scalar or reference representation.
        const bits = isHostReference(state.type) ? typedValue(state.value, state.type) : state.bits;
        const view = new DataView(e.memory.buffer, memoryOffset),
          at = e.global_info(binding.index);

        view.setBigInt64(at + 24, BigInt.asIntN(64, bits), true);
        view.setBigInt64(at + 72, state.type === 7 ? BigInt.asIntN(64, bits >> 64n) : 0n, true);
      } else {
        // Import the latest shared table size and element references.
        const delta = state.entries.length - e.table_size(binding.index);

        // Reject imported table growth that cannot fit this interpreter's configured table capacity.
        if (delta > 0 && e.grow_guest_table(binding.index, delta) < 0)
          throw new Error('shared table growth exceeds capacity');

        // Import each shared table element after checking reference compatibility.
        state.entries.forEach((entry, index) => {
          const target =
            state.type === 5 ? (entry ? tableFunctionIndex(entry) : -1) : Number(typedValue(entry, state.type)) - 1;

          // Validate managed table references before writing instance-owned object handles.
          if (state.type >= 8) {
            const accepts = e.table_accepts(binding.index, BigInt((target + 1) >>> 0));

            check(e.error_code());

            // Reject foreign managed objects that fail the destination table's type and ownership checks.
            if (!accepts)
              throw new Error('shared table element type mismatch; managed references belong to their interpreter');
          }

          new DataView(e.memory.buffer, memoryOffset).setInt32(e.table_base(binding.index) + index * 4, target, true);
        });
      }
    }
  }

  // Publish guest memory, global and table changes to shared host resource handles.
  function synchronizeOut() {
    // Publish each bound resource after guest execution or an import boundary.
    for (const binding of resources) {
      const state = binding.state;

      // Skip immutable tag identities when publishing mutable resource state.
      if (state.kind === 4) continue;

      // Publish the memory's current logical size and complete byte image.
      if (state.kind === 1) {
        state.pages = e.memory_pages(binding.index);
        state.bytes = new Uint8Array(
          e.memory.buffer,
          memoryOffset + e.memory_base(binding.index),
          state.pages * 65536
        ).slice();
      } else if (state.kind === 2) {
        // Publish global bits and decode reference-valued globals for other instances.
        state.bits = new DataView(e.memory.buffer, memoryOffset).getBigInt64(e.global_info(binding.index) + 24, true);

        // Include the upper 64 bits when publishing a vector global.
        if (state.type === 7)
          state.bits =
            BigInt.asUintN(64, state.bits) |
            (BigInt.asUintN(
              64,
              new DataView(e.memory.buffer, memoryOffset).getBigInt64(e.global_info(binding.index) + 72, true)
            ) <<
              64n);

        // Retain host reference identity rather than publishing an instance-local pointer.
        if (isHostReference(state.type)) state.value = decodedValue(state.bits, state.type);
      }
      // Snapshot each guest table element into its shared host representation.
      else
        state.entries = Array.from({ length: e.table_size(binding.index) }, (_, index) => {
          const target = new DataView(e.memory.buffer, memoryOffset).getInt32(
            e.table_base(binding.index) + index * 4,
            true
          );

          return state.type === 5
            ? target < 0
              ? null
              : functionReference(target)
            : decodedValue(BigInt((target + 1) >>> 0), state.type);
        });
    }
  }

  // Read the result kind or kinds of a guest function.
  function resultSignature(index) {
    const count = e.function_results(index);

    return count <= 1
      ? e.function_result_type(index, 0)
      : Array.from({ length: count }, (_, slot) => e.function_result_type(index, slot));
  }

  // Copy a fresh bulk snapshot before later ABI calls reuse its host scratch bytes.
  function signatureAt(index, includeResults = true) {
    // Direct native calls are cheaper than filling scratch; bulk queries target interpreted forwarding.
    if (!ensureMemory)
      return {
        params: Array.from({ length: e.function_params(index) }, (_, slot) => e.function_param_type(index, slot)),
        results: includeResults ? resultSignature(index) : undefined
      };

    const at = e.function_signature(index, includeResults ? 1 : 0);

    // Translate a failed bulk signature query before attempting to read its scratch buffer.
    if (!at) check(e.error_code());

    const view = new DataView(e.memory.buffer, memoryOffset);
    const count = view.getUint32(at, true),
      results = view.getUint32(at + 4, true);
    const params = Array.from({ length: count }, (_, slot) => view.getUint32(at + 8 + slot * 4, true));
    const types = includeResults
      ? Array.from({ length: results }, (_, slot) => view.getUint32(at + 8 + (count + slot) * 4, true))
      : [];

    return { params, results: includeResults ? (results > 1 ? types : types[0] ?? 0) : undefined };
  }

  // Create or reuse a typed forwarding wrapper for a guest function.
  function functionReference(index) {
    // Reuse an existing function wrapper to preserve host reference identity.
    if (tableFunctions.has(index)) return tableFunctions.get(index);

    const descriptor = e.function_info(index),
      view = new DataView(e.memory.buffer, memoryOffset);

    // Recover the provider's reference when this guest function is itself an imported forwarding binding.
    if (view.getInt32(descriptor + 8, true) === -1) {
      const binding = bindings[view.getInt32(descriptor + 12, true)];
      const forwarding = binding && functionTypes.get(binding.callback);

      // Reuse the original provider reference instead of adding another forwarding hop.
      if (forwarding?.reference) {
        const reference = forwarding.reference();

        tableFunctions.set(index, reference);

        return reference;
      }
    }

    const signature = signatureAt(index),
      currentGeneration = generation;

    // Check that a forwarding handle still belongs to the current loaded generation.
    const valid = () => e.segments_ready() && generation === currentGeneration;

    // Forward decoded arguments to the referenced guest function.
    const callback = (...args) => {
      reentryOwner(false);

      // Prevent cached callbacks from invoking a reloaded guest.
      if (!valid()) throw new Error('stale forwarded function');

      // Bound cross-instance forwarding depth before entering another guest call.
      if (backend.countsForwardingDepth && currentDepth() >= limits.forwardingDepth)
        throw new Error('forwarding depth limit');

      // Validate argument arity before preparing forwarded guest values.
      if (args.length !== signature.params.length) throw new Error('argument mismatch');

      return invokeValues(
        '',
        args.map((value, slot) => typedValue(value, signature.params[slot])),
        false,
        index
      );
    };

    // Run the operation with raw typed arguments and results.
    const raw = (args) => {
      reentryOwner(false);

      // Prevent raw callbacks from invoking a reloaded guest.
      if (!valid()) throw new Error('stale forwarded function');

      // Bound cross-instance forwarding depth for raw synchronous calls.
      if (backend.countsForwardingDepth && currentDepth() >= limits.forwardingDepth)
        throw new Error('forwarding depth limit');

      return invokeValues(
        '',
        args.map((arg, slot) => rawSlot(arg, signature.params[slot])),
        true,
        index
      );
    };

    // Forward raw typed arguments while awaiting asynchronous guest imports.
    const rawAsync = async (args) => {
      reentryOwner(true);

      // Prevent asynchronous raw callbacks from invoking a reloaded guest.
      if (!valid()) throw new Error('stale forwarded function');

      // Bound cross-instance forwarding depth before asynchronous guest forwarding.
      if (backend.countsForwardingDepth && currentDepth() >= limits.forwardingDepth)
        throw new Error('forwarding depth limit');

      return invokeValues(
        '',
        args.map((arg, slot) => rawSlot(arg, signature.params[slot])),
        true,
        index,
        true
      );
    };

    functionTypes.set(callback, { ...signature, valid, raw, rawAsync, reference: () => reference });

    const reference = { owner, index, callback: exportedFunctions.get(index) ?? callback, signature };

    tableFunctions.set(index, reference);

    return reference;
  }

  // Resolve a function reference, interning foreign forwarding bindings when needed.
  function tableFunctionIndex(reference) {
    // Reuse local function indices without allocating a foreign forwarding entry.
    if (reference.owner === owner) return reference.index;

    // Reuse an already interned foreign function so table updates retain reference identity.
    if (foreignFunctions.has(reference)) return foreignFunctions.get(reference);

    const { params, results } = reference.signature;
    const at = e.host_base();

    ensure(at + params.length * 4);
    new Uint32Array(e.memory.buffer, memoryOffset + at, params.length).set(params);

    const slot = bindings.length;
    const index = e.foreign_function(params.length, Array.isArray(results) ? results[0] : results, at, slot);

    // Publish all result kinds for foreign functions with multiple results.
    if (index >= 0 && Array.isArray(results)) {
      ensure(at + results.length * 4);
      new Uint32Array(e.memory.buffer, memoryOffset + at, results.length).set(results);
      check(e.foreign_results(index, at, results.length));
    }

    check(e.error_code());
    bindings.push({ module: '<table>', name: String(reference.index), params, results, callback: reference.callback });
    foreignFunctions.set(reference, index);
    tableFunctions.set(index, reference);

    return index;
  }

  // Create or reuse a generation-bound handle for an exported resource.
  function exportResource(index, kind) {
    const key = `${kind}:${index}`;

    // Preserve identity by returning a cached resource handle for this export.
    if (exportedResources.has(key)) return exportedResources.get(key);

    const imported = resources.find((binding) => binding.index === index && binding.state.kind === kind);
    let state = imported?.state;

    // Reuse the original host handle when a guest reexports an imported resource.
    if (state?.handle) {
      exportedResources.set(key, state.handle);

      return state.handle;
    }

    // Snapshot a newly exported local resource with a validity guard for this load generation.
    if (!state) {
      const currentGeneration = generation;

      state = { kind, valid: () => loaded && generation === currentGeneration };

      // Retain the tag's stable identity and structural payload signature.
      if (kind === 4)
        Object.assign(state, {
          identity: new DataView(e.memory.buffer, memoryOffset).getInt32(e.tag_info(index) + 16, true),
          descriptor: typeDescription(e.tag_type(index))
        });
      // Retain memory limits, address width and the current byte image for future imports.
      else if (kind === 1)
        Object.assign(state, {
          addressType: e.memory_width(index),
          pages: e.memory_pages(index),
          maximum: e.memory_maximum(index),
          bytes: new Uint8Array(
            e.memory.buffer,
            memoryOffset + e.memory_base(index),
            e.memory_pages(index) * 65536
          ).slice()
        });
      else if (kind === 2) {
        // Retain global mutability, type and current bits for future imports.
        const view = new DataView(e.memory.buffer, memoryOffset),
          at = e.global_info(index);

        Object.assign(state, {
          type: e.value_kind(view.getInt32(at + 12, true)),
          descriptor: typeDescription(view.getInt32(at + 12, true)),
          mutable: view.getInt32(at + 8, true),
          bits: view.getBigInt64(at + 24, true)
        });

        // Preserve the upper half of an exported vector global.
        if (state.type === 7)
          state.bits = BigInt.asUintN(64, state.bits) | (BigInt.asUintN(64, view.getBigInt64(at + 72, true)) << 64n);

        // Retain reference-valued global identity through a host wrapper.
        if (isHostReference(state.type)) state.value = decodedValue(state.bits, state.type);
      } else
        Object.assign(state, {
          addressType: e.table_address_type(index),
          type: e.table_type(index),
          descriptor: typeDescription(
            new DataView(e.memory.buffer, memoryOffset).getInt32(e.table_info(index) + 16, true)
          ),
          maximum: e.table_max(index),
          // Retain the initial table contents as generation-bound host references.
          entries: Array.from({ length: e.table_size(index) }, (_, slot) => {
            const target = new DataView(e.memory.buffer, memoryOffset).getInt32(e.table_base(index) + slot * 4, true);

            return e.table_type(index) === 5
              ? target < 0
                ? null
                : functionReference(target)
              : decodedValue(BigInt((target + 1) >>> 0), e.table_type(index));
          })
        });

      resources.push({ index, state });
    }

    const handle = Object.freeze({ kind: ['function', 'memory', 'global', 'table', 'tag'][kind] });

    resourceTypes.set(handle, state);
    exportedResources.set(key, handle);

    return handle;
  }

  // The synchronous runner never yields; async imports resume this same state machine.
  function drive(value, raw = false) {
    return driveSteps(value, raw, false).next().value;
  }

  // Run guest execution while awaiting imports and preserving opaque reference values.
  async function driveAsync(value, raw = false) {
    const steps = driveSteps(value, raw, true);
    let step = steps.next();

    // Continue driving the guest until its imports and final result have completed.
    while (!step.done) {
      let returned;

      // Await the pending host operation before resuming the generator with its result.
      try {
        returned = await step.value;
      } catch (error) {
        // Feed a rejected host operation back into the guest driver so normal failure handling runs.
        step = steps.throw(error);
        continue;
      }

      step = steps.next(returned);
    }

    return { value: step.value };
  }

  // Yield pending imports and resume guest execution with translated results or exceptions.
  function* driveSteps(/** @type {bigint} */ value, raw, asynchronous) {
    // Service each pending guest import before resuming instruction execution.
    while (e.pending_import() >= 0) {
      const binding = bindings[e.pending_import()];
      let result = 0n;
      /** @type {unknown} */
      let failure;
      let failed = false;

      // Capture argument conversion and callback failures for translation through the guest import ABI.
      try {
        const view = new DataView(e.memory.buffer, memoryOffset);
        const at = e.pending_args();
        const pendingHigh = e.pending_high_args();
        // Read each pending import argument without losing vector halves or reference identity.
        const rawArgs = binding.params.map((type, index) => {
          let bits = view.getBigInt64(at + index * 8, true);

          // Combine both argument halves before forwarding a vector import.
          if (type === 7)
            bits =
              BigInt.asUintN(64, bits) | (BigInt.asUintN(64, view.getBigInt64(pendingHigh + index * 8, true)) << 64n);

          return rawResult(bits, type);
        });
        const args = rawArgs.map((value, index) =>
          isHostReference(binding.params[index]) ? value.value : decodedValue(value.bits, binding.params[index])
        );

        synchronizeOut();

        const forwarding = functionTypes.get(binding.callback);
        const forward = asynchronous && forwarding?.rawAsync ? forwarding.rawAsync : forwarding?.raw;
        // Promise externrefs are ordinary values unless the binding explicitly opts into awaiting.
        const awaitable =
          binding.results !== 6 || asynchronousImports.has(binding.callback) || (asynchronous && forwarding?.rawAsync);
        let returned;
        const scope = {
          backend,
          invocation: activeInvocation,
          asynchronous,
          active: true,
          children: new Set(),
          parent: callbackContext.getStore()
        };

        // Run the callback inside its reentry scope and deactivate that scope on every exit path.
        try {
          returned = callbackContext.run(scope, () => (forward ? forward(rawArgs) : binding.callback(...args)));

          // Await promises only for imports whose ABI opts into asynchronous completion.
          if (asynchronous && awaitable && returned && typeof returned.then === 'function') returned = yield returned;
        } finally {
          // Deactivate the callback scope before joining children and importing their resource effects.
          scope.active = false;

          // Even an unawaited nested call must finish before its caller can resume the guest.
          if (asynchronous && scope.children.size) yield Promise.allSettled([...scope.children]);

          // Import side effects remain visible even when a rejected guest exception enters a handler.
          synchronizeIn();
        }

        // Reject asynchronous callback results when the caller selected synchronous invocation.
        if (!asynchronous && awaitable && returned && typeof returned.then === 'function') {
          // Consume rejected promises while rejecting asynchronous callbacks for this synchronous ABI.
          Promise.resolve(returned).catch(() => {});

          throw new Error('import callbacks must be synchronous');
        }

        const resultCount = Array.isArray(binding.results) ? binding.results.length : binding.results ? 1 : 0;

        // Check result capacity before writing into the guest's shared operand arena.
        if (resultCount && resultCount > e.pending_result_capacity()) throw new Error('operand stack resource limit');

        // Validate and publish all slots of a multi-value import result.
        if (Array.isArray(binding.results)) {
          // Require the returned array to have exactly the import's declared result arity.
          if (!Array.isArray(returned) || returned.length !== binding.results.length)
            throw new Error('import result count mismatch');

          const slots = returned.map((value, slot) =>
            forward ? rawSlot(value, binding.results[slot]) : typedValue(value, binding.results[slot])
          );
          const resultAt = e.pending_args();

          ensure(resultAt + slots.length * 8);

          const output = new DataView(e.memory.buffer, memoryOffset);

          // Write each multi-value import result into its low and high guest slots.
          slots.forEach((value, slot) => {
            output.setBigInt64(resultAt + slot * 8, BigInt.asIntN(64, value), true);
            output.setBigInt64(
              e.pending_high_args() + slot * 8,
              binding.results[slot] === 7 ? BigInt.asIntN(64, value >> 64n) : 0n,
              true
            );
          });

          result = slots[0];
        } else if (binding.results) {
          // Encode the single declared import result; void imports leave the result slot unused.
          result = forward ? rawSlot(returned, binding.results) : typedValue(returned, binding.results);

          // Publish a vector result's upper half in the separate high-slot ABI.
          if (binding.results === 7) {
            new DataView(e.memory.buffer, memoryOffset).setBigInt64(
              e.pending_high_args(),
              BigInt.asIntN(64, result >> 64n),
              true
            );

            result = BigInt.asIntN(64, result);
          }
        }
      } catch (error) {
        // Retain callback failures so guest resumption can trap or enter an exception handler.
        failure = error;
        failed = true;
      }

      // Guest exceptions retain their tag identity and unwind through the caller's own handlers.
      if (failed && exceptionTypes.has(failure)) {
        value = e.resume_exception(importException(failure));

        check(e.error_code());
        continue;
      }

      // The scalar ABI carries only the low 64 bits; vector high bits live in their separate slots.
      value = e.resume64(BigInt.asIntN(64, result), failed ? 1 : 0);

      // Attach the import name, source offset and original cause to ordinary host failures.
      if (failed) {
        const error = new Error(
          `host import ${binding.module}.${binding.name} failed at byte ${Math.max(0, e.error_offset() - 4096)}`
        );

        Object.defineProperty(error, 'cause', { value: failure });

        throw error;
      }

      check(e.error_code());
    }

    check(e.error_code());

    // The bootstrap avoids scratch metadata work when its native queries cross no interpreted boundary.
    if (!ensureMemory) {
      const count = e.result_count();

      // Decode each slot when the guest export returns multiple values.
      if (count > 1) {
        const view = new DataView(e.memory.buffer, memoryOffset),
          at = e.result_base();

        // Decode each returned result slot according to its guest kind.
        return Array.from({ length: count }, (_, slot) => {
          let bits = view.getBigInt64(at + slot * 8, true);
          const type = e.result_type(slot);

          // Combine both halves before decoding a vector in a multi-value result.
          if (type === 7)
            bits = BigInt.asUintN(64, bits) | (view.getBigUint64(e.result_high_base() + slot * 8, true) << 64n);

          return raw ? rawResult(bits, type) : decodedValue(bits, type);
        });
      }

      const type = e.result_type(0);

      // Combine the high half before decoding a single vector result.
      if (type === 7)
        value =
          BigInt.asUintN(64, value) |
          (new DataView(e.memory.buffer, memoryOffset).getBigUint64(e.result_high_base(), true) << 64n);

      return raw ? rawResult(value, type) : decodedValue(value, type);
    }

    const info = e.result_info();

    // Translate a failed bulk result query before reading its scratch descriptor.
    if (!info) check(e.error_code());

    const output = new DataView(e.memory.buffer, memoryOffset);
    const resultCount = output.getUint32(info, true),
      at = output.getUint32(info + 4, true),
      highAt = output.getUint32(info + 8, true);
    // Copy kinds and bits before decoding references can issue further metadata queries.
    const types = Array.from({ length: Math.max(1, resultCount) }, (_, slot) =>
      output.getUint32(info + 12 + slot * 4, true)
    );

    // Preserve each typed raw slot when an export has multiple results.
    if (resultCount > 1) {
      // Retain each raw result slot without converting floating-point values.
      const bits = Array.from({ length: resultCount }, (_, slot) => {
        const low = output.getBigInt64(at + slot * 8, true);

        return types[slot] === 7
          ? BigInt.asUintN(64, low) | (output.getBigUint64(highAt + slot * 8, true) << 64n)
          : low;
      });

      return bits.map((bits, slot) => (raw ? rawResult(bits, types[slot]) : decodedValue(bits, types[slot])));
    }

    const resultType = types[0];

    // Restore all 128 bits of a single raw vector result.
    if (resultType === 7) value = BigInt.asUintN(64, value) | (output.getBigUint64(highAt, true) << 64n);

    return raw ? rawResult(value, resultType) : decodedValue(value, resultType);
  }

  // Run either public scalar values or exact raw slots through the same protected invocation.
  function invokeValues(name, values, raw = false, index = undefined, asynchronous = false) {
    const ownerScope = reentryOwner(asynchronous);
    const previousInvocation = activeInvocation;
    const nested = invoking;

    // Save the suspended guest state before entering a callback-owned nested invocation.
    if (nested) check(e.begin_reentry(index));

    activeInvocation = {};
    invoking = true;

    let at, n, argumentsAt;

    // Prepare arguments and backing memory while retaining a recovery path for partial failure.
    try {
      synchronizeIn();

      refreshHostRoots();

      at = e.host_base();
      // Indexed calls already resolved their export and need no second name write.
      n = index === undefined ? write(name, at) : 0;
      argumentsAt = Math.ceil((at + n) / 8) * 8;

      ensure(argumentsAt + values.length * 8);

      const view = new DataView(e.memory.buffer, memoryOffset);
      const highAt = values.length ? e.argument_high_base() : 0;

      // Write each prepared argument into the guest invocation buffers.
      values.forEach((value, index) => {
        view.setBigInt64(argumentsAt + index * 8, BigInt.asIntN(64, value), true);
        view.setBigInt64(highAt + index * 8, value > 0n ? BigInt.asIntN(64, value >> 64n) : 0n, true);
      });
    } catch (error) {
      // Restore the previous invocation if preparing the nested call fails.
      // Unwind the synthetic reentry boundary created for the failed nested call.
      if (nested) check(e.end_reentry());

      activeInvocation = previousInvocation;
      invoking = !!previousInvocation;

      throw error;
    }

    // Restore invocation ownership and saved execution state after completion or failure.
    const cleanup = () => {
      // Publish resource changes and abort any remaining suspended import before restoring ownership.
      try {
        // Cancel a still-pending import so the engine cannot remain suspended after cleanup.
        if (e.pending_import() >= 0) e.resume64(0n, 1);

        synchronizeOut();
      } finally {
        // Restore the caller's suspended frames after the nested invocation ends.
        if (nested) check(e.end_reentry());

        activeInvocation = previousInvocation;
        invoking = !!previousInvocation;
      }
    };

    // Enter the prepared guest function by export name or resolved function index.
    const start = () =>
      index === undefined
        ? e.invoke64(at, n, argumentsAt, values.length)
        : e.invoke_index64(index, argumentsAt, values.length);

    // Use the asynchronous driver and retain the callback-owned completion obligation.
    if (asynchronous) {
      const depth = currentDepth() + (backend.countsForwardingDepth ? 1 : 0);
      // Track guest completion separately from public Promise assimilation of an externref result.
      const completion = invocationContext.run(depth, async () => {
        // Run the awaited guest call while guaranteeing invocation cleanup.
        try {
          return await driveAsync(start(), raw);
        } finally {
          // Restore invocation state whether the asynchronous guest call returns or throws.
          cleanup();
        }
      });

      // Track nested completion so an unawaited child cannot outlive its outer callback.
      if (ownerScope) {
        ownerScope.children.add(completion);
        completion.then(
          () => ownerScope.children.delete(completion),
          () => ownerScope.children.delete(completion)
        );
      }

      return completion.then((result) => result.value);
    }

    // Execute the prepared operation within its invocation context.
    const run = () => {
      // Guarantee cleanup even when synchronous guest execution traps.
      try {
        return drive(start(), raw);
      } finally {
        // Restore invocation state whether the synchronous guest call returns or traps.
        cleanup();
      }
    };

    return backend.countsForwardingDepth ? invocationContext.run(currentDepth() + 1, run) : run();
  }

  // Validate decoded host arguments against the export signature before invocation.
  function invokePublic(name, args, asyncInvocation) {
    reentryOwner(asyncInvocation);
    requireLoaded();

    // Bound forwarding depth before decoding public invocation arguments.
    if (backend.countsForwardingDepth && currentDepth() >= limits.forwardingDepth)
      throw new Error('forwarding depth limit');

    // Reject argument lists larger than the configured parameter arena.
    if (args.length > limits.parameters) throw new Error(`too many arguments (maximum ${limits.parameters})`);

    const signature = functionSignature(name, false);

    // Require the export's exact parameter arity before converting arguments.
    if (args.length !== signature.params.length) throw new Error('argument mismatch');

    // Validate each decoded argument and attach a useful type error on failure.
    const values = args.map((arg, index) => {
      // Convert each argument using the guest's declared value kind.
      try {
        return typedValue(arg, signature.params[index]);
      } catch (error) {
        // Preserve reference diagnostics while adding useful scalar argument-type messages.
        // Keep precise reference ownership and liveness errors instead of replacing them with scalar diagnostics.
        if (signature.params[index] >= 5) throw error;

        throw new Error(
          signature.params[index] === 2
            ? 'arguments must be i64 BigInt integers'
            : signature.params[index] === 1
            ? 'arguments must be i32 integers'
            : `arguments must be ${scalarNames[signature.params[index]]} Numbers`
        );
      }
    });

    return invokeValues('', values, false, signature.index, asyncInvocation);
  }

  // Validate raw value slots against the export signature before invocation.
  function invokeRawPublic(name, args, asyncInvocation) {
    reentryOwner(asyncInvocation);
    requireLoaded();

    // Bound forwarding depth before preparing a raw public invocation.
    if (backend.countsForwardingDepth && currentDepth() >= limits.forwardingDepth)
      throw new Error('forwarding depth limit');

    const signature = functionSignature(name, false);

    // Require the raw argument count to match the export signature.
    if (args.length !== signature.params.length) throw new Error('argument mismatch');

    // Normalize each raw argument to its declared guest kind.
    const values = args.map((arg, index) => {
      return rawSlot(arg, signature.params[index]);
    });

    return invokeValues('', values, true, signature.index, asyncInvocation);
  }
  const api = {
    // Resource adapters bind to this revision and reject reuse after load/validation attempts.
    get generation() {
      return generation;
    },

    // Parse and validate a module without imports, resource allocation, segment effects or start execution.
    validate(source, binarySource = false) {
      requireIdle();

      loaded = false;
      generation++;
      resourceExports = undefined;

      const sourceLength = write(source, 4096);

      e.validation_only(1);

      // Validate source with instantiation disabled and restore the normal load mode afterward.
      try {
        check(binarySource ? e.load_binary(4096, sourceLength) : e.load(4096, sourceLength));
      } finally {
        // Restore normal instantiation behavior after a validation-only attempt.
        e.validation_only(0);
      }

      return api;
    },

    // Load, bind and initialize a guest module through the selected interpreter.
    load(
      /** @type {string} */ source,
      /** @type {Record<string, Record<string, Function>>} */ imports = {},
      binarySource = false,
      asynchronous = false
    ) {
      requireIdle();

      loaded = false;
      generation++;
      resourceExports = undefined;
      bindings = [];
      resources = [];

      importedExceptions.clear();

      exportedResources = new Map();
      exportedFunctions = new Map();
      tableFunctions = new Map();
      foreignFunctions = new Map();
      externalValues = [null];
      externalIds = new Map();
      opaqueReferences = new Map();

      const sourceLength = write(source, 4096);

      check(binarySource ? e.load_binary(4096, sourceLength) : e.load(4096, sourceLength));

      // Give each declared guest tag a fresh identity for this module generation.
      for (let index = 0; index < e.tag_count(); index++) e.bind_tag(index, nextTagIdentity++);

      const resolved = [],
        resourceBindings = [];
      let pages = e.memory_minimum(0),
        maximum = e.memory_maximum(0),
        entries = e.table_size(0),
        tableMaximum = e.table_max(0);

      // Resolve and validate every function and resource import before initialization.
      for (let index = 0; index < e.import_count(); index++) {
        const view = new DataView(e.memory.buffer, memoryOffset);
        const at = e.import_info(index);
        const target = view.getInt32(at, true);
        const module = readText(view.getUint32(at + 4, true), view.getUint32(at + 8, true));
        const name = readText(view.getUint32(at + 12, true), view.getUint32(at + 16, true));
        const kind = view.getInt32(at + 24, true);
        const namespace = imports && Object.hasOwn(imports, module) ? imports[module] : undefined;
        const callback = namespace && Object.hasOwn(namespace, name) ? namespace[name] : undefined;

        // Bind resource imports through typed host handles instead of treating them as callbacks.
        if (kind) {
          const state = callback && resourceTypes.get(callback);

          // Report a missing resource handle before reading its signature or state.
          if (!state) throw new Error(`missing resource import ${module}.${name}`);

          // Reject a resource whose provider is stale or whose kind differs from the declared import.
          if (!state.valid() || state.kind !== kind)
            throw new Error(`import signature mismatch or stale binding ${module}.${name}`);

          // Require tag payload signatures to agree in both directions before sharing identity.
          if (kind === 4) {
            const descriptor = typeDescription(e.tag_type(target));

            // Reject tag imports whose structural payload signatures differ.
            if (!compatibleType(state.descriptor, descriptor) || !compatibleType(descriptor, state.descriptor))
              throw new Error(`import signature mismatch ${module}.${name}`);

            e.bind_tag(target, state.identity);
            resourceBindings.push({ index: target, state });
            resolved.push(null);
            continue;
          }

          // Check imported memory and table limits and address widths before binding their storage.
          if (kind === 1 || kind === 3) {
            // Prevent memory32/table32 resources from satisfying memory64/table64 imports or vice versa.
            if (state.addressType !== (kind === 1 ? e.memory_width(target) : e.table_address_type(target)))
              throw new Error(`import signature mismatch ${module}.${name}`);

            const actual = kind === 1 ? state.pages : state.entries.length;
            const minimum = kind === 1 ? e.memory_minimum(target) : e.table_size(target),
              requiredMaximum = kind === 1 ? e.memory_maximum(target) : e.table_max(target);

            // Require table element types to agree because imported tables can be both read and written.
            if (
              kind === 3 &&
              (!compatibleType(state.descriptor, typeDescription(view.getInt32(e.table_info(target) + 16, true))) ||
                !compatibleType(typeDescription(view.getInt32(e.table_info(target) + 16, true)), state.descriptor))
            )
              throw new Error(`import signature mismatch ${module}.${name}`);

            // Enforce declared minimum sizes and maximum limits against the provider's actual resource.
            if (
              actual < minimum ||
              (requiredMaximum !== -1 && (state.maximum === -1 || state.maximum > requiredMaximum))
            )
              throw new Error(`import signature mismatch ${module}.${name}`);

            // Bind imported memory with the provider's current size and maximum.
            if (kind === 1) check(e.bind_guest_memory(target, actual, state.maximum));
            else check(e.bind_guest_table(target, actual, state.maximum));
          } else {
            // Bind a global import with its declared mutability and structural value type.
            const globalAt = e.global_info(target);

            // Require global mutability to match; mutable globals also require type compatibility in both directions.
            if (
              state.mutable !== view.getInt32(globalAt + 8, true) ||
              !compatibleType(state.descriptor, typeDescription(view.getInt32(globalAt + 12, true))) ||
              (state.mutable && !compatibleType(typeDescription(view.getInt32(globalAt + 12, true)), state.descriptor))
            )
              throw new Error(`import signature mismatch ${module}.${name}`);
          }

          resourceBindings.push({ index: target, state });
          resolved.push(null);
          continue;
        }

        const params = Array.from({ length: e.function_params(target) }, (_, slot) =>
          e.function_param_type(target, slot)
        );
        const results = resultSignature(target);

        // Reject missing or noncallable function imports before recording their argument ABI.
        if (typeof callback !== 'function') throw new Error(`missing function import ${module}.${name}`);

        const signature = functionTypes.get(callback);

        // Reject typed forwarding functions whose generation or structural signature is incompatible.
        if (
          signature &&
          (!signature.valid() ||
            signature.params.join(',') !== params.join(',') ||
            JSON.stringify(signature.results) !== JSON.stringify(results) ||
            (signature.descriptor &&
              !compatibleType(signature.descriptor, typeDescription(e.function_heap_type(target)))))
        ) {
          throw new Error(`import signature mismatch or stale binding ${module}.${name}`);
        }

        resolved.push({ module, name, params, results, callback });
      }

      bindings = resolved;
      resources = resourceBindings;

      const globalAliases = new Map();

      // Canonicalize repeated imports of the same mutable global handle.
      // Restrict global aliasing to global imports.
      for (const binding of resources)
        if (binding.state.kind === 2) {
          // Point duplicate imports at the first guest slot so mutations are immediately shared.
          if (globalAliases.has(binding.state)) e.alias_guest_global(binding.index, globalAliases.get(binding.state));
          else globalAliases.set(binding.state, binding.index);
        }

      const memoryAliases = new Map();

      // Canonicalize repeated imports of the same memory handle.
      // Restrict memory aliasing to memory imports.
      for (const binding of resources)
        if (binding.state.kind === 1) {
          // Reuse the first imported memory descriptor so aliases share storage and growth.
          if (memoryAliases.has(binding.state)) e.alias_guest_memory(binding.index, memoryAliases.get(binding.state));
          else memoryAliases.set(binding.state, binding.index);
        }

      const tableAliases = new Map();

      // Canonicalize repeated imports of the same table handle.
      // Restrict table aliasing to table imports.
      for (const binding of resources)
        if (binding.state.kind === 3) {
          // Reuse the first imported table descriptor so aliases share entries and growth.
          if (tableAliases.has(binding.state)) e.alias_guest_table(binding.index, tableAliases.get(binding.state));
          else tableAliases.set(binding.state, binding.index);
        }

      check(e.prepare_resource_imports(pages, maximum, entries, tableMaximum));

      synchronizeIn();

      // Check forwarding depth before running imported callbacks during guest initialization.
      if (backend.countsForwardingDepth && currentDepth() >= limits.forwardingDepth)
        throw new Error('forwarding depth limit');

      // Start callbacks may reenter initialized functions while reloads remain guarded.
      loaded = true;
      invoking = true;
      activeInvocation = {};

      // Finish module initialization and publish its loaded state and resource changes.
      const finish = () => {
        synchronizeOut();
      };

      // Clear the loaded state and translate an initialization failure for the caller.
      const failed = (error) => {
        // Preserve segment writes even when later initialization fails.
        if (e.segments_ready()) synchronizeOut();

        loaded = false;

        throw error;
      };

      // Restore invocation ownership after guest module initialization.
      const cleanup = () => {
        // Abort a pending initialization import before releasing invocation ownership.
        try {
          // Cancel a still-pending import left by a failed start callback.
          if (e.pending_import() >= 0) e.resume64(0n, 1);
        } finally {
          // Release initialization ownership even when aborting a suspended import fails.
          invoking = false;
          activeInvocation = undefined;
        }
      };

      // Allow the automatic start function to suspend only for an asynchronous load.
      if (asynchronous) {
        const depth = currentDepth() + (backend.countsForwardingDepth ? 1 : 0);

        // Initialize the guest asynchronously and clear invocation state on every exit path.
        return invocationContext.run(depth, async () => {
          // Initialize resources and run the automatic start while guaranteeing cleanup.
          try {
            check(e.initialize());
            await driveAsync(0n);
            finish();
          } catch (error) {
            // Clear loaded state and preserve visible segment effects when asynchronous initialization fails.
            failed(error);
          } finally {
            // Release invocation ownership after asynchronous guest initialization.
            cleanup();
          }
        });
      }

      // Execute the prepared operation within its invocation context.
      const run = () => {
        // Initialize resources and run the automatic start through the synchronous driver.
        try {
          check(e.initialize());
          drive(0n);
          finish();
        } catch (error) {
          // Clear loaded state and preserve visible segment effects when synchronous initialization fails.
          failed(error);
        } finally {
          // Release invocation ownership after synchronous guest initialization.
          cleanup();
        }
      };

      return backend.countsForwardingDepth ? invocationContext.run(currentDepth() + 1, run) : run();
    },

    // Load a text guest while allowing asynchronous imports during initialization.
    async loadAsync(source, imports = {}) {
      return api.load(source, imports, false, true);
    },

    // Load a binary guest while allowing asynchronous imports during initialization.
    async loadBinaryAsync(bytes, imports = {}) {
      // Require byte-oriented binary input before using the asynchronous binary decoder.
      if (!(bytes instanceof Uint8Array)) throw new Error('binary source must be a Uint8Array');

      return api.load(bytes, imports, true, true);
    },

    // Decode and load a binary guest without compiling it natively.
    loadBinary(bytes, imports = {}) {
      // Require byte-oriented binary input before using the synchronous binary decoder.
      if (!(bytes instanceof Uint8Array)) throw new Error('binary source must be a Uint8Array');

      return api.load(bytes, imports, true);
    },

    // Invoke a guest export synchronously and return decoded results.
    invoke(name, ...args) {
      return invokePublic(name, args, false);
    },

    // Invoke a guest export while awaiting asynchronous host imports.
    async invokeAsync(name, ...args) {
      return invokePublic(name, args, true);
    },

    // Raw async slots also protect Promise externrefs from JavaScript promise assimilation.
    async invokeRawAsync(name, ...args) {
      return invokeRawPublic(name, args, true);
    },

    // Invoke a guest export with raw typed value slots.
    invokeRaw(name, ...args) {
      return invokeRawPublic(name, args, false);
    },

    // Return bytes reclaimed from the guest's private object arena; collection preserves live reference identity.
    collectGarbage() {
      requireIdle();
      requireLoaded();

      synchronizeIn();

      refreshHostRoots();

      const before = e.gc_live_bytes();

      e.collect_garbage();
      check(e.error_code());

      return before - e.gc_live_bytes();
    },

    // Return the parameter and result types of a named guest export.
    signature(/** @type {string} */ name) {
      const signature = functionSignature(name);

      return {
        params: signature.params.map((type) => scalarNames[type]),
        result: Array.isArray(signature.results)
          ? signature.results.map((type) => scalarNames[type])
          : scalarNames[signature.results]
      };
    },

    // Return a typed, generation-bound forwarding function for a guest export.
    exportFunction(/** @type {string} */ name) {
      requireLoaded();

      const signature = functionSignature(name);

      // Preserve callback identity by reusing an already exported function.
      if (exportedFunctions.has(signature.index)) return exportedFunctions.get(signature.index);

      const existing = tableFunctions.get(signature.index);

      // Reuse this instance's table callback when the function already has a reference wrapper.
      if (existing?.owner === owner) return existing.callback;

      const currentGeneration = generation;

      // Forward decoded arguments to the referenced guest function.
      const callback = (/** @type {(number | bigint)[]} */ ...args) => {
        // Reject decoded forwarding calls after their provider has been reloaded.
        if (!loaded || generation !== currentGeneration) throw new Error('stale forwarded function');

        return api.invoke(name, ...args);
      };

      functionTypes.set(callback, {
        params: signature.params,
        results: signature.results,
        descriptor: typeDescription(e.function_heap_type(signature.index)),

        // Check that a forwarding handle still belongs to the current loaded generation.
        valid: () => loaded && generation === currentGeneration,

        // Run the operation with raw typed arguments and results.
        raw: (args) => {
          // Reject raw forwarding calls after their provider has been reloaded.
          if (!loaded || generation !== currentGeneration) throw new Error('stale forwarded function');

          return api.invokeRaw(name, ...args);
        },

        // Forward raw typed arguments while awaiting asynchronous guest imports.
        rawAsync: async (args) => {
          // Reject asynchronous raw forwarding calls after their provider has been reloaded.
          if (!loaded || generation !== currentGeneration) throw new Error('stale forwarded function');

          return api.invokeRawAsync(name, ...args);
        },

        // Return the generation-checked guest function reference for this forwarding binding.
        reference: () => {
          // Reject reference recovery after the function's provider has been reloaded.
          if (!loaded || generation !== currentGeneration) throw new Error('stale forwarded function');

          return functionReference(signature.index);
        }
      });
      exportedFunctions.set(signature.index, callback);

      return callback;
    },

    // Return a forwarding function that supports asynchronous guest imports.
    exportFunctionAsync(name) {
      const synchronous = api.exportFunction(name);

      // Reuse the asynchronous wrapper for a previously exported synchronous function.
      if (asynchronousFunctions.has(synchronous)) return asynchronousFunctions.get(synchronous);

      const metadata = functionTypes.get(synchronous);

      // Forward decoded arguments to the referenced guest function.
      const callback = async (...args) => {
        // Reject asynchronous forwarding calls whose original export is stale.
        if (!metadata.valid()) throw new Error('stale forwarded function');

        return api.invokeAsync(name, ...args);
      };

      functionTypes.set(callback, metadata);
      asynchronousFunctions.set(synchronous, callback);
      asynchronousImports.add(callback);

      return callback;
    },

    // Build an export namespace whose functions permit asynchronous invocation.
    exportNamespaceAsync() {
      return api.exportNamespace(true);
    },

    // Build a namespace of forwarding functions and resource handles.
    exportNamespace(asynchronous = false) {
      requireLoaded();

      synchronizeIn();

      const namespace = Object.create(null);

      // Expose every named guest export as a typed callback or resource handle.
      for (let index = 0; index < e.exports_count(); index++) {
        const view = new DataView(e.memory.buffer, memoryOffset),
          at = e.export_info(index);
        const name = readText(view.getUint32(at, true), view.getUint32(at + 4, true));
        const target = view.getInt32(at + 8, true),
          kind = view.getInt32(at + 20, true);

        namespace[name] = kind
          ? exportResource(target, kind)
          : asynchronous
          ? api.exportFunctionAsync(name)
          : api.exportFunction(name);
      }

      return namespace;
    },

    // Read and decode a named guest global, preserving vector and reference values.
    getGlobal(/** @type {string} */ name) {
      synchronizeIn();

      requireLoaded();

      const at = e.host_base();
      const n = write(name, at);
      const type = e.global_type(at, n);

      check(e.error_code());

      let value = e.get_global64(at, n);

      // Include both halves when reading a vector global.
      if (type === 7) value = BigInt.asUintN(64, value) | (BigInt.asUintN(64, e.global_high(at, n)) << 64n);

      check(e.error_code());

      return decodedValue(value, type);
    },

    // Validate and publish a new value for a mutable guest global.
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

      // Write the upper half as well as the low slot when assigning a vector global.
      if (type === 7) check(e.set_global_high(at, n, BigInt.asIntN(64, bits >> 64n)));

      synchronizeOut();
    },

    // Copy a checked range of guest memory into host-owned bytes.
    readMemory(offset, length, memory = 0) {
      synchronizeIn();

      const at = memoryRange(offset, length, memoryIndex(memory));

      return new Uint8Array(e.memory.buffer, memoryOffset + at, length).slice();
    },

    // Copy host bytes into a checked range of guest memory and publish changes.
    writeMemory(offset, bytes, memory = 0) {
      synchronizeIn();

      // Require a byte array before copying host data into guest memory.
      if (!(bytes instanceof Uint8Array)) throw new Error('memory bytes must be a Uint8Array');

      const at = memoryRange(offset, bytes.length, memoryIndex(memory));

      new Uint8Array(e.memory.buffer, memoryOffset + at, bytes.length).set(bytes);

      synchronizeOut();
    },

    // Page counts remain Numbers because host-visible physical backing is bounded.
    memoryType(memory = 0) {
      requireLoaded();

      return e.memory_width(memoryIndex(memory)) === 2 ? 'i64' : 'i32';
    },

    // Read the current logical page count of a selected guest memory.
    memoryPages(memory = 0) {
      synchronizeIn();

      return e.memory_pages(memoryIndex(memory));
    },

    // Grow a selected guest memory, returning its previous size or failure.
    growMemory(pages, memory = 0) {
      synchronizeIn();

      const index = memoryIndex(memory);

      // Preserve a memory64 growth delta as a BigInt until its logical range has been checked.
      if (typeof pages === 'bigint') {
        // Prevent BigInt growth requests from being used with memory32.
        if (e.memory_width(index) !== 2) throw new Error('BigInt growth requires memory64');

        // Reject growth deltas outside the unsigned memory64 address range.
        if (pages < 0n || pages > (1n << 64n) - 1n) throw new Error('pages must be an unsigned i64 integer');

        // Large logical deltas must fail without narrowing or wrapping the host ABI's i32 slot.
        if (pages > 0xffffffffn) return -1;

        pages = Number(pages);
      }

      u32(pages);

      const result = e.grow_memory(index, pages);

      synchronizeOut();

      return result;
    },

    // Return a checked, generation-bound guest tag handle.
    getTag(tag = 0) {
      return exportResource(tagIndex(tag), 4);
    },

    // Return the parameter types of a selected guest tag.
    tagSignature(tag = 0) {
      return { params: tagParameters(tagIndex(tag)).map((type) => scalarNames[type]) };
    },

    // Validate a tag payload and create a host-visible guest exception.
    createException(tag, ...args) {
      return createException(tag, args, false);
    },

    // Create a tagged guest exception from raw typed payload slots.
    createExceptionRaw(tag, ...args) {
      return createException(tag, args, true);
    },

    // Read the current logical element count of a selected guest table.
    tableSize(table = 0) {
      synchronizeIn();

      return e.table_size(tableIndex(table));
    },

    // Read and decode a checked guest table element.
    getTable(index, table = 0) {
      synchronizeIn();

      const target = tableIndex(table),
        slot = tableEntry(index, target);
      const at = e.table_base(target) + slot * 4;
      const bits = BigInt((new DataView(e.memory.buffer, memoryOffset).getUint32(at, true) + 1) >>> 0);

      return decodedValue(bits, e.table_type(target));
    },

    // Validate and publish a replacement guest table element.
    setTable(index, value, table = 0) {
      synchronizeIn();

      const target = tableIndex(table),
        slot = tableEntry(index, target);
      const bits = tableValue(value, target);

      // Reference interning can move backing memory, so obtain the entry address afterward.
      new DataView(e.memory.buffer, memoryOffset).setInt32(e.table_base(target) + slot * 4, Number(bits) - 1, true);

      synchronizeOut();
    },

    // Grow a guest table with a compatible fill value, returning its previous size or failure.
    growTable(entries, value = null, table = 0) {
      synchronizeIn();

      const target = tableIndex(table);
      let oversized = false;

      // Preserve table64 growth deltas until their logical range has been checked.
      if (typeof entries === 'bigint') {
        // Prevent BigInt growth requests from being used with table32.
        if (e.table_address_type(target) !== 2) throw new Error('BigInt growth requires table64');

        // Reject growth deltas outside the unsigned table64 address range.
        if (entries < 0n || entries > (1n << 64n) - 1n) throw new Error('entries must be an unsigned i64 integer');

        oversized = entries > 0xffffffffn;
        entries = oversized ? 0 : Number(entries);
      }

      u32(entries);

      const bits = tableValue(value, target);

      // Report physically unrepresentable table growth without wrapping the requested size.
      if (oversized) return -1;

      const result = e.grow_host_table(target, entries, bits);

      synchronizeOut();

      return result;
    },

    // Set the unsigned 32-bit instruction budget for subsequent guest invocations.
    setFuel(/** @type {number} */ limit) {
      // Reject fuel budgets that cannot be represented as an unsigned i32.
      if (!Number.isInteger(limit) || limit < 0 || limit > 4294967295) {
        throw new Error('fuel must be an unsigned i32 integer');
      }

      e.set_fuel(limit);
    },

    // Set the unsigned 64-bit instruction budget for subsequent guest invocations.
    setFuel64(/** @type {bigint} */ limit) {
      // Reject fuel budgets that cannot be represented as an unsigned i64 BigInt.
      if (typeof limit !== 'bigint' || limit < 0n || limit > (1n << 64n) - 1n) {
        throw new Error('fuel must be an unsigned i64 BigInt');
      }

      e.set_fuel64(BigInt.asIntN(64, limit));
    }
  };

  engineBackends.set(api, backend);

  return api;
}

/** A guest exit status that never terminates the embedding Node process. */
export class WasiExit extends Error {
  // Retain an unsigned guest exit code without terminating the host process.
  constructor(code) {
    super(`WASI process exited with code ${code >>> 0}`);

    this.name = 'WasiExit';
    this.code = code >>> 0;
  }
}

// Find a guest process exit through wrapped host-import error causes.
function exitError(error) {
  const seen = new Set();

  // Search wrapped import causes without looping on a cyclic error chain.
  for (let cause = error; cause instanceof Error && !seen.has(cause); cause = cause.cause) {
    // Recover the original guest process exit rather than reporting it as an import failure.
    if (cause instanceof WasiExit) return cause;

    seen.add(cause);
  }

  return error;
}

/** Preview 1 imports for one wasm32 guest. Standard streams are borrowed descriptors. */
export function createWasiHost(engine, options = {}) {
  const {
    memory: selector = 'memory',
    args = [],
    env = {},
    preopens = {},
    stdin = 0,
    stdout = 1,
    stderr = 2,
    ...unknown
  } = options;

  // Reject unsupported WASI options instead of silently using host defaults.
  if (Object.keys(unknown).length) throw new Error(`unknown WASI option ${Object.keys(unknown)[0]}`);

  const wasi = new WASI({ args, env, preopens, stdin, stdout, stderr, version: 'preview1', returnOnExit: true });
  const memory = new WebAssembly.Memory({ initial: 0 });

  wasi.initialize({ exports: { memory } });

  const descriptors = new Map([
    [0, false],
    [1, false],
    [2, false],
    ...Object.keys(preopens).map((_, i) => [i + 3, true])
  ]);
  let generation,
    pages = 0,
    phase = 'fresh',
    closed = false,
    active = 0;

  // Bind the WASI host to one initialized wasm32 guest generation.
  function bind() {
    // Prevent use of a WASI adapter after its owned descriptors have been closed.
    if (closed) throw new Error('WASI host is closed');

    // Prevent a memory mirror and descriptor set from being reused after guest reload.
    if (generation !== undefined && generation !== engine.generation)
      throw new Error('create a fresh WASI host after guest reload');

    // Require wasm32 memory for the Preview 1 pointer ABI.
    if (engine.memoryType(selector) !== 'i32') throw new Error('WASI Preview 1 requires wasm32 memory');

    generation = engine.generation;
  }

  // Copy the latest guest memory image into the Node WASI mirror.
  function synchronizeIn() {
    bind();

    const current = engine.memoryPages(selector);

    // Grow the mirror to cover newly allocated guest pages before invoking Node WASI.
    if (current > pages) memory.grow(current - pages);

    pages = current;

    new Uint8Array(memory.buffer).set(engine.readMemory(0, pages * 65536, selector));
  }

  // Track descriptor ownership after successful WASI open, close or renumber operations.
  function descriptorEffect(name, arguments_, result) {
    // Failed syscalls must not change descriptor ownership bookkeeping.
    if (result !== 0) return;

    // Retain ownership of newly opened or accepted descriptors for later cleanup.
    if (name === 'path_open' || name === 'sock_accept') {
      const pointer = arguments_[name === 'path_open' ? 8 : 2] >>> 0;

      descriptors.set(new DataView(memory.buffer).getUint32(pointer, true), true);
    }

    // Remove successfully closed descriptors from the cleanup set.
    if (name === 'fd_close') descriptors.delete(arguments_[0] >>> 0);

    // Move ownership alongside a successful descriptor renumber operation.
    if (name === 'fd_renumber') {
      const from = arguments_[0] >>> 0,
        to = arguments_[1] >>> 0;

      // Leave ownership unchanged when a descriptor is renumbered to itself.
      if (from !== to) {
        const owned = descriptors.get(from);

        descriptors.delete(from);
        descriptors.set(to, owned);
      }
    }
  }
  const namespace = Object.create(null);

  // Wrap every Node Preview 1 import with guest memory synchronization and lifetime tracking.
  for (const [name, callback] of Object.entries(wasi.wasiImport)) {
    // Forward one Preview 1 syscall through the memory mirror and track descriptor changes.
    namespace[name] = (...arguments_) => {
      bind();

      // Translate process exit into an exception so the guest cannot terminate its embedding process.
      if (name === 'proc_exit') throw new WasiExit(arguments_[0]);

      synchronizeIn();

      active++;

      // Account for each active syscall and copy memory changes back even when it throws.
      try {
        // WASI i32 parameters are unsigned; Node’s JavaScript binding needs the same bits as its native Wasm path.
        const result = callback(...arguments_.map((value) => (typeof value === 'number' ? value >>> 0 : value)));

        descriptorEffect(name, arguments_, result);

        return result;
      } finally {
        // Always release the active-call count, including when copying syscall effects back fails.
        try {
          engine.writeMemory(0, new Uint8Array(memory.buffer), selector);
        } finally {
          // Release the syscall activity guard even when copying memory effects back fails.
          active--;
        }
      }
    };
  }

  // Invoke a guest export synchronously and return decoded results.
  function invoke(name, ...arguments_) {
    bind();

    active++;

    // Run the command export while retaining exit unwrapping and active-call cleanup.
    try {
      return engine.invoke(name, ...arguments_);
    } catch (error) {
      // Preserve the original process exit hidden inside an interpreter import error.
      throw exitError(error);
    } finally {
      // Release the command activity guard after either a normal return or a process exit.
      active--;
    }
  }

  // Invoke a guest export while awaiting asynchronous host imports.
  async function invokeAsync(name, ...arguments_) {
    bind();

    active++;

    // Await the command export while retaining exit unwrapping and active-call cleanup.
    try {
      return await engine.invokeAsync(name, ...arguments_);
    } catch (error) {
      // Preserve the original process exit hidden inside an asynchronous import error.
      throw exitError(error);
    } finally {
      // Release the asynchronous command activity guard after every completion path.
      active--;
    }
  }

  // Validate the WASI entry point and consume the fresh command or reactor lifecycle.
  function begin(mode) {
    bind();

    // Consume the command or reactor lifecycle only once per host adapter.
    if (phase !== 'fresh') throw new Error('WASI guest already started or initialized');

    const exports = engine.exportNamespace();
    const name = mode === 'command' ? '_start' : '_initialize';

    // Prevent command and reactor entry points from being mixed in the same WASI guest.
    if (Object.hasOwn(exports, mode === 'command' ? '_initialize' : '_start'))
      throw new Error(`WASI ${mode} has an incompatible entry point`);

    const present = Object.hasOwn(exports, name);

    // Validate the required command entry or an optional reactor initializer before consuming the lifecycle.
    if (mode === 'command' || present) {
      const signature = engine.signature(name);

      // Require the WASI entry point to have a void, zero-argument signature.
      if (signature.params.length || signature.result !== null)
        throw new Error(`WASI ${name} must have no parameters or results`);
    }

    phase = mode;

    return present ? name : undefined;
  }
  return Object.freeze({
    imports: Object.freeze({ wasi_snapshot_preview1: Object.freeze(namespace) }),
    invoke,
    invokeAsync,

    // Run the WASI command entry point and return its unsigned guest exit code.
    start() {
      const name = begin('command');

      // Run the command and report success when it returns normally.
      try {
        invoke(name);

        return 0;
      } catch (error) {
        // Convert explicit guest process exit into an unsigned status while preserving other errors.
        // Return the requested guest status instead of treating proc_exit as a command failure.
        if (error instanceof WasiExit) return error.code;

        throw error;
      }
    },

    // Run the WASI command entry point while awaiting asynchronous imports.
    async startAsync() {
      const name = begin('command');

      // Await the command and report success when it returns normally.
      try {
        await invokeAsync(name);

        return 0;
      } catch (error) {
        // Convert asynchronous guest process exit into an unsigned status while preserving other errors.
        // Return the requested guest status instead of treating proc_exit as an asynchronous failure.
        if (error instanceof WasiExit) return error.code;

        throw error;
      }
    },

    // Initialize a WASI reactor once, invoking its optional entry point.
    initialize() {
      const name = begin('reactor');

      // Invoke the reactor initializer only when the guest exports one.
      if (name) invoke(name);
    },

    // Initialize a WASI reactor while awaiting asynchronous imports.
    async initializeAsync() {
      const name = begin('reactor');

      // Await the reactor initializer only when the guest exports one.
      if (name) await invokeAsync(name);
    },

    // Close owned WASI descriptors once, retaining borrowed standard streams.
    close() {
      // Make descriptor cleanup idempotent.
      if (closed) return;

      // Prevent closing descriptors while a host call is still using them.
      if (active) throw new Error('WASI host is active');

      closed = true;

      const failures = [];

      // Visit the tracked descriptors while retaining all cleanup failures for one final report.
      // Close owned preopens and guest-opened descriptors while retaining borrowed standard streams.
      for (const [fd, owned] of descriptors)
        if (owned) {
          // Attempt every owned close even if an earlier descriptor failed to close.
          try {
            const errno = wasi.wasiImport.fd_close(fd);

            // Ignore already-closed descriptors but retain other native cleanup errors.
            if (errno && errno !== 8) failures.push(new Error(`WASI fd_close ${fd}: errno ${errno}`));
          } catch (error) {
            // Retain thrown cleanup errors so remaining owned descriptors still receive a close attempt.
            failures.push(error);
          }
        }

      descriptors.clear();

      // Report all cleanup failures together after exhausting the owned descriptor set.
      if (failures.length) throw new AggregateError(failures, 'WASI descriptor cleanup failed');
    }
  });
}

// Recognize Wasm by its magic bytes so guest loading does not depend on the filename extension.
function isWasmBinary(bytes) {
  return bytes[0] === 0 && bytes[1] === 0x61 && bytes[2] === 0x73 && bytes[3] === 0x6d;
}

/** Load WAT or Wasm with fresh Preview 1 imports; the caller owns the returned host. */
export async function loadWasi(source, options = {}) {
  const {
    runtime = 'wat',
    fuel = 100_000_000n,
    limits,
    parentLimits,
    parentFuel,
    imports = {},
    mode,
    ...hostOptions
  } = options;

  // Select only a supported interpreter implementation for WASI execution.
  if (!['wat', 'wasm'].includes(runtime)) throw new Error('WASI runtime must be wat or wasm');

  // Reject an unsupported WASI lifecycle mode before constructing the guest.
  if (mode !== undefined && !['command', 'reactor'].includes(mode))
    throw new Error('WASI mode must be command or reactor');

  const engine = await (runtime === 'wasm' ? createBootstrapInterpreter : createInterpreter)(undefined, {
    limits,
    parentLimits,
    parentFuel
  });

  engine.setFuel64(fuel);

  const host = createWasiHost(engine, hostOptions);

  // Close the newly created host if import binding or guest loading fails.
  try {
    // Protect the Preview 1 adapter from replacement by additional host imports.
    if (Object.hasOwn(imports, 'wasi_snapshot_preview1'))
      throw new Error('additional imports cannot replace WASI Preview 1');

    const bindings = { ...imports, ...host.imports };

    // Detect binary bytes explicitly and decode other byte input as strict UTF-8 WAT.
    if (source instanceof Uint8Array) {
      // Use the binary decoder only when the input begins with the Wasm magic bytes.
      if (isWasmBinary(source)) await engine.loadBinaryAsync(source, bindings);
      else await engine.loadAsync(new TextDecoder('utf-8', { fatal: true }).decode(source), bindings);
    }
    // Load string input directly as WAT without a byte-decoding round trip.
    else if (typeof source === 'string') await engine.loadAsync(source, bindings);
    else throw new Error('WASI source must be WAT text or a Uint8Array');

    return { engine, host };
  } catch (error) {
    // Release owned descriptors from a failed load and retain any wrapped guest exit identity.
    host.close();

    throw exitError(error);
  }
}

/** Execute a command or initialize a reactor, returning its unsigned exit code and closing owned descriptors. */
export async function runWasi(source, options = {}) {
  let host;

  // Run the selected lifecycle while guaranteeing descriptor cleanup on success or failure.
  try {
    ({ host } = await loadWasi(source, options));

    // Initialize reactors without requiring or invoking a command entry point.
    if (options.mode === 'reactor') {
      await host.initializeAsync();

      return 0;
    }

    return await host.startAsync();
  } catch (error) {
    // Treat guest process exit as a status while preserving unrelated execution failures.
    // Return the unsigned guest exit code, including exits reached during automatic start.
    if (error instanceof WasiExit) return error.code;

    throw error;
  } finally {
    // Close owned guest descriptors after command or reactor execution, including failures.
    host?.close();
  }
}

const cliUsage = `Usage: node wiw.js [options] <guest.wat|guest.wasm> <export> [arguments...]
  --runtime wasm|wat   Compiled Wasm (default, faster) or self-hosted WAT
  --bootstrap          Alias for --runtime wat (inception: wiw interprets itself)
  --wasi               Run a WASI Preview 1 guest; omit <export> and pass guest arguments
                       Accepts WAT or Wasm; guest filename becomes argv[0]
  --fuel INTEGER       Unsigned 64-bit per-invocation fuel (default 100000000)
  --env NAME=VALUE     WASI guest environment entry; repeatable
  --dir GUEST=HOST     WASI preopened directory mapping; repeatable
  --reactor            WASI: initialize _initialize instead of invoking _start
  --help               Show usage
Place host options before the guest filename. WASI environment and preopens default to empty.
i64 and v128 arguments accept decimal or hexadecimal integers with an optional n suffix.
Multiple results use one typed line per value; vectors use a fixed-width 128-bit hex pattern.`;

// Parse shared CLI options before the filename, retaining the remaining guest arguments verbatim.
function parseCli(arguments_) {
  const options = { runtime: 'wasm', fuel: 100_000_000n, env: Object.create(null), preopens: Object.create(null) };
  let wasi = false,
    wasiOptions = false;

  // Stop at the filename so guest arguments cannot be consumed as host switches.
  while (arguments_.length) {
    const argument = arguments_[0];

    // An explicit separator permits a filename beginning with a dash.
    if (argument === '--') {
      arguments_.shift();
      break;
    }

    // Retain the filename and all following positional values for the selected runner.
    if (!argument.startsWith('-')) break;

    arguments_.shift();

    // Show the complete flag descriptions without loading a guest.
    if (argument === '--help') return { help: true };

    // Select the WASI lifecycle while retaining the shared runtime flags.
    if (argument === '--wasi') {
      wasi = true;
      continue;
    }

    // Inception executes the WAT interpreter inside the compiled parent.
    if (argument === '--bootstrap') {
      options.runtime = 'wat';
      continue;
    }

    // Reactors initialize an optional entry point instead of starting a command.
    if (argument === '--reactor') {
      options.mode = 'reactor';
      wasiOptions = true;
      continue;
    }

    // Consume one value for runtime selection or WASI host configuration.
    if (['--runtime', '--fuel', '--env', '--dir'].includes(argument)) {
      const value = arguments_.shift();

      // Reject incomplete host options before interpreting positional guest input.
      if (value === undefined) throw new Error(`missing value for ${argument}`);

      // Runtime selection applies equally to export and WASI invocation.
      if (argument === '--runtime') {
        options.runtime = value;
      } else if (argument === '--fuel') {
        // Preserve the complete unsigned 64-bit budget without converting through a Number.
        if (!/^\d+$/.test(value)) throw new Error('fuel must be an unsigned integer');

        options.fuel = BigInt(value);

        // Reject an unrepresentable budget before loading either the guest or its interpreter.
        if (options.fuel > (1n << 64n) - 1n) throw new Error('fuel must be an unsigned i64 integer');
      } else {
        // Environment and preopen mappings configure only the WASI host.
        wasiOptions = true;

        const split = value.indexOf('=');

        // Require a nonempty guest-side name before separating the mapping value.
        if (split < 1) throw new Error(`${argument} requires NAME=VALUE`);

        const key = value.slice(0, split),
          content = value.slice(split + 1);

        // Reject preopen mappings without a host directory target.
        if (argument === '--dir' && !content) throw new Error('--dir requires a host directory');

        options[argument === '--env' ? 'env' : 'preopens'][key] = content;
      }

      continue;
    }

    throw new Error(`unknown option ${argument}`);
  }

  // Reject unsupported runtime names before constructing either interpreter.
  if (!['wasm', 'wat'].includes(options.runtime)) throw new Error('runtime must be wasm or wat');

  // Require explicit WASI mode for options that configure process hosting.
  if (wasiOptions && !wasi) throw new Error('WASI options require --wasi');

  return { wasi, options };
}

// Run a WASI command or reactor using the already parsed shared CLI options.
async function runWasiCli(arguments_, options) {
  const file = arguments_.shift();

  // Require a guest filename before opening files or constructing the interpreter.
  if (!file) throw new Error(cliUsage);

  // Remove the optional guest-argument separator without changing subsequent arguments.
  if (arguments_[0] === '--') arguments_.shift();

  options.args = [file, ...arguments_];
  process.exitCode = (await runWasi(await readFile(file), options)) & 255;
}

// Convert a CLI value to its declared guest kind without rounding wide integer or vector patterns.
function cliArgument(argument, type) {
  // Wide numeric values must remain BigInts throughout parsing and invocation.
  if (type === 'i64' || type === 'v128') {
    const literal = argument.endsWith('n') ? argument.slice(0, -1) : argument;

    const integer = literal.match(/^([+-]?)(\d+|0[xX][0-9a-fA-F]+)$/);

    // Require a complete integer spelling; empty arguments must not silently become zero.
    if (!integer) throw new Error(`${type} argument must be a decimal or hexadecimal integer`);

    // BigInt does not parse signed hexadecimal text directly, so retain the sign separately from its magnitude.
    const magnitude = BigInt(integer[2]);

    return integer[1] === '-' ? -magnitude : magnitude;
  }

  // CLI references can express null; live function and object handles belong to the embedding API.
  if (type.endsWith('ref')) {
    // Reject arbitrary strings rather than constructing an untyped or forged host handle.
    if (argument !== 'null') throw new Error(`${type} CLI argument must be null; use the API for live references`);

    return null;
  }

  // Preserve the familiar infinity spellings while leaving declared-width rounding to the interpreter.
  const value =
    argument === 'inf' || argument === '+inf' ? Infinity : argument === '-inf' ? -Infinity : Number(argument);

  // Only explicit NaN spellings may become NaN; malformed numeric text must not silently turn into one.
  if (!argument.length || argument.trim() !== argument || (Number.isNaN(value) && !/^[+-]?nan$/i.test(argument))) {
    throw new Error(`${type} argument must be a number`);
  }

  return value;
}

// Format one result while retaining signed zero and the complete raw vector width.
function cliResult(value, type) {
  // A lane-independent hex pattern exposes both vector halves without interpreting them as an integer result.
  if (type === 'v128') return `0x${BigInt.asUintN(128, value).toString(16).padStart(32, '0')}`;

  // Opaque host handles have no reusable CLI spelling, but null reference results remain inspectable.
  if (type.endsWith('ref')) return value === null ? 'null' : '<opaque reference>';

  return Object.is(value, -0) ? '-0' : String(value);
}

// Invoke a named export from WAT or binary input using the selected runtime and instruction budget.
async function runExportCli(arguments_, { runtime, fuel }) {
  const [file, name, ...values] = arguments_;

  // Require both a guest file and a named export before constructing the interpreter.
  if (!file || name === undefined) throw new Error(cliUsage);

  const interpreter = await (runtime === 'wat' ? createInterpreter() : createBootstrapInterpreter());

  // Apply fuel before loading so automatic module start functions cannot escape the requested budget.
  interpreter.setFuel64(fuel);

  const source = await readFile(file);

  // Use content detection for both formats, including files with unconventional or misleading extensions.
  if (isWasmBinary(source)) {
    interpreter.loadBinary(source);
  } else {
    // Reject malformed UTF-8 instead of silently replacing bytes in the WAT source.
    interpreter.load(new TextDecoder('utf-8', { fatal: true }).decode(source));
  }

  const signature = interpreter.signature(name);

  // Check arity before interpreting any argument using its declared guest kind.
  if (values.length !== signature.params.length) throw new Error('argument mismatch');

  // Parse each value at its own width; mixed scalar and vector signatures must not share Number coercion.
  const args = values.map((argument, index) => cliArgument(argument, signature.params[index]));
  const value = interpreter.invoke(name, ...args);

  // Void exports produce no output in either text or binary mode.
  if (value === undefined) return;

  // Multi-value returns retain order and an explicit type on every output line.
  if (Array.isArray(signature.result)) {
    // Format each result using its corresponding declared type rather than coercing the array to a comma-separated string.
    value.forEach((result, index) =>
      console.log(`${signature.result[index]}: ${cliResult(result, signature.result[index])}`)
    );
  } else {
    // Keep single numeric scalar output compatible; vectors and references require their type label.
    const typed = signature.result === 'v128' || signature.result.endsWith('ref');

    console.log(`${typed ? signature.result + ': ' : ''}${cliResult(value, signature.result)}`);
  }
}

// Run the CLI only when this module is the process entry point, allowing side-effect-free library imports.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // Translate command errors into stderr output and an exit status without throwing past the entry point.
  try {
    const arguments_ = process.argv.slice(2);
    const { help, wasi, options } = parseCli(arguments_);

    // Help documents the optional WASI mode alongside ordinary export invocation.
    if (help) {
      console.log(cliUsage);
    } else if (wasi) {
      // WASI mode supplies Preview 1 imports and runs the selected process lifecycle.
      await runWasiCli(arguments_, options);
    } else {
      // Ordinary mode invokes the requested export through the shared runtime selection.
      await runExportCli(arguments_, options);
    }
  } catch (error) {
    // Report a concise command error and mark the process as failed.
    console.error(error instanceof Error ? error.message : error);

    process.exitCode = 1;
  }
}
