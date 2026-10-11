import {
  createBootstrapInterpreter as createSharedBootstrapInterpreter,
  createInterpretedInterpreter as createSharedInterpretedInterpreter,
  formatValue
} from './wiw-lib.js';

export * from './wiw-lib.js';

/** @typedef {import('./wiw-lib.js').InterpreterApi} InterpreterApi */
/** @typedef {import('./wiw-lib.js').InterpreterOptions} InterpreterOptions */
/** @typedef {import('./wiw-lib.js').RuntimeServices} RuntimeServices */
/** @typedef {import('./wiw-lib.js').CallbackScope} CallbackScope */
/** @typedef {import('./wiw-lib.js').ValueTypeName} ValueTypeName */
/** @typedef {string | URL | WebAssembly.Module} BrowserBootstrapSource */

/**
 * CodeMirror methods used by the page, without coupling the interpreter to editor packages.
 * @typedef {object} WatEditor
 * @property {() => string} getValue
 * @property {() => HTMLTextAreaElement} getInputField
 */

/**
 * Direct-script editor configuration for the WAST mode and accessible input field.
 * @typedef {object} WatEditorOptions
 * @property {string} mode
 * @property {string} theme
 * @property {boolean} lineNumbers
 * @property {boolean} matchBrackets
 * @property {boolean} lineWrapping
 * @property {number} indentUnit
 * @property {number} tabSize
 * @property {string} inputStyle
 * @property {string} screenReaderLabel
 */

/**
 * Minimal classic CodeMirror API loaded from cdnjs by index.html.
 * @typedef {{fromTextArea: (source: HTMLTextAreaElement, options: WatEditorOptions) => WatEditor}} WatEditorFactory
 */

/**
 * Browser globals extended by the optional CDN editor script.
 * @typedef {Window & {CodeMirror?: WatEditorFactory}} EditorWindow
 */

/**
 * Synchronous ownership scopes for browser calls; no ambient scope escapes into unrelated tasks.
 * @template T
 */
class BrowserContext {
  /** @type {T | undefined} */
  current;

  /**
   * Read the scope active on this synchronous JavaScript stack.
   * @returns {T | undefined}
   */
  getStore() {
    return this.current;
  }

  /**
   * Run one synchronous scope and restore its caller even when it throws.
   * @template R
   * @param {T} value
   * @param {() => R} callback
   * @returns {R}
   */
  run(value, callback) {
    const previous = this.current;
    this.current = value;

    // A suspended browser callback must not authorize an unrelated event-loop task.
    try {
      return callback();
    } finally {
      this.current = previous;
    }
  }
}

/** @type {RuntimeServices} */
const runtime = {
  invocationContext: new BrowserContext(),
  callbackContext: new BrowserContext(),

  /**
   * Yield cooperative execution to the browser event loop.
   * @returns {Promise<void>}
   */
  yieldTask() {
    return new Promise(
      /**
       * Schedule a continuation after the current task finishes.
       * @param {() => void} resolve
       * @returns {void}
       */
      (resolve) => {
        setTimeout(resolve, 0);
      }
    );
  }
};

/**
 * Fetch an interpreter artifact and report HTTP failures before compiling or loading it.
 * @param {string | URL} source
 * @returns {Promise<Response>}
 */
async function fetchArtifact(source) {
  const response = await fetch(source);

  // A missing build must produce an actionable error instead of a Wasm magic-byte error.
  if (!response.ok) throw new Error(`Could not load ${source}: HTTP ${response.status}. Run make all first.`);

  return response;
}

/**
 * Fetch the compiled interpreter or retain a caller-owned compiled module.
 * @param {BrowserBootstrapSource} source
 * @returns {Promise<WebAssembly.Module>}
 */
async function bootstrapModule(source) {
  // Compiled modules can be shared while each interpreter gets fresh instance state.
  if (source instanceof WebAssembly.Module) return source;

  const response = await fetchArtifact(source);

  return WebAssembly.compile(await response.arrayBuffer());
}

/**
 * Create the compiled browser interpreter from an HTTP artifact or precompiled module.
 * @param {BrowserBootstrapSource} [binary]
 * @param {InterpreterOptions} [options]
 * @returns {Promise<InterpreterApi>}
 */
export async function createBootstrapInterpreter(
  binary = new URL('./build/wiw-opt.wasm', import.meta.url),
  options = {}
) {
  return createSharedBootstrapInterpreter(await bootstrapModule(binary), options, runtime);
}

/**
 * Retain the embedding API's default self-hosted interpreter in the browser frontend.
 * @param {BrowserBootstrapSource} [binary]
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
 * Fetch the optimized WAT interpreter and execute it inside the compiled browser bootstrap.
 * @param {BrowserBootstrapSource} [binary]
 * @param {InterpreterOptions} [options]
 * @returns {Promise<InterpreterApi>}
 */
export async function createInterpretedInterpreter(
  binary = new URL('./build/wiw-opt.wasm', import.meta.url),
  options = {}
) {
  const module = await bootstrapModule(binary);
  const source =
    options.source ?? (await (await fetchArtifact(new URL('./build/wiw-opt.wat', import.meta.url))).text());

  return createSharedInterpretedInterpreter(module, { ...options, source }, runtime);
}

/**
 * Run a fresh WAT module and show the results of its zero-argument function exports in order.
 * @param {string} source
 * @param {BrowserBootstrapSource} [binary]
 * @returns {Promise<string>}
 */
export async function runWat(source, binary = new URL('./build/wiw-opt.wasm', import.meta.url)) {
  const engine = await createBootstrapInterpreter(binary);
  const lines = [];

  engine.setFuel64(100_000_000n);
  engine.load(source);

  // Resource exports are retained by the engine; only callable exports can be run here.
  for (const [name, value] of Object.entries(engine.exportNamespace())) {
    // Memory, tables, globals and tags have no invocation result.
    if (typeof value !== 'function') continue;

    const signature = engine.signature(name);

    // This single-button interface has no argument editor, so parameterized exports stay uninvoked.
    if (signature.params.length) {
      lines.push(`${name}: requires ${signature.params.length} argument(s)`);
      continue;
    }

    const result = engine.invoke(name);

    // Multivalue results keep their declared order and exact wide numeric patterns.
    if (Array.isArray(signature.result)) {
      const types = signature.result;
      const values = /** @type {unknown[]} */ (result);
      const output = values.map(
        /**
         * Format one result using its declared Wasm kind.
         * @param {unknown} value
         * @param {number} index
         * @returns {string}
         */
        (value, index) =>
          `${types[index]}: ${formatValue(value, /** @type {ValueTypeName} */ (types[index]))}`
      );

      lines.push(`${name}: ${output.join(', ')}`);
    } else if (signature.result === null) {
      // Void functions may have side effects even though they produce no values.
      lines.push(`${name}: (no result)`);
    } else {
      lines.push(`${name}: ${signature.result}: ${formatValue(result, signature.result)}`);
    }
  }

  return lines.length ? lines.join('\n') : 'Module loaded (no function exports).';
}

/**
 * Attach the single-button interface and keep all interpreter execution inside a disposable worker.
 * @returns {void}
 */
function attachInterface() {
  const sourceElement = document.getElementById('wat');
  const outputElement = document.getElementById('output');
  const buttonElement = document.getElementById('run');

  // The browser API can also be imported by pages that do not use this interface.
  if (
    !(sourceElement instanceof HTMLTextAreaElement) ||
    !(outputElement instanceof HTMLPreElement) ||
    !(buttonElement instanceof HTMLButtonElement)
  )
    return;

  const source = sourceElement;
  const output = outputElement;
  const button = buttonElement;
  const codeMirror = /** @type {EditorWindow} */ (window).CodeMirror;
  // Keep the textarea usable if the CDN is unavailable; interpreter execution stays independent.
  const editor = codeMirror?.fromTextArea(source, {
    mode: 'text/webassembly',
    theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'material-darker' : 'default',
    lineNumbers: true,
    matchBrackets: true,
    lineWrapping: false,
    indentUnit: 2,
    tabSize: 2,
    inputStyle: 'textarea',
    screenReaderLabel: 'WAT input'
  });

  // Preserve the original input's help association after CodeMirror creates its editing field.
  if (editor) {
    const input = editor.getInputField();

    input.id = 'wat-editor';
    input.setAttribute('aria-describedby', 'hint');
    document.querySelector('label[for="wat"]')?.setAttribute('for', input.id);
  }

  /**
   * Run the current input in a fresh worker and display either results or the guest diagnostic.
   * @returns {void}
   */
  function run() {
    button.disabled = true;
    output.textContent = 'Running…';

    /** @type {Worker} */
    let worker;

    // Restore the page if the browser rejects worker construction before any event can fire.
    try {
      worker = new Worker(new URL('./wiw-browser.js', import.meta.url), { type: 'module' });
    } catch (error) {
      output.textContent = error instanceof Error ? error.message : String(error);
      button.disabled = false;
      return;
    }

    let finished = false;
    const timeout = setTimeout(
      /**
       * Restore the interface if an artifact fetch or guest run never finishes.
       * @returns {void}
       */
      () => finish('Run timed out after 30 seconds.'),
      30_000
    );

    /**
     * End the worker, restore the button and publish plain text output exactly once.
     * @param {string} text
     * @returns {void}
     */
    function finish(text) {
      // Ignore an already queued error or timeout after a successful worker result.
      if (finished) return;

      finished = true;
      clearTimeout(timeout);
      worker.terminate();
      output.textContent = text;
      button.disabled = false;
    }

    worker.onmessage =
      /**
       * Display the worker's completed run or reported guest error.
       * @param {MessageEvent<string>} event
       * @returns {void}
       */
      (event) => finish(event.data);

    worker.onerror =
      /**
       * Report worker startup or module-loading errors and allow another run.
       * @param {ErrorEvent} event
       * @returns {void}
       */
      (event) => finish(event.message || 'Could not start the interpreter worker.');

    worker.postMessage(editor ? editor.getValue() : source.value);
  }

  button.addEventListener('click', run);
}

// The same module supplies the page frontend and its isolated worker entry point.
if (typeof document !== 'undefined') {
  attachInterface();
} else if (typeof globalThis.postMessage === 'function') {
  globalThis.onmessage =
    /**
     * Interpret one WAT request without compiling guest WAT or importing Node modules.
     * @param {MessageEvent<string>} event
     * @returns {Promise<void>}
     */
    async (event) => {
      // Keep guest errors inside the output area so the next Run starts cleanly.
      try {
        globalThis.postMessage(await runWat(event.data));
      } catch (error) {
        globalThis.postMessage(error instanceof Error ? error.message : String(error));
      }
    };
}
