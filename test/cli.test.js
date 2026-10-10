import assert from 'node:assert/strict';
import { before, after, test } from 'node:test';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { testMode } from './runtime.js';

const cli = new URL('../wiw.js', import.meta.url);
const vector = '0xfedcba98765432100123456789abcdef';
const source = `(module
  (func (export "answer") (result i32) i32.const 42)
  (func (export "echoI64") (param i64) (result i64) local.get 0)
  (func (export "echoFloat") (param f64) (result f64) local.get 0)
  (func (export "echoVector") (param v128) (result v128) local.get 0)
  (func (export "echoReference") (param externref) (result externref) local.get 0)
  (func (export "vector") (result v128) v128.const i64x2 0x0123456789abcdef 0xfedcba9876543210)
  (func (export "mixed") (result i32 i64 f32 f64 v128)
    i32.const -7 i64.const -9223372036854775808 f32.const -0 f64.const inf
    v128.const i64x2 0x0123456789abcdef 0xfedcba9876543210)
  (func (export "nothing"))
  (func (export "forever") (loop $again br $again)))`;
let directory, formats;

// Prepare equivalent text and binary fixtures with deliberately misleading extensions.
before(async () => {
  directory = await mkdtemp(join(tmpdir(), 'wiw-cli-'));

  const wat = join(directory, 'source.wat');
  const wasm = join(directory, 'source.wasm');

  await writeFile(wat, source);
  execFileSync('wat2wasm', [wat, '-o', wasm]);

  const text = join(directory, 'text.wasm');
  const binary = join(directory, 'binary.wat');

  await writeFile(text, source);
  await writeFile(binary, await readFile(wasm));

  formats = [
    ['text', text],
    ['binary', binary]
  ];
});

// Release compiler fixtures even when a CLI assertion fails.
after(async () => {
  // Setup can fail before a temporary directory is allocated.
  if (directory) await rm(directory, { recursive: true, force: true });
});

// Invoke the public CLI at the runtime selected by the current check target.
function invoke(arguments_) {
  return spawnSync(
    process.execPath,
    ['--disable-warning=ExperimentalWarning', cli.pathname, '--runtime', testMode, ...arguments_],
    {
      encoding: 'utf8',
      timeout: 15_000
    }
  );
}

// Compare the complete process outcome so successful execution cannot hide output or stderr regressions.
function output(result, expected) {
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, '');
  assert.equal(result.stdout, expected);
}

test(`${testMode}: CLI detects WAT/Wasm contents and preserves scalar, vector and multi-value results`, () => {
  const cases = [
    ['answer', [], '42\n'],
    ['echoI64', ['-9223372036854775808n'], '-9223372036854775808\n'],
    ['echoI64', ['0xffffffffffffffff'], '-1\n'],
    ['echoI64', ['-0x8000000000000000n'], '-9223372036854775808\n'],
    ['echoI64', ['18446744073709551615n'], '-1\n'],
    ['echoFloat', ['-0'], '-0\n'],
    ['echoFloat', ['-inf'], '-Infinity\n'],
    ['echoFloat', ['NaN'], 'NaN\n'],
    ['echoVector', [vector + 'n'], `v128: ${vector}\n`],
    ['echoVector', ['-1'], 'v128: 0xffffffffffffffffffffffffffffffff\n'],
    ['echoVector', ['-0x1'], 'v128: 0xffffffffffffffffffffffffffffffff\n'],
    ['echoVector', ['1'], 'v128: 0x00000000000000000000000000000001\n'],
    ['echoReference', ['null'], 'externref: null\n'],
    ['vector', [], `v128: ${vector}\n`],
    ['mixed', [], `i32: -7\ni64: -9223372036854775808\nf32: -0\nf64: Infinity\nv128: ${vector}\n`],
    ['nothing', [], '']
  ];

  // Equivalent semantics must survive both input decoders regardless of filename extension.
  for (const [, file] of formats) {
    // Cover width boundaries and mixed signatures independently of the guest format.
    for (const [name, arguments_, expected] of cases) output(invoke([file, name, ...arguments_]), expected);
  }
});

test(`${testMode}: CLI rejects malformed values, invalid arity and unrepresentable wide arguments`, () => {
  const cases = [
    ['echoI64', [''], /decimal or hexadecimal integer/],
    ['echoI64', ['12.5'], /decimal or hexadecimal integer/],
    ['echoI64', ['18446744073709551616'], /i64 BigInt/],
    ['echoVector', [(1n << 128n).toString()], /v128 BigInt/],
    ['echoFloat', ['typo'], /argument must be a number/],
    ['echoFloat', [''], /argument must be a number/],
    ['echoFloat', [' 1'], /argument must be a number/],
    ['echoReference', ['not-a-handle'], /use the API for live references/],
    ['echoI64', [], /argument mismatch/],
    ['answer', ['1'], /argument mismatch/],
    ['missing', [], /unknown export/]
  ];
  const file = formats[1][1];

  // Each bad argument must fail before printing a misleading or partially decoded result.
  for (const [name, arguments_, expected] of cases) {
    const result = invoke([file, name, ...arguments_]);

    assert.equal(result.status, 1);
    assert.equal(result.stdout, '');
    assert.match(result.stderr, expected);
  }
});

test(`${testMode}: CLI fuel supports the full u64 range and bounds exports and automatic starts`, async () => {
  // The same instruction budget must constrain text and binary exports.
  for (const [, file] of formats) {
    // High-bit budgets must not wrap through the old unsigned i32 fuel ABI.
    for (const fuel of ['4294967296', '18446744073709551615']) {
      output(invoke(['--fuel', fuel, file, 'answer']), '42\n');
    }

    // Exhaustion must terminate a looping export and produce no successful result.
    for (const [fuel, name] of [
      ['0', 'answer'],
      ['100', 'forever']
    ]) {
      const result = invoke(['--fuel', fuel, file, name]);

      assert.equal(result.error, undefined);
      assert.equal(result.status, 1);
      assert.equal(result.stdout, '');
      assert.match(result.stderr, /exhausted fuel/);
    }
  }

  const wat = join(directory, 'start.wat');
  const wasm = join(directory, 'start.wasm');

  await writeFile(
    wat,
    '(module (func $start (loop $again br $again)) (start $start) (func (export "answer") (result i32) i32.const 42))'
  );
  execFileSync('wat2wasm', [wat, '-o', wasm]);

  // Fuel must already be active during loading, before the requested export can run.
  for (const file of [wat, wasm]) {
    const result = invoke(['--fuel', '100', file, 'answer']);

    assert.equal(result.error, undefined);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /exhausted fuel/);
  }

  // Invalid budgets must be rejected before any guest or interpreter file is loaded.
  for (const fuel of ['-1', '1.5', 'abc', '18446744073709551616']) {
    const result = invoke(['--fuel', fuel, 'does-not-exist', 'answer']);

    assert.equal(result.status, 1);
    assert.match(result.stderr, /fuel must be/);
    assert.doesNotMatch(result.stderr, /ENOENT/);
  }
});

test(`${testMode}: CLI rejects malformed source and documents common fuel and binary support`, async () => {
  const file = join(directory, 'malformed');

  await writeFile(file, Uint8Array.of(0xff));

  const text = invoke([file, 'answer']);

  assert.equal(text.status, 1);
  assert.match(text.stderr, /encoded data|encoding/i);

  await writeFile(file, Uint8Array.of(0, 97, 115, 109, 1));

  const binary = invoke([file, 'answer']);

  assert.equal(binary.status, 1);
  assert.match(binary.stderr, /invalid syntax/);
  assert.equal(binary.stdout, '');

  const help = invoke(['--help']);

  assert.equal(help.status, 0, help.stderr);
  assert.match(help.stdout, /<guest.wat\|guest.wasm>/);
  assert.match(help.stdout, /--fuel INTEGER\s+Unsigned 64-bit per-invocation fuel/);
  assert.match(help.stdout, /Multiple results use one typed line/);
});
