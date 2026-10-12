import {
	createBootstrapInterpreter as createSharedBootstrapInterpreter,
	createInterpretedInterpreter as createSharedInterpretedInterpreter,
	formatValue,
	WiwError
} from './wiw-lib.js';

export * from './wiw-lib.js';

/** @typedef {import('./wiw-lib.js').InterpreterApi} InterpreterApi */
/** @typedef {import('./wiw-lib.js').InterpreterOptions} InterpreterOptions */
/** @typedef {import('./wiw-lib.js').RuntimeServices} RuntimeServices */
/** @typedef {import('./wiw-lib.js').CallbackScope} CallbackScope */
/** @typedef {import('./wiw-lib.js').ValueTypeName} ValueTypeName */
/** @typedef {import("./wiw-lib.js").PublicSignature} PublicSignature */
/** @typedef {string | URL | WebAssembly.Module} BrowserBootstrapSource */

/**
 * Worker output with optional original WAT coordinates (one-based Unicode columns).
 * @typedef {object} BrowserRunResult
 * @property {string} text
 * @property {number} [line]
 * @property {number} [column]
 */

/**
 * Exported function name and its declared parameter/result types.
 * @typedef {PublicSignature & {name: string}} BrowserFunction
 */

/**
 * Initialized guest retained between explicit function executions.
 * @typedef {object} BrowserSession
 * @property {BrowserFunction[]} functions
 * @property {(name: string) => string} execute
 */

/** @typedef {{action: 'compile', source: string} | {action: 'execute', name: string}} BrowserRequest */
/** @typedef {BrowserRunResult & {ok: boolean, functions?: BrowserFunction[]}} BrowserResponse */

/** @typedef {object} WatEditorLine */

/**
 * CodeMirror methods used by the page, without coupling the interpreter to editor packages.
 * @typedef {object} WatEditor
 * @property {() => string} getValue
 * @property {() => HTMLTextAreaElement} getInputField
 * @property {(line: number, where: string, className: string) => WatEditorLine} addLineClass
 * @property {(line: WatEditorLine, where: string, className: string) => unknown} removeLineClass
 * @property {(position: {line: number, ch: number}) => void} scrollIntoView
 * @property {(event: 'change', callback: () => void) => void} on
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
	if (!response.ok)
		throw new Error(`Could not load ${source}: HTTP ${response.status}. Run make all first.`);

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
		options.source ??
		(await (await fetchArtifact(new URL('./build/wiw-opt.wat', import.meta.url))).text());

	return createSharedInterpretedInterpreter(module, { ...options, source }, runtime);
}

/**
 * Validate and initialize WAT, discovering exports without invoking them.
 * @param {string} source
 * @param {BrowserBootstrapSource} [binary]
 * @returns {Promise<BrowserSession>}
 */
export async function compileWat(source, binary = new URL('./build/wiw-opt.wasm', import.meta.url)) {
	const engine = await createBootstrapInterpreter(binary);
	/** @type {BrowserFunction[]} */
	const functions = [];

	engine.setFuel64(100_000_000n);
	engine.load(source);

	// Discover callable exports without changing guest state through an invocation.
	for (const [name, value] of Object.entries(engine.exportNamespace())) {
		// Resources are available to the module but do not belong in the function selector.
		if (typeof value === 'function') functions.push({ name, ...engine.signature(name) });
	}

	return {
		functions,

		/**
		 * Execute one zero-argument export on the initialized guest, renewing its fuel budget.
		 * @param {string} name
		 * @returns {string}
		 */
		execute(name) {
			const signature = functions.find(
				/**
				 * Match the requested export by its exact name.
				 * @param {BrowserFunction} entry
				 * @returns {boolean}
				 */
				(entry) => entry.name === name
			);

			// Reject unsupported requests before they can mutate the initialized guest.
			if (!signature) throw new Error(`Unknown function export: ${name}`);
			if (signature.params.length)
				throw new Error(`${name}: requires ${signature.params.length} argument(s)`);

			engine.setFuel64(100_000_000n);
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

				return `${name}: ${output.join(', ')}`;
			}

			// Void functions may have side effects even though they produce no values.
			if (signature.result === null) return `${name}: (no result)`;

			return `${name}: ${signature.result}: ${formatValue(result, signature.result)}`;
		}
	};
}

/**
 * Run all zero-argument exports for existing browser API callers.
 * @param {string} source
 * @param {BrowserBootstrapSource} [binary]
 * @returns {Promise<string>}
 */
export async function runWat(source, binary = new URL('./build/wiw-opt.wasm', import.meta.url)) {
	const session = await compileWat(source, binary);
	const lines = session.functions.map(
		/**
		 * Retain the original runner's treatment of parameterized exports.
		 * @param {BrowserFunction} entry
		 * @returns {string}
		 */
		(entry) =>
			entry.params.length
				? `${entry.name}: requires ${entry.params.length} argument(s)`
				: session.execute(entry.name)
	);

	return lines.length ? lines.join('\n') : 'Module loaded (no function exports).';
}

/**
 * Format interpreter coordinates with a source excerpt without guessing the parser's underlying cause.
 * @param {unknown} error
 * @param {string} source
 * @returns {BrowserRunResult}
 */
export function formatBrowserError(error, source) {
	const message = error instanceof Error ? error.message : String(error);
	const location = error instanceof WiwError ? error.location : undefined;

	// Binary/generated offsets and host errors have no trustworthy position in the input editor.
	if (location?.format !== 'wat' || location.line === undefined || location.column === undefined) {
		return { text: message };
	}

	const { line, column } = location;
	const sourceLine = source.split(/\r\n|\r|\n/)[line - 1];

	// Retain the original diagnostic if it points outside the submitted source.
	if (sourceLine === undefined) return { text: message };

	const prefix = [...sourceLine].slice(0, column - 1).join('');
	const gutter = `${line} | `;
	const caret = ' '.repeat(gutter.length) + prefix.replace(/[^\t]/gu, ' ') + '^';
	const end = location.byteOffset === new TextEncoder().encode(source).length;
	const hint =
		error instanceof WiwError && error.code === 'SYNTAX' && end
			? '\nReached the end of the input. Check for an unclosed parenthesis, string or comment.'
			: '';

	return {
		text: `${message} (line ${line}, column ${column})\n\n${gutter}${sourceLine}\n${caret}${hint}`,
		line,
		column
	};
}

/**
 * Attach compilation and explicit execution controls to a persistent, isolated guest worker.
 * @returns {void}
 */
function attachInterface() {
	const sourceElement = document.getElementById('wat');
	const outputElement = document.getElementById('output');
	const compileElement = document.getElementById('compile');
	const executeElement = document.getElementById('execute');
	const functionsElement = document.getElementById('functions');

	// Importing this frontend on another page does not require the playground's controls.
	if (
		!(sourceElement instanceof HTMLTextAreaElement) ||
		!(outputElement instanceof HTMLPreElement) ||
		!(compileElement instanceof HTMLButtonElement) ||
		!(executeElement instanceof HTMLButtonElement) ||
		!(functionsElement instanceof HTMLSelectElement)
	)
		return;

	const source = sourceElement;
	const output = outputElement;
	const compile = compileElement;
	const execute = executeElement;
	const functions = functionsElement;
	const codeMirror = /** @type {EditorWindow} */ (window).CodeMirror;
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

	// Preserve the label and help association after the editor replaces the textarea.
	if (editor) {
		const input = editor.getInputField();

		input.id = 'wat-editor';
		input.setAttribute('aria-describedby', 'hint');
		document.querySelector('label[for="wat"]')?.setAttribute('for', input.id);
	}

	/** @type {Worker | undefined} */
	let worker;
	/** @type {ReturnType<typeof setTimeout> | undefined} */
	let timeout;
	/** @type {WatEditorLine | undefined} */
	let errorMarker;
	let busy = false;
	let compiled = false;
	let submitted = '';

	/**
	 * Read the visible editor, including the plain-text fallback.
	 * @returns {string}
	 */
	function sourceText() {
		return editor ? editor.getValue() : source.value;
	}

	/**
	 * Enable execution only for a compiled, selected zero-argument function.
	 * @returns {void}
	 */
	function updateControls() {
		compile.disabled = busy;
		functions.disabled = busy || !compiled || !functions.options.length;
		const selected = functions.selectedOptions[0];

		execute.disabled = busy || !compiled || !selected || selected.disabled;
	}

	/**
	 * Clear the diagnostic highlight before editing or a new request.
	 * @returns {void}
	 */
	function clearError() {
		// Line handles keep the marker removable even when edits shift its line number.
		if (editor && errorMarker) editor.removeLineClass(errorMarker, 'background', 'wat-error-line');

		errorMarker = undefined;
	}

	/**
	 * Discard guest state and outstanding responses when source or compilation changes.
	 * @returns {void}
	 */
	function reset() {
		clearError();
		clearTimeout(timeout);
		worker?.terminate();
		worker = undefined;
		busy = false;
		compiled = false;
		functions.replaceChildren();
		updateControls();
	}

	/**
	 * Require fresh validation and initialization after any source edit.
	 * @returns {void}
	 */
	function edited() {
		reset();
		output.textContent = 'Source changed. Compile before executing.';
	}

	editor?.on('change', edited);
	source.addEventListener('input', edited);
	functions.addEventListener('change', updateControls);

	/**
	 * Display a completed request and retain accurate source diagnostics.
	 * @param {BrowserResponse} result
	 * @returns {void}
	 */
	function finish(result) {
		clearTimeout(timeout);
		busy = false;
		output.textContent = result.text;

		// A successful compile supplies metadata without invoking any exported function.
		if (result.functions) {
			compiled = true;
			functions.replaceChildren();

			for (const entry of result.functions) {
				const results =
					entry.result === null ? [] : Array.isArray(entry.result) ? entry.result : [entry.result];
				const option = new Option(
					`${entry.name} (${entry.params.join(', ')}) → ${results.join(', ') || 'void'}`,
					entry.name
				);

				// Argument entry is not supported yet; still display these exports and their signatures.
				option.disabled = entry.params.length > 0;
				functions.add(option);
			}

			const first = Array.from(functions.options).find(
				/**
				 * Choose the first export the current interface can execute.
				 * @param {HTMLOptionElement} option
				 * @returns {boolean}
				 */
				(option) => !option.disabled
			);
			functions.value = first?.value ?? '';
		} else if (!result.ok && !compiled) {
			// Failed validation or initialization cannot leave a usable guest behind.
			reset();
		}

		updateControls();

		// Coordinates belong only to the exact source that produced this diagnostic.
		if (
			editor &&
			sourceText() === submitted &&
			result.line !== undefined &&
			result.column !== undefined
		) {
			const line = result.line - 1;
			const text = submitted.split(/\r\n|\r|\n/)[line] ?? '';
			const ch = [...text].slice(0, result.column - 1).join('').length;

			errorMarker = editor.addLineClass(line, 'background', 'wat-error-line');
			editor.scrollIntoView({ line, ch });
		}
	}

	/**
	 * Send one request with a fresh deadline while preserving initialized guest state.
	 * @param {BrowserRequest} request
	 * @returns {void}
	 */
	function send(request) {
		clearError();
		busy = true;
		updateControls();
		output.textContent = request.action === 'compile' ? 'Compiling…' : 'Executing…';
		timeout = setTimeout(
			/**
			 * Terminate a stalled request and require recompilation of discarded guest state.
			 * @returns {void}
			 */
			() => {
				reset();
				output.textContent =
					'Request timed out after 30 seconds. Compile again to create a fresh instance.';
			},
			30_000
		);

		// Worker construction or dispatch failures restore the controls for another attempt.
		try {
			if (!worker) throw new Error('Compile a module before executing.');
			worker.postMessage(request);
		} catch (error) {
			reset();
			output.textContent = error instanceof Error ? error.message : String(error);
		}
	}

	/**
	 * Initialize a fresh module in a worker and request its exported function metadata.
	 * @returns {void}
	 */
	function compileSource() {
		reset();
		submitted = sourceText();

		// Startup failures must leave compilation available and execution disabled.
		try {
			const current = new Worker(new URL('./wiw-browser.js', import.meta.url), { type: 'module' });
			worker = current;
			current.onmessage =
				/**
				 * Ignore results from an instance discarded by edits or a subsequent compilation.
				 * @param {MessageEvent<BrowserResponse>} event
				 * @returns {void}
				 */
				(event) => {
					if (worker === current) finish(event.data);
				};
			current.onerror =
				/**
				 * Discard a broken worker and display its startup or transport error.
				 * @param {ErrorEvent} event
				 * @returns {void}
				 */
				(event) => {
					if (worker !== current) return;

					reset();
					output.textContent = event.message || 'Could not start the interpreter worker.';
				};
			send({ action: 'compile', source: submitted });
		} catch (error) {
			reset();
			output.textContent = error instanceof Error ? error.message : String(error);
		}
	}

	/**
	 * Invoke only the selected export of the current initialized instance.
	 * @returns {void}
	 */
	function executeSelected() {
		// Disabled controls also have a guard against programmatic or stale click dispatch.
		if (execute.disabled) return;

		send({ action: 'execute', name: functions.value });
	}

	compile.addEventListener('click', compileSource);
	execute.addEventListener('click', executeSelected);
	updateControls();
}

// The same module supplies the page frontend and its isolated worker entry point.
if (typeof document !== 'undefined') {
	attachInterface();
} else if (typeof globalThis.postMessage === 'function') {
	/** @type {BrowserSession | undefined} */
	let session;
	let source = '';

	globalThis.onmessage =
		/**
		 * Initialize once, then execute explicit requests against that same guest instance.
		 * @param {MessageEvent<BrowserRequest>} event
		 * @returns {Promise<void>}
		 */
		async (event) => {
			const request = event.data;

			// Guest failures retain source diagnostics; a failed compilation discards the previous session.
			try {
				if (request.action === 'compile') {
					session = undefined;
					source = request.source;
					session = await compileWat(source);
					globalThis.postMessage({
						ok: true,
						functions: session.functions,
						text: session.functions.length
							? 'Module initialized. Select a function and press Execute. Functions requiring arguments are unavailable.'
							: 'Module initialized (no function exports).'
					});
				} else {
					if (!session) throw new Error('Compile a module before executing.');

					globalThis.postMessage({ ok: true, text: session.execute(request.name) });
				}
			} catch (error) {
				globalThis.postMessage({ ok: false, ...formatBrowserError(error, source) });
			}
		};
}
