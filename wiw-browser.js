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
 * @property {(name: string, args?: string[]) => string} execute
 * @property {(view?: BrowserMemoryView) => BrowserState} inspect
 */

/** @typedef {{memory: string, offset: string, length: number}} BrowserMemoryView */
/** @typedef {{name: string, type: ValueTypeName, value: string}} BrowserGlobal */
/** @typedef {{name: string, address: string, pages: number}} BrowserMemory */
/** @typedef {{globals: BrowserGlobal[], memories: BrowserMemory[], memory?: string, offset?: string, length?: number, dump: string}} BrowserState */

/** @typedef {{action: 'compile', source: string} | {action: 'execute', name: string, args: string[]} | {action: 'inspect', view: BrowserMemoryView}} BrowserRequest */
/** @typedef {{compileMs?: number, executeMs?: number}} BrowserTiming */
/** @typedef {BrowserRunResult & {ok: boolean, functions?: BrowserFunction[], state?: BrowserState, timing?: BrowserTiming}} BrowserResponse */

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
 * Parse an exact integer literal, accepting signed values or unsigned bit patterns without rounding.
 * @param {string} text
 * @param {ValueTypeName} type
 * @returns {number | bigint}
 */
export function parseBrowserInteger(text, type) {
	// Other parameter kinds need their own input controls and conversion rules.
	if (type !== 'i32' && type !== 'i64') throw new Error(`Unsupported parameter type: ${type}`);

	const literal = text.trim();

	// BigInt preserves all i64 digits; reject blanks, fractions and exponent notation explicitly.
	if (!/^[+-]?(?:[0-9]+|0x[0-9a-f]+)$/i.test(literal)) {
		throw new Error(`Enter an ${type} integer in decimal or hexadecimal (0x…).`);
	}

	const negative = literal.startsWith('-');
	const magnitude = BigInt(literal.replace(/^[+-]/, ''));
	const value = negative ? -magnitude : magnitude;
	const bits = type === 'i32' ? 32 : 64;

	// Accept Wasm's signed range and unsigned literal range, then interpret the same bits as signed.
	if (value < -(1n << BigInt(bits - 1)) || value >= 1n << BigInt(bits)) {
		throw new Error(
			`${type} integer is out of range (${-(1n << BigInt(bits - 1))} to ${(1n << BigInt(bits)) - 1n}).`
		);
	}

	const signed = BigInt.asIntN(bits, value);

	return type === 'i32' ? Number(signed) : signed;
}

/**
 * Identify scalar parameter kinds with text inputs in the browser interface.
 * @param {ValueTypeName} type
 * @returns {boolean}
 */
function supportsBrowserArgument(type) {
	return type === 'i32' || type === 'i64' || type === 'f32' || type === 'f64';
}

/**
 * Parse scalar input with exact integer widths and explicit floating-point special values.
 * @param {string} text
 * @param {ValueTypeName} type
 * @returns {number | bigint}
 */
export function parseBrowserArgument(text, type) {
	// Retain exact integer parsing instead of passing i64 values through Number.
	if (type === 'i32' || type === 'i64') return parseBrowserInteger(text, type);

	// Vectors and references need different controls and cannot be represented by scalar text.
	if (type !== 'f32' && type !== 'f64') throw new Error(`Unsupported parameter type: ${type}`);

	const literal = text.trim();

	// Special values must be intentional; malformed or overflowing decimals must not become NaN/infinity.
	if (/^[+-]?nan$/i.test(literal)) return NaN;
	if (/^[+-]?(?:inf|infinity)$/i.test(literal)) return literal.startsWith('-') ? -Infinity : Infinity;
	if (!/^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:e[+-]?[0-9]+)?$/i.test(literal)) {
		throw new Error(`Enter an ${type} decimal number, inf, -inf or NaN.`);
	}

	const value = Number(literal);
	const rounded = type === 'f32' ? Math.fround(value) : value;

	// Finite decimal overflow is rejected, while rounding and underflow retain IEEE signed zero.
	if (!Number.isFinite(rounded))
		throw new Error(`${type} number is out of range. Use inf or -inf for infinity.`);

	return rounded;
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
	/** @type {string[]} */
	const globals = [];
	/** @type {string[]} */
	const memories = [];

	engine.setFuel64(100_000_000n);
	engine.load(source);

	// Discover callable exports without changing guest state through an invocation.
	for (const [name, value] of Object.entries(engine.exportNamespace())) {
		// Resources are available to the module but do not belong in the function selector.
		if (typeof value === 'function') functions.push({ name, ...engine.signature(name) });
		else if (value.kind === 'global') globals.push(name);
		else if (value.kind === 'memory') memories.push(name);
	}

	return {
		functions,

		/**
		 * Copy exported state and a bounded memory window without invoking guest functions.
		 * @param {BrowserMemoryView} [view]
		 * @returns {BrowserState}
		 */
		inspect(view) {
			const state = {
				globals: globals.map(
					/**
					 * Decode each exported global using its declared value kind.
					 * @param {string} name
					 * @returns {BrowserGlobal}
					 */
					(name) => {
						const type = engine.globalType(name);

						return { name, type, value: formatValue(engine.getGlobal(name), type) };
					}
				),
				memories: memories.map(
					/**
					 * Capture current page counts so memory growth appears after execution.
					 * @param {string} name
					 * @returns {BrowserMemory}
					 */
					(name) => ({ name, address: engine.memoryType(name), pages: engine.memoryPages(name) })
				),
				dump: ''
			};
			const memory = view?.memory ?? memories[0];

			// Modules without exported memory still expose globals independently.
			if (memory === undefined) return state;
			if (!memories.includes(memory)) throw new Error(`Unknown memory export: ${memory}`);

			const literal = (view?.offset ?? '0').trim();
			const length = view?.length ?? 128;

			// Bounded reads protect the page and worker from oversized inspection requests.
			if (!/^(?:[0-9]+|0x[0-9a-f]+)$/i.test(literal))
				throw new Error('Memory offset must be a non-negative decimal or hexadecimal integer.');
			if (!Number.isInteger(length) || length < 1 || length > 256)
				throw new Error('Memory byte count must be between 1 and 256.');

			const offset = BigInt(literal);
			const size = BigInt(engine.memoryPages(memory)) * 65536n;

			if (offset > size) throw new Error(`Memory offset is beyond the ${size}-byte memory.`);

			const bytes = engine.readMemory(
				engine.memoryType(memory) === 'i64' ? offset : Number(offset),
				Number(size - offset < BigInt(length) ? size - offset : BigInt(length)),
				memory
			);
			const rows = [];

			// Show sixteen bytes per row, retaining exact addresses and printable ASCII alongside hex.
			for (let index = 0; index < bytes.length; index += 16) {
				const row = bytes.subarray(index, index + 16);
				const hex = Array.from(
					row,
					/**
					 * Format one byte as two hexadecimal digits.
					 * @param {number} byte
					 * @returns {string}
					 */
					(byte) => byte.toString(16).padStart(2, '0')
				)
					.join(' ')
					.padEnd(47, ' ');
				const ascii = Array.from(
					row,
					/**
					 * Replace non-printable bytes with a dot in the ASCII column.
					 * @param {number} byte
					 * @returns {string}
					 */
					(byte) => (byte >= 32 && byte <= 126 ? String.fromCharCode(byte) : '.')
				).join('');

				rows.push(`${(offset + BigInt(index)).toString(16).padStart(8, '0')}  ${hex}  |${ascii}|`);
			}

			return {
				...state,
				memory,
				offset: literal,
				length,
				dump: rows.join('\n') || '(No bytes at this offset.)'
			};
		},

		/**
		 * Execute one scalar-parameter export on the initialized guest, renewing its fuel budget.
		 * @param {string} name
		 * @param {string[]} [args]
		 * @returns {string}
		 */
		execute(name, args = []) {
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
			if (signature.params.length !== args.length)
				throw new Error(
					`${name}: requires ${signature.params.length} argument(s), received ${args.length}`
				);

			const values = signature.params.map(
				/**
				 * Convert each input using its declared scalar type before starting guest execution.
				 * @param {ValueTypeName} type
				 * @param {number} index
				 * @returns {number | bigint}
				 */
				(type, index) => {
					try {
						return parseBrowserArgument(args[index] ?? '', type);
					} catch (error) {
						throw new Error(
							`Argument ${index + 1}: ${error instanceof Error ? error.message : String(error)}`
						);
					}
				}
			);

			engine.setFuel64(100_000_000n);
			const result = engine.invoke(name, ...values);

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
	const fuelHint =
		error instanceof WiwError && error.code === 'EXHAUSTED_FUEL'
			? '\nStopped after exhausting the 100,000,000-instruction budget. Each execution gets a fresh budget.'
			: '';
	const location = error instanceof WiwError ? error.location : undefined;

	// Binary/generated offsets and host errors have no trustworthy position in the input editor.
	if (location?.format !== 'wat' || location.line === undefined || location.column === undefined) {
		return { text: message + fuelHint };
	}

	const { line, column } = location;
	const sourceLine = source.split(/\r\n|\r|\n/)[line - 1];

	// Retain the original diagnostic if it points outside the submitted source.
	if (sourceLine === undefined) return { text: message + fuelHint };

	const prefix = [...sourceLine].slice(0, column - 1).join('');
	const gutter = `${line} | `;
	const caret = ' '.repeat(gutter.length) + prefix.replace(/[^\t]/gu, ' ') + '^';
	const end = location.byteOffset === new TextEncoder().encode(source).length;
	const hint =
		error instanceof WiwError && error.code === 'SYNTAX' && end
			? '\nReached the end of the input. Check for an unclosed parenthesis, string or comment.'
			: '';

	return {
		text: `${message} (line ${line}, column ${column})\n\n${gutter}${sourceLine}\n${caret}${hint}${fuelHint}`,
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
	const argumentsElement = document.getElementById('arguments');
	const globalsElement = document.getElementById('globals');
	const memoryElement = document.getElementById('memories');
	const offsetElement = document.getElementById('memory-offset');
	const countElement = document.getElementById('memory-count');
	const refreshElement = document.getElementById('inspect');
	const dumpElement = document.getElementById('memory-dump');
	const memoryInfoElement = document.getElementById('memory-info');
	const timingElement = document.getElementById('timing');

	// Importing this frontend on another page does not require the playground's controls.
	if (
		!(sourceElement instanceof HTMLTextAreaElement) ||
		!(outputElement instanceof HTMLPreElement) ||
		!(compileElement instanceof HTMLButtonElement) ||
		!(executeElement instanceof HTMLButtonElement) ||
		!(functionsElement instanceof HTMLSelectElement) ||
		!(argumentsElement instanceof HTMLDivElement) ||
		!(globalsElement instanceof HTMLPreElement) ||
		!(memoryElement instanceof HTMLSelectElement) ||
		!(offsetElement instanceof HTMLInputElement) ||
		!(countElement instanceof HTMLInputElement) ||
		!(refreshElement instanceof HTMLButtonElement) ||
		!(dumpElement instanceof HTMLPreElement) ||
		!(memoryInfoElement instanceof HTMLParagraphElement) ||
		!(timingElement instanceof HTMLParagraphElement)
	)
		return;

	const source = sourceElement;
	const output = outputElement;
	const compile = compileElement;
	const execute = executeElement;
	const functions = functionsElement;
	const argumentFields = argumentsElement;
	const globalsOutput = globalsElement;
	const memorySelect = memoryElement;
	const memoryOffset = offsetElement;
	const memoryCount = countElement;
	const refresh = refreshElement;
	const memoryDump = dumpElement;
	const memoryInfo = memoryInfoElement;
	const timingOutput = timingElement;
	/** @type {BrowserTiming} */
	let timings = {};
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
	/** @type {BrowserFunction[]} */
	let exports = [];
	/** @type {HTMLInputElement[]} */
	let inputs = [];

	/**
	 * Read the visible editor, including the plain-text fallback.
	 * @returns {string}
	 */
	function sourceText() {
		return editor ? editor.getValue() : source.value;
	}

	/**
	 * Enable execution only for a compiled export with supported scalar parameter types.
	 * @returns {void}
	 */
	function updateControls() {
		compile.disabled = busy;
		functions.disabled = busy || !compiled || !functions.options.length;
		const selected = functions.selectedOptions[0];

		execute.disabled = busy || !compiled || !selected || selected.disabled;

		for (const input of inputs) input.disabled = busy;
		const unavailable = busy || !compiled || !memorySelect.options.length;

		memorySelect.disabled = unavailable;
		memoryOffset.disabled = unavailable;
		memoryCount.disabled = unavailable;
		refresh.disabled = unavailable;
	}

	/**
	 * Build labeled scalar fields for the selected function without changing guest state.
	 * @returns {void}
	 */
	function selectFunction() {
		argumentFields.replaceChildren();
		inputs = [];
		const entry = exports.find(
			/**
			 * Resolve the selected export's declared parameter types.
			 * @param {BrowserFunction} entry
			 * @returns {boolean}
			 */
			(entry) => entry.name === functions.value
		);

		// Unsupported exports stay listed but cannot create executable argument controls.
		if (entry && entry.params.every(supportsBrowserArgument)) {
			for (const [index, type] of entry.params.entries()) {
				const field = document.createElement('div');
				const label = document.createElement('label');
				const input = document.createElement('input');

				input.id = `argument-${index}`;
				input.type = 'text';
				input.required = true;
				input.spellcheck = false;
				input.placeholder =
					type === 'i32' || type === 'i64'
						? 'Decimal or 0x hexadecimal'
						: 'Decimal, inf, -inf or NaN';
				input.setAttribute('aria-describedby', 'function-hint');
				label.htmlFor = input.id;
				label.textContent = `Argument ${index + 1} (${type})`;
				input.addEventListener(
					'input',
					/**
					 * Remove the previous validation message while the user corrects this input.
					 * @returns {void}
					 */
					() => input.setCustomValidity('')
				);
				field.append(label, input);
				argumentFields.append(field);
				inputs.push(input);
			}
		}

		updateControls();
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
		argumentFields.replaceChildren();
		exports = [];
		memorySelect.replaceChildren();
		globalsOutput.textContent = 'Compile to inspect globals.';
		memoryDump.textContent = 'Compile to inspect memory.';
		memoryInfo.textContent = '';
		timings = {};
		timingOutput.textContent = '';
		inputs = [];
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
	functions.addEventListener('change', selectFunction);

	/**
	 * Display a completed request and retain accurate source diagnostics.
	 * @param {BrowserResponse} result
	 * @returns {void}
	 */
	function finish(result) {
		clearTimeout(timeout);
		busy = false;
		if (result.text) output.textContent = result.text;

		// Snapshot strings are rendered as text, preserving arbitrary export names safely.
		if (result.state) {
			globalsOutput.textContent =
				result.state.globals
					.map(
						/**
						 * Display each global's declared kind beside its current value.
						 * @param {BrowserGlobal} global
						 * @returns {string}
						 */
						(global) => `${global.name}: ${global.type}: ${global.value}`
					)
					.join('\n') || '(No exported globals.)';
			memorySelect.replaceChildren();

			for (const memory of result.state.memories) {
				memorySelect.add(
					new Option(`${memory.name} (${memory.address}, ${memory.pages} pages)`, memory.name)
				);
			}

			memorySelect.value = result.state.memory ?? '';
			memoryOffset.value = result.state.offset ?? '0';
			memoryCount.value = String(result.state.length ?? 128);
			memoryDump.textContent = result.state.dump || '(No exported memory.)';
			memoryInfo.textContent = result.state.memories.length
				? 'Read-only hex/ASCII view. Up to 256 bytes; refreshed after execution.'
				: '';
		}

		// A successful compile supplies metadata without invoking any exported function.
		if (result.functions) {
			compiled = true;
			exports = result.functions;
			functions.replaceChildren();

			for (const entry of result.functions) {
				const results =
					entry.result === null ? [] : Array.isArray(entry.result) ? entry.result : [entry.result];
				const option = new Option(
					`${entry.name} (${entry.params.join(', ')}) → ${results.join(', ') || 'void'}`,
					entry.name
				);

				// Vectors and references stay listed while their unsupported inputs remain disabled.
				option.disabled = !entry.params.every(supportsBrowserArgument);
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
			selectFunction();
		} else if (!result.ok && !compiled) {
			// Failed validation or initialization cannot leave a usable guest behind.
			reset();
		}

		// Keep compilation and the most recent invocation timings separate from state inspection.
		if (result.timing) {
			timings = { ...timings, ...result.timing };
			const parts = [];

			if (timings.compileMs !== undefined) parts.push(`Compile: ${timings.compileMs.toFixed(3)} ms`);
			if (timings.executeMs !== undefined) parts.push(`Execute: ${timings.executeMs.toFixed(3)} ms`);

			timingOutput.textContent = parts.join(' · ');
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
		if (request.action !== 'inspect')
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
		memoryOffset.value = '0';
		memoryCount.value = '128';

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

		const entry = exports.find(
			/**
			 * Resolve the selected function before validating its argument controls.
			 * @param {BrowserFunction} entry
			 * @returns {boolean}
			 */
			(entry) => entry.name === functions.value
		);

		if (!entry) return;

		// Validate all inputs before sending anything that can change the guest instance.
		for (const [index, input] of inputs.entries()) {
			try {
				parseBrowserArgument(input.value, entry.params[index] ?? 'i32');
				input.setCustomValidity('');
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);

				input.setCustomValidity(message);
				input.reportValidity();
				output.textContent = `Argument ${index + 1}: ${message}`;
				return;
			}
		}

		send({
			action: 'execute',
			name: functions.value,
			args: inputs.map(
				/**
				 * Transfer original text so the worker independently checks scalar values.
				 * @param {HTMLInputElement} input
				 * @returns {string}
				 */
				(input) => input.value
			)
		});
	}

	/**
	 * Refresh the selected memory window without executing guest code.
	 * @returns {void}
	 */
	function inspectMemory() {
		// Inspection is available only for an initialized guest with exported memory.
		if (refresh.disabled) return;

		send({
			action: 'inspect',
			view: {
				memory: memorySelect.value,
				offset: memoryOffset.value,
				length: Number(memoryCount.value)
			}
		});
	}

	/**
	 * Start a new memory selection at its first byte.
	 * @returns {void}
	 */
	function selectMemory() {
		memoryOffset.value = '0';
		inspectMemory();
	}

	refresh.addEventListener('click', inspectMemory);
	memorySelect.addEventListener('change', selectMemory);
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
	/** @type {BrowserMemoryView | undefined} */
	let view;

	globalThis.onmessage =
		/**
		 * Initialize once, then execute explicit requests against that same guest instance.
		 * @param {MessageEvent<BrowserRequest>} event
		 * @returns {Promise<void>}
		 */
		async (event) => {
			const request = event.data;
			/** @type {BrowserTiming} */
			const timing = {};

			// Guest failures retain source diagnostics; a failed compilation discards the previous session.
			try {
				if (request.action === 'compile') {
					session = undefined;
					view = undefined;
					source = request.source;
					const started = performance.now();

					// Record initialization failures too, without including inspection or message delivery.
					try {
						session = await compileWat(source);
					} finally {
						timing.compileMs = performance.now() - started;
					}
					globalThis.postMessage({
						ok: true,
						functions: session.functions,
						timing,
						state: session.inspect(),
						text: session.functions.length
							? 'Module initialized. Select a function and press Execute. Scalar parameters can be entered below.'
							: 'Module initialized (no function exports).'
					});
				} else {
					if (!session) throw new Error('Compile a module before executing.');

					// Inspection updates the view only after its requested range has been validated.
					if (request.action === 'inspect') {
						const state = session.inspect(request.view);
						view = request.view;
						globalThis.postMessage({ ok: true, text: '', state });
					} else {
						const started = performance.now();
						let text;

						// Invocation timing includes argument conversion and result formatting, but excludes inspection.
						try {
							text = session.execute(request.name, request.args);
						} finally {
							timing.executeMs = performance.now() - started;
						}

						globalThis.postMessage({ ok: true, text, timing, state: session.inspect(view) });
					}
				}
			} catch (error) {
				/** @type {BrowserState | undefined} */
				let state;

				// Inspection failures must never hide the original compilation or guest error.
				if (session) {
					try {
						state = session.inspect(view);
					} catch {
						// Preserve the primary diagnostic when the guest state cannot be read safely.
					}
				}

				globalThis.postMessage({
					ok: false,
					...formatBrowserError(error, source),
					timing,
					...(state ? { state } : {})
				});
			}
		};
}
