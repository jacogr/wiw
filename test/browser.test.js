import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import {
	createBootstrapInterpreter,
	createInterpretedInterpreter,
	createMemory,
	formatBrowserError,
	runWat,
	WiwError
} from '../wiw-browser.js';
import { WiwError as NodeWiwError } from '../wiw.js';

const binary = await WebAssembly.compile(await readFile(new URL('../build/wiw-opt.wasm', import.meta.url)));

// Check the page's execution policy, initialization order and exact result formatting.
test('browser runner initializes WAT and runs only zero-argument exports', async () => {
	const output = await runWat(
		`(module
    (global $value (mut i32) (i32.const 0))
    (func $start i32.const 42 global.set $value)
    (start $start)
    (func (export "answer") (result i32) global.get $value)
    (func (export "values") (result i64 f64) i64.const -9 f64.const -0)
    (func (export "ignored") (param i32) unreachable)
    (func (export "done")))`,
		binary
	);

	assert.equal(
		output,
		'answer: i32: 42\nvalues: i64: -9, f64: -0\nignored: requires 1 argument(s)\ndone: (no result)'
	);
	assert.equal(await runWat('(module)', binary), 'Module loaded (no function exports).');
});

// Every click must start with a fresh engine and retain shared diagnostic class identities.
test('browser runner reports guest errors and recovers on the next run', async () => {
	assert.equal(WiwError, NodeWiwError);
	await assert.rejects(runWat('(module (func (export "run") unreachable))', binary), {
		code: 'UNREACHABLE'
	});
	await assert.rejects(runWat('(module (', binary), { phase: 'load' });
	assert.equal(
		await runWat('(module (func (export "run") (result i32) i32.const 7))', binary),
		'run: i32: 7'
	);
});

// Exercise the shared ABI through browser services in both native and self-hosted configurations.
test('browser factories retain resources, synchronous callback reentry and self-hosting', async () => {
	const source = await readFile(new URL('../build/wiw-opt.wat', import.meta.url), 'utf8');

	for (const create of [createBootstrapInterpreter, createInterpretedInterpreter]) {
		const engine = await create(binary, { source });
		const memory = createMemory({ initial: 1 });

		engine.load(
			`(module
      (import "host" "memory" (memory 1))
      (import "host" "callback" (func $callback (result i32)))
      (func (export "inner") (result i32) i32.const 42)
      (func (export "run") (result i32) call $callback))`,
			{
				host: {
					memory,
					callback: () => engine.invoke('inner')
				}
			}
		);

		assert.equal(engine.invoke('run'), 42);
		engine.writeMemory(0, new Uint8Array([7]));
		assert.deepEqual(memory.read(0, 1), new Uint8Array([7]));
	}
});

// Frontend artifact fetches must report missing builds clearly and instantiate successful responses.
test('browser artifact loading uses HTTP and rejects missing interpreter builds', async () => {
	const fetch = globalThis.fetch;
	const bytes = await readFile(new URL('../build/wiw-opt.wasm', import.meta.url));

	try {
		globalThis.fetch = async () => new Response(null, { status: 404 });
		await assert.rejects(createBootstrapInterpreter(), /HTTP 404.*make all/);

		globalThis.fetch = async () => new Response(bytes);
		const engine = await createBootstrapInterpreter();

		engine.load('(module (func (export "answer") (result i32) i32.const 42))');
		assert.equal(engine.invoke('answer'), 42);
	} finally {
		globalThis.fetch = fetch;
	}
});

// Worker diagnostics must retain original WAT coordinates instead of losing them during serialization.
test('browser diagnostics show source coordinates, EOF hints and plain host errors', async () => {
	const source = '(module\n  (func (export "answer") (result i32)\n    i32.const 42)';
	let diagnostic;

	try {
		await runWat(source, binary);
	} catch (error) {
		diagnostic = formatBrowserError(error, source);
	}

	assert.deepEqual(diagnostic, {
		text:
			'invalid syntax at byte 64 (line 3, column 18)\n\n3 |     i32.const 42)\n' +
			' '.repeat(21) +
			'^\nReached the end of the input. Check for an unclosed parenthesis, string or comment.',
		line: 3,
		column: 18
	});
	assert.deepEqual(formatBrowserError(new Error('HTTP 404'), source), { text: 'HTTP 404' });

	const unicodeSource = '(module\r\n;; 🙂\r\n  (func (export "run") unreachable))';

	try {
		await runWat(unicodeSource, binary);
		assert.fail('unreachable must trap');
	} catch (error) {
		const result = formatBrowserError(error, unicodeSource);

		assert.equal(result.line, 3);
		assert.match(result.text, /3 \|   \(func.*unreachable/);
		assert.doesNotMatch(result.text, /Reached the end/);
	}

	const unicodeError = new WiwError('invalid syntax', {
		code: 'SYNTAX',
		location: { format: 'wat', byteOffset: 5, line: 1, column: 3 }
	});

	assert.equal(
		formatBrowserError(unicodeError, '🙂 x').text,
		'invalid syntax (line 1, column 3)\n\n1 | 🙂 x\n      ^'
	);
	assert.deepEqual(
		formatBrowserError(
			new WiwError('binary error', {
				location: { format: 'generated-wat', byteOffset: 8 }
			}),
			source
		),
		{ text: 'binary error' }
	);
});
