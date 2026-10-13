import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import {
	createBootstrapInterpreter,
	createInterpretedInterpreter,
	createMemory,
	compileWat,
	formatBrowserError,
	parseBrowserInteger,
	parseBrowserArgument,
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
      (global (export "value") f32 (f32.const -0))
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
		assert.equal(engine.globalType('value'), 'f32');
		assert.ok(Object.is(engine.getGlobal('value'), -0));
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

// Compilation must discover exports without invoking them, and execution must retain initialized state.
test('browser compilation discovers signatures and executes only selected exports on persistent state', async () => {
	const source = `(module
    (global $value (mut i32) (i32.const 0))
    (func $start i32.const 10 global.set $value)
    (start $start)
    (memory (export "memory") 1)
    (func (export "increment") (result i32)
      global.get $value i32.const 1 i32.add global.set $value global.get $value)
    (func (export "read") (result i32) global.get $value)
    (func (export "trap") unreachable)
    (func (export "argument") (param i64) (result i64) local.get 0)
    (func (export "values") (result i64 f64) i64.const -9 f64.const -0)
    (func (export "void")))`;
	const session = await compileWat(source, binary);

	assert.deepEqual(
		session.functions.map(({ name, params, result }) => ({ name, params, result })),
		[
			{ name: 'increment', params: [], result: 'i32' },
			{ name: 'read', params: [], result: 'i32' },
			{ name: 'trap', params: [], result: null },
			{ name: 'argument', params: ['i64'], result: 'i64' },
			{ name: 'values', params: [], result: ['i64', 'f64'] },
			{ name: 'void', params: [], result: null }
		]
	);
	assert.equal(session.execute('read'), 'read: i32: 10');
	assert.equal(session.execute('increment'), 'increment: i32: 11');
	assert.equal(session.execute('increment'), 'increment: i32: 12');
	assert.equal(session.execute('read'), 'read: i32: 12');
	assert.equal(session.execute('values'), 'values: i64: -9, f64: -0');
	assert.equal(session.execute('void'), 'void: (no result)');
	assert.throws(() => session.execute('argument'), /requires 1 argument/);
	assert.throws(() => session.execute('missing'), /Unknown function export/);
	assert.throws(() => session.execute('trap'), { code: 'UNREACHABLE' });
	assert.equal(session.execute('read'), 'read: i32: 12');

	const fresh = await compileWat(source, binary);

	assert.equal(fresh.execute('read'), 'read: i32: 10');
	assert.deepEqual((await compileWat('(module)', binary)).functions, []);
	await assert.rejects(compileWat('(module (', binary), { phase: 'load' });
	await assert.rejects(compileWat('(module (func $start unreachable) (start $start))', binary), {
		code: 'UNREACHABLE'
	});
});

// Integer input must preserve all i64 bits and reject invalid values before mutating the guest.
test('browser integer arguments preserve widths, validate literals and invoke mixed signatures', async () => {
	const session = await compileWat(
		`(module
    (global $calls (mut i32) (i32.const 0))
    (func (export "mixed") (param i32 i64) (result i32 i64)
      global.get $calls i32.const 1 i32.add global.set $calls
      local.get 0 local.get 1)
    (func (export "calls") (result i32) global.get $calls)
    (func (export "vector") (param v128)))`,
		binary
	);

	assert.equal(
		session.execute('mixed', ['-2147483648', '9223372036854775807']),
		'mixed: i32: -2147483648, i64: 9223372036854775807'
	);
	assert.equal(session.execute('mixed', ['0xffffffff', '0xffffffffffffffff']), 'mixed: i32: -1, i64: -1');
	assert.equal(
		session.execute('mixed', ['+0x2a', '-0x8000000000000000']),
		'mixed: i32: 42, i64: -9223372036854775808'
	);
	assert.equal(session.execute('mixed', ['0', '9007199254740993']), 'mixed: i32: 0, i64: 9007199254740993');

	for (const args of [
		[],
		['1'],
		['1', '2', '3'],
		['', '1'],
		['1.5', '1'],
		['1', '1e3'],
		['4294967296', '1'],
		['-2147483649', '1'],
		['1', '18446744073709551616'],
		['1', '-9223372036854775809']
	]) {
		assert.throws(() => session.execute('mixed', args));
	}

	assert.throws(() => session.execute('vector', ['1']), /Unsupported parameter type: v128/);
	assert.equal(session.execute('calls'), 'calls: i32: 4');
	assert.equal(parseBrowserInteger('  +42  ', 'i32'), 42);
	assert.equal(parseBrowserInteger('18446744073709551615', 'i64'), -1n);

	for (const literal of ['', ' ', '0x', '1_000', 'NaN', 'Infinity', '--1', '2.0', '1e2']) {
		assert.throws(() => parseBrowserInteger(literal, 'i64'));
	}
});

// Float arguments must preserve signed zero and distinguish deliberate special values from invalid input.
test('browser float arguments round f32, preserve f64 and validate before guest execution', async () => {
	const session = await compileWat(
		`(module
    (global $calls (mut i32) (i32.const 0))
    (func (export "echo") (param f32 f64) (result f32 f64)
      global.get $calls i32.const 1 i32.add global.set $calls
      local.get 0 local.get 1)
    (func (export "mixed") (param i32 i64 f32 f64) (result i32 i64 f32 f64)
      local.get 0 local.get 1 local.get 2 local.get 3)
    (func (export "calls") (result i32) global.get $calls))`,
		binary
	);

	assert.equal(session.execute('echo', ['0.1', '0.1']), 'echo: f32: 0.10000000149011612, f64: 0.1');
	assert.equal(session.execute('echo', ['-0', '-0.0e3']), 'echo: f32: -0, f64: -0');
	assert.equal(session.execute('echo', ['inf', '-Infinity']), 'echo: f32: Infinity, f64: -Infinity');
	assert.equal(session.execute('echo', ['NaN', '-nan']), 'echo: f32: NaN, f64: NaN');
	assert.equal(session.execute('echo', ['-1e-100', '-1e-400']), 'echo: f32: -0, f64: -0');
	assert.equal(
		session.execute('mixed', ['42', '9007199254740993', '1.5', '2.25']),
		'mixed: i32: 42, i64: 9007199254740993, f32: 1.5, f64: 2.25'
	);

	for (const args of [
		['', '1'],
		['0x1', '1'],
		['1e39', '1'],
		['1', '1e309'],
		['1', '1e'],
		['1', 'nan:0x1']
	]) {
		assert.throws(() => session.execute('echo', args));
	}

	assert.equal(session.execute('calls'), 'calls: i32: 5');
	assert.equal(parseBrowserArgument(' +.5E+2 ', 'f64'), 50);
	assert.equal(parseBrowserArgument('1.', 'f32'), 1);
	assert.equal(parseBrowserArgument('+Infinity', 'f32'), Infinity);
	assert.ok(Object.is(parseBrowserArgument('-0', 'f32'), -0));
	assert.ok(Number.isNaN(parseBrowserArgument('+NaN', 'f64')));
	assert.equal(parseBrowserArgument('3.4028234663852886e38', 'f32'), Math.fround(3.4028234663852886e38));
	assert.equal(parseBrowserArgument('1.7976931348623157e308', 'f64'), Number.MAX_VALUE);
	assert.equal(parseBrowserArgument('9007199254740993', 'i64'), 9007199254740993n);

	for (const type of ['f32', 'f64']) {
		for (const value of ['', ' ', '.', '1e', '1.2.3', '1_000', '0x1p0', 'Infinity!', '--1', '1e9999']) {
			assert.throws(() => parseBrowserArgument(value, type));
		}
	}
});

// State inspection must remain read-only and expose guest writes, growth and pre-trap side effects.
test('browser inspector snapshots exported globals and bounded memory windows', async () => {
	const session = await compileWat(
		`(module
    (memory (export "bytes") 1 2)
    (memory (export "other") 1)
    (global $count (export "count") (mut i32) (i32.const 0))
    (global (export "wide") i64 (i64.const 9007199254740993))
    (global (export "float") f64 (f64.const -0))
    (global (export "vector") v128 (v128.const i32x4 1 2 3 4))
    (global (export "reference") externref (ref.null extern))
    (data (i32.const 0) "Hello")
    (data (memory 1) (i32.const 0) "Other")
    (func (export "write") (param i32)
      local.get 0 global.set $count
      i32.const 5 local.get 0 i32.store8)
    (func (export "grow") i32.const 1 memory.grow drop)
    (func (export "trap")
      i32.const 99 global.set $count
      i32.const 6 i32.const 88 i32.store8 unreachable))`,
		binary
	);
	const initial = session.inspect();

	assert.equal(initial.memory, 'bytes');
	assert.deepEqual(initial.memories, [
		{ name: 'bytes', address: 'i32', pages: 1 },
		{ name: 'other', address: 'i32', pages: 1 }
	]);
	assert.deepEqual(initial.globals.slice(0, 3), [
		{ name: 'count', type: 'i32', value: '0' },
		{ name: 'wide', type: 'i64', value: '9007199254740993' },
		{ name: 'float', type: 'f64', value: '-0' }
	]);
	assert.match(initial.globals[3].value, /^0x/);
	assert.deepEqual(initial.globals[4], { name: 'reference', type: 'externref', value: 'null' });
	assert.match(initial.dump, /^00000000  48 65 6c 6c 6f/);
	assert.match(initial.dump, /\|Hello/);
	session.execute('write', ['33']);
	assert.equal(session.inspect().globals[0].value, '33');
	assert.match(
		session.inspect({ memory: 'bytes', offset: '0x5', length: 1 }).dump,
		/^00000005  21 .*\|!\|$/
	);
	assert.match(session.inspect({ memory: 'other', offset: '0', length: 5 }).dump, /\|Other\|$/);
	assert.throws(() => session.execute('trap'), { code: 'UNREACHABLE' });
	assert.equal(session.inspect().globals[0].value, '99');
	assert.match(session.inspect({ memory: 'bytes', offset: '6', length: 1 }).dump, /58 .*\|X\|$/);
	session.execute('grow');
	assert.equal(session.inspect().memories[0].pages, 2);
	assert.equal(initial.memories[0].pages, 1);
	assert.match(session.inspect({ memory: 'bytes', offset: '131071', length: 128 }).dump, /0001ffff  00/);
	assert.equal(
		session.inspect({ memory: 'bytes', offset: '131072', length: 1 }).dump,
		'(No bytes at this offset.)'
	);

	for (const view of [
		{ memory: 'missing', offset: '0', length: 1 },
		{ memory: 'bytes', offset: '-1', length: 1 },
		{ memory: 'bytes', offset: '1.5', length: 1 },
		{ memory: 'bytes', offset: '131073', length: 1 },
		{ memory: 'bytes', offset: '0', length: 0 },
		{ memory: 'bytes', offset: '0', length: 257 }
	])
		assert.throws(() => session.inspect(view));

	assert.equal(session.inspect().globals[0].value, '99');
	assert.deepEqual((await compileWat('(module)', binary)).inspect(), {
		globals: [],
		memories: [],
		dump: ''
	});
	const memory64 = await compileWat(
		'(module (memory (export "wide") i64 1) (data (i64.const 0) "64"))',
		binary
	);

	assert.equal(memory64.inspect().memories[0].address, 'i64');
	assert.match(memory64.inspect().dump, /\|64/);
});
