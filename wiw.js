import { readFile } from 'node:fs/promises';
import { AsyncLocalStorage } from 'node:async_hooks';
import { pathToFileURL } from 'node:url';
import { WASI } from 'node:wasi';

import {
  formatValue as cliResult,
  createBootstrapInterpreter as createSharedBootstrapInterpreter,
  createInterpretedInterpreter as createSharedInterpretedInterpreter
} from './wiw-lib.js';

export * from './wiw-lib.js';

/** @typedef {import("./wiw-lib.js").InterpreterApi} InterpreterApi */
/** @typedef {import("./wiw-lib.js").InterpreterOptions} InterpreterOptions */
/** @typedef {import("./wiw-lib.js").GuestSource} GuestSource */
/** @typedef {import("./wiw-lib.js").HostImports} HostImports */
/** @typedef {import("./wiw-lib.js").ResourceSelector} ResourceSelector */
/** @typedef {import("./wiw-lib.js").ValueTypeName} ValueTypeName */
/** @typedef {import("./wiw-lib.js").CallbackScope} CallbackScope */
/** @typedef {import("./wiw-lib.js").RuntimeServices} RuntimeServices */
/** @typedef {import("./wiw-lib.js").AbiValue} AbiValue */

/**
 * Bootstrap path or precompiled native interpreter module.
 * @typedef {string | URL | WebAssembly.Module} BootstrapSource
 */

/**
 * WASI entry-point lifecycle.
 * @typedef {'command' | 'reactor'} WasiMode
 */

/**
 * Preview 1 guest memory selector, process values and descriptor ownership options.
 * @typedef {{memory?:ResourceSelector | undefined, args?:string[] | undefined, env?:Record<string, string> | undefined, preopens?:Record<string, string> | undefined, stdin?:number | undefined, stdout?:number | undefined, stderr?:number | undefined}} WasiOptions
 */

/**
 * WASI loader/runtime options shared by the CLI and embedding API.
 * @typedef {WasiOptions & InterpreterOptions & {runtime?: 'wat' | 'wasm', fuel?: bigint, imports?: HostImports, mode?: WasiMode}} WasiLoadOptions
 */

/**
 * Preview 1 import namespace, guest invocation and command/reactor lifecycle.
 * @typedef {{imports:HostImports, invoke:(name:string, ...args:unknown[]) => unknown, invokeAsync:(name:string, ...args:unknown[]) => Promise<unknown>, start:() => number, startAsync:() => Promise<number>, initialize:() => void, initializeAsync:() => Promise<void>, close:() => void}} WasiHost
 */

/**
 * Loaded guest interpreter and its caller-owned Preview 1 host.
 * @typedef {{engine:InterpreterApi, host:WasiHost}} WasiGuest
 */

/**
 * Help request or a runnable command with parsed runtime/WASI options.
 * @typedef {{help: true, wasi?: never, options?: never} | {help?: false, wasi: boolean, options: WasiLoadOptions}} CliParseResult
 */

/** @type {RuntimeServices} */
const runtime = {
  invocationContext: new AsyncLocalStorage(),
  callbackContext: new AsyncLocalStorage(),

  /**
   * Yield cooperative guest execution to Node's event loop.
   * @returns {Promise<void>}
   */
  yieldTask() {
    return new Promise(
      /**
       * Schedule the next cooperative continuation as a Node macrotask.
       * @param {() => void} resolve
       * @returns {void}
       */
      (resolve) => {
        setImmediate(resolve);
      }
    );
  }
};

/**
 * Read the compiled interpreter from disk or use a caller-supplied compiled module.
 * @param {BootstrapSource} [binary]
 * @param {InterpreterOptions} [options]
 * @returns {Promise<InterpreterApi>}
 */
export async function createBootstrapInterpreter(
  binary = new URL('./build/wiw-opt.wasm', import.meta.url),
  options = {}
) {
  const source = binary instanceof WebAssembly.Module ? binary : await readFile(binary);

  return createSharedBootstrapInterpreter(source, options, runtime);
}

/**
 * Create Node's default self-hosted interpreter using the optimized WAT source.
 * @param {BootstrapSource} [binary]
 * @param {InterpreterOptions} [options]
 * @returns {Promise<InterpreterApi>}
 */
export async function createInterpreter(
  binary = new URL('./build/wiw-opt.wasm', import.meta.url),
  options = {}
) {
  return createInterpretedInterpreter(binary, options);
}

/**
 * Read interpreter artifacts from disk and run one WAT interpreter above the bootstrap.
 * @param {BootstrapSource} [binary]
 * @param {InterpreterOptions} [options]
 * @returns {Promise<InterpreterApi>}
 */
export async function createInterpretedInterpreter(
  binary = new URL('./build/wiw-opt.wasm', import.meta.url),
  options = {}
) {
  const source = binary instanceof WebAssembly.Module ? binary : await readFile(binary);
  const interpreterSource =
    options.source ?? (await readFile(new URL('./build/wiw-opt.wat', import.meta.url), 'utf8'));

  return createSharedInterpretedInterpreter(source, { ...options, source: interpreterSource }, runtime);
}

/** A guest exit status that never terminates the embedding Node process. */
export class WasiExit extends Error {
  /**
   * Retain an unsigned guest exit code without terminating the host process.
   *
   * @param {number} code
   * @constructor
   */
  constructor(code) {
    super(`WASI process exited with code ${code >>> 0}`);

    this.name = 'WasiExit';
    this.code = code >>> 0;
  }
}

/**
 * Find a guest process exit through wrapped host-import error causes.
 *
 * @param {unknown} error
 * @returns {unknown}
 */
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

/**
 * Preview 1 imports for one wasm32 guest. Standard streams are borrowed descriptors.
 *
 * @param {InterpreterApi} engine
 * @param {WasiOptions} [options]
 * @returns {WasiHost}
 */
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

  const wasi = new WASI({
    args,
    env,
    preopens,
    stdin,
    stdout,
    stderr,
    version: 'preview1',
    returnOnExit: true
  });
  const memory = new WebAssembly.Memory({ initial: 0 });

  wasi.initialize({ exports: { memory } });

  const descriptors = new Map([
    [0, false],
    [1, false],
    [2, false],
    ...Object.keys(preopens).map(
      /**
       * Mark one preopened descriptor as host-owned for cleanup.
       *
       * @param {string} _
       * @param {number} i
       * @returns {[number, boolean]}
       */
      (_, i) => [i + 3, true]
    )
  ]);
  /** @type {number | undefined} */
  let generation;
  let pages = 0,
    phase = 'fresh',
    closed = false,
    active = 0;

  /**
   * Bind the WASI host to one initialized wasm32 guest generation.
   *
   * @returns {void}
   */
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

  /**
   * Copy the latest guest memory image into the Node WASI mirror.
   *
   * @returns {void}
   */
  function synchronizeIn() {
    bind();

    const current = engine.memoryPages(selector);

    // Grow the mirror to cover newly allocated guest pages before invoking Node WASI.
    if (current > pages) memory.grow(current - pages);

    pages = current;

    new Uint8Array(memory.buffer).set(engine.readMemory(0, pages * 65536, selector));
  }

  /**
   * Track descriptor ownership after successful WASI open, close or renumber operations.
   *
   * @param {string} name
   * @param {AbiValue[]} arguments_
   * @param {number} result
   * @returns {void}
   */
  function descriptorEffect(name, arguments_, result) {
    // Failed syscalls must not change descriptor ownership bookkeeping.
    if (result !== 0) return;

    // Retain ownership of newly opened or accepted descriptors for later cleanup.
    if (name === 'path_open' || name === 'sock_accept') {
      const pointer = /** @type {number} */ (arguments_[name === 'path_open' ? 8 : 2]) >>> 0;

      descriptors.set(new DataView(memory.buffer).getUint32(pointer, true), true);
    }

    // Remove successfully closed descriptors from the cleanup set.
    if (name === 'fd_close') descriptors.delete(/** @type {number} */ (arguments_[0]) >>> 0);

    // Move ownership alongside a successful descriptor renumber operation.
    if (name === 'fd_renumber') {
      const from = /** @type {number} */ (arguments_[0]) >>> 0,
        to = /** @type {number} */ (arguments_[1]) >>> 0;

      // Leave ownership unchanged when a descriptor is renumbered to itself.
      if (from !== to) {
        const owned = descriptors.get(from);

        descriptors.delete(from);
        descriptors.set(to, owned ?? false);
      }
    }
  }
  const namespace = Object.create(null);

  // Wrap every Node Preview 1 import with guest memory synchronization and lifetime tracking.
  for (const [name, callback] of Object.entries(wasi.wasiImport)) {
    // Forward one Preview 1 syscall through the memory mirror and track descriptor changes.
    namespace[name] =
      /**
       * Forward one Preview 1 syscall through the synchronized memory mirror.
       *
       * @param {...AbiValue} arguments_
       * @returns {number}
       */
      (...arguments_) => {
        bind();

        // Translate process exit into an exception so the guest cannot terminate its embedding process.
        if (name === 'proc_exit') throw new WasiExit(/** @type {number} */ (arguments_[0]));

        synchronizeIn();

        active++;

        // Account for each active syscall and copy memory changes back even when it throws.
        try {
          // WASI i32 parameters are unsigned; Node’s JavaScript binding needs the same bits as its native Wasm path.
          const result = callback(
            ...arguments_.map(
              /**
               * Preserve unsigned i32 syscall bits while leaving i64 arguments intact.
               *
               * @param {AbiValue} value
               * @returns {AbiValue}
               */
              (value) => (typeof value === 'number' ? value >>> 0 : value)
            )
          );

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

  /**
   * Invoke a guest export synchronously and return decoded results.
   *
   * @param {string} name
   * @param {...unknown} arguments_
   * @returns {unknown}
   */
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

  /**
   * Invoke a guest export while awaiting asynchronous host imports.
   *
   * @param {string} name
   * @param {...unknown} arguments_
   * @returns {Promise<unknown>}
   */
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

  /**
   * Validate the WASI entry point and consume the fresh command or reactor lifecycle.
   *
   * @param {WasiMode} mode
   * @returns {string | undefined}
   */
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

    /**
     * Run the WASI command entry point and return its unsigned guest exit code.
     *
     * @returns {number}
     */
    start() {
      const name = /** @type {string} */ (begin('command'));

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

    /**
     * Run the WASI command entry point while awaiting asynchronous imports.
     *
     * @returns {Promise<number>}
     */
    async startAsync() {
      const name = /** @type {string} */ (begin('command'));

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

    /**
     * Initialize a WASI reactor once, invoking its optional entry point.
     *
     * @returns {void}
     */
    initialize() {
      const name = begin('reactor');

      // Invoke the reactor initializer only when the guest exports one.
      if (name) invoke(name);
    },

    /**
     * Initialize a WASI reactor while awaiting asynchronous imports.
     *
     * @returns {Promise<void>}
     */
    async initializeAsync() {
      const name = begin('reactor');

      // Await the reactor initializer only when the guest exports one.
      if (name) await invokeAsync(name);
    },

    /**
     * Close owned WASI descriptors once, retaining borrowed standard streams.
     *
     * @returns {void}
     */
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
            const errno = wasi.wasiImport['fd_close'](fd);

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

/**
 * Recognize Wasm by its magic bytes so guest loading does not depend on the filename extension.
 *
 * @param {Uint8Array} bytes
 * @returns {boolean}
 */
function isWasmBinary(bytes) {
  return bytes[0] === 0 && bytes[1] === 0x61 && bytes[2] === 0x73 && bytes[3] === 0x6d;
}

/**
 * Load WAT or Wasm with fresh Preview 1 imports; the caller owns the returned host.
 *
 * @param {GuestSource} source
 * @param {WasiLoadOptions} [options]
 * @returns {Promise<WasiGuest>}
 */
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

/**
 * Execute a command or initialize a reactor, returning its unsigned exit code and closing owned descriptors.
 *
 * @param {GuestSource} source
 * @param {WasiLoadOptions} [options]
 * @returns {Promise<number>}
 */
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

/**
 * Parse shared CLI options before the filename, retaining the remaining guest arguments verbatim.
 *
 * @param {string[]} arguments_
 * @returns {CliParseResult}
 */
function parseCli(arguments_) {
  /** @type {WasiLoadOptions} */
  const options = {
    runtime: 'wasm',
    fuel: 100_000_000n,
    env: Object.create(null),
    preopens: Object.create(null)
  };
  let wasi = false,
    wasiOptions = false;

  // Stop at the filename so guest arguments cannot be consumed as host switches.
  while (arguments_.length) {
    const argument = /** @type {string} */ (arguments_[0]);

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
        options.runtime = /** @type {"wat" | "wasm"} */ (value);
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

        const mapping = /** @type {Record<string, string>} */ (
          options[argument === '--env' ? 'env' : 'preopens']
        );

        mapping[key] = content;
      }

      continue;
    }

    throw new Error(`unknown option ${argument}`);
  }

  // Reject unsupported runtime names before constructing either interpreter.
  if (!['wasm', 'wat'].includes(options.runtime ?? 'wasm')) throw new Error('runtime must be wasm or wat');

  // Require explicit WASI mode for options that configure process hosting.
  if (wasiOptions && !wasi) throw new Error('WASI options require --wasi');

  return { wasi, options };
}

/**
 * Run a WASI command or reactor using the already parsed shared CLI options.
 *
 * @param {string[]} arguments_
 * @param {WasiLoadOptions} options
 * @returns {Promise<void>}
 */
async function runWasiCli(arguments_, options) {
  const file = arguments_.shift();

  // Require a guest filename before opening files or constructing the interpreter.
  if (!file) throw new Error(cliUsage);

  // Remove the optional guest-argument separator without changing subsequent arguments.
  if (arguments_[0] === '--') arguments_.shift();

  options.args = [file, ...arguments_];
  process.exitCode = (await runWasi(await readFile(file), options)) & 255;
}

/**
 * Convert a CLI value to its declared guest kind without rounding wide integer or vector patterns.
 *
 * @param {string} argument
 * @param {ValueTypeName} type
 * @returns {number | bigint | null}
 */
function cliArgument(argument, type) {
  // Wide numeric values must remain BigInts throughout parsing and invocation.
  if (type === 'i64' || type === 'v128') {
    const literal = argument.endsWith('n') ? argument.slice(0, -1) : argument;

    const integer = literal.match(/^([+-]?)(\d+|0[xX][0-9a-fA-F]+)$/);

    // Require a complete integer spelling; empty arguments must not silently become zero.
    if (!integer) throw new Error(`${type} argument must be a decimal or hexadecimal integer`);

    // BigInt does not parse signed hexadecimal text directly, so retain the sign separately from its magnitude.
    const magnitude = BigInt(/** @type {string} */ (integer[2]));

    return integer[1] === '-' ? -magnitude : magnitude;
  }

  // CLI references can express null; live function and object handles belong to the embedding API.
  if (type.endsWith('ref')) {
    // Reject arbitrary strings rather than constructing an untyped or forged host handle.
    if (argument !== 'null')
      throw new Error(`${type} CLI argument must be null; use the API for live references`);

    return null;
  }

  // Preserve the familiar infinity spellings while leaving declared-width rounding to the interpreter.
  const value =
    argument === 'inf' || argument === '+inf' ? Infinity : argument === '-inf' ? -Infinity : Number(argument);

  // Only explicit NaN spellings may become NaN; malformed numeric text must not silently turn into one.
  if (
    !argument.length ||
    argument.trim() !== argument ||
    (Number.isNaN(value) && !/^[+-]?nan$/i.test(argument))
  ) {
    throw new Error(`${type} argument must be a number`);
  }

  return value;
}

/**
 * Invoke a named export from WAT or binary input using the selected runtime and instruction budget.
 *
 * @param {string[]} arguments_
 * @param {WasiLoadOptions} options
 * @returns {Promise<void>}
 */
async function runExportCli(arguments_, { runtime, fuel }) {
  const [file, name, ...values] = arguments_;

  // Require both a guest file and a named export before constructing the interpreter.
  if (!file || name === undefined) throw new Error(cliUsage);

  const interpreter = await (runtime === 'wat' ? createInterpreter() : createBootstrapInterpreter());

  // Apply fuel before loading so automatic module start functions cannot escape the requested budget.
  interpreter.setFuel64(/** @type {bigint} */ (fuel));

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
  const args = values.map(
    /**
     * Parse one CLI argument according to its declared guest parameter type.
     *
     * @param {string} argument
     * @param {number} index
     * @returns {number | bigint | null}
     */
    (argument, index) => cliArgument(argument, /** @type {ValueTypeName} */ (signature.params[index]))
  );
  const value = interpreter.invoke(name, ...args);

  // Void exports produce no output in either text or binary mode.
  if (value === undefined) return;

  // Multi-value returns retain order and an explicit type on every output line.
  if (Array.isArray(signature.result)) {
    const resultTypes = signature.result;

    // Format each result using its corresponding declared type rather than coercing the array to a comma-separated string.
    /** @type {unknown[]} */ (value).forEach(
      /**
       * Print one multivalue CLI result with its declared type label.
       *
       * @param {unknown} result
       * @param {number} index
       * @returns {void}
       */
      (result, index) =>
        console.log(
          `${resultTypes[index]}: ${cliResult(result, /** @type {ValueTypeName} */ (resultTypes[index]))}`
        )
    );
  } else {
    // Keep single numeric scalar output compatible; vectors and references require their type label.
    const resultType = /** @type {ValueTypeName} */ (signature.result);
    const typed = resultType === 'v128' || resultType.endsWith('ref');

    console.log(`${typed ? resultType + ': ' : ''}${cliResult(value, resultType)}`);
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
