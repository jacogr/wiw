import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {WiwException} from '../wiw.js';
import {createInterpreter} from '../wiw.js';

const binary = new URL('../build/wiw-opt.wasm', import.meta.url);

test('wiw-opt.wasm: mixed memory widths preserve data across growth and reject wrapped copy addresses', async () => {
  const engine = await createInterpreter(binary);
  engine.load(`(module
    (memory $small 1 3)
    (memory $wide i64 1 3)
    (data (memory $small) (i32.const 0) "A")
    (data (memory $wide) (i64.const 0) "B")
    (func (export "small") (result i32) (i32.load8_u $small (i32.const 0)))
    (func (export "wide") (result i32) (i32.load8_u $wide (i64.const 0)))
    (func (export "grow") (result i32) (memory.grow $small (i32.const 1)))
    (func (export "copy") (param i64) (memory.copy $small $wide (i32.const 1) (local.get 0) (i32.const 1)))
    (func (export "copied") (result i32) (i32.load8_u $small (i32.const 1))))`);
  assert.equal(engine.invoke('small'), 65);
  assert.equal(engine.invoke('wide'), 66);
  assert.equal(engine.invoke('grow'), 1);
  assert.equal(engine.invoke('wide'), 66);
  engine.invoke('copy', 0n);
  assert.equal(engine.invoke('copied'), 66);
  for (const offset of [1n << 32n, -(1n << 32n), -1n]) {
    assert.throws(() => engine.invoke('copy', offset), /memory out of bounds/);
    assert.equal(engine.invoke('copied'), 66);
  }
});

test('wiw-opt.wasm: typed function references compose globals, null branches and tail calls', async () => {
  const engine = await createInterpreter(binary);
  engine.load(`(module
    (type $t (func (param i32) (result i32)))
    (func $twice (type $t) (i32.mul (local.get 0) (i32.const 2)))
    (elem declare func $twice)
    (global $f (ref $t) (ref.func $twice))
    (func $apply (param i32 (ref null $t)) (result i32)
      (block $null (local.get 0) (return_call_ref $t (br_on_null $null (local.get 1))))
      (i32.const -1))
    (func (export "run") (param i32) (result i32) (call $apply (local.get 0) (global.get $f)))
    (func (export "null") (result i32) (call $apply (i32.const 3) (ref.null $t)))
    (func (export "trap") (result i32) (call_ref $t (i32.const 3) (ref.as_non_null (ref.null $t)))))`);
  assert.equal(engine.invoke('run', 21), 42);
  assert.equal(engine.invoke('null'), -1);
  assert.throws(() => engine.invoke('trap'), /null reference/);
  assert.equal(engine.invoke('run', -4), -8);
});

test('wiw-opt.wasm: wide logical memory and table addresses never wrap into their backing arenas', async () => {
  const engine = await createInterpreter(binary);
  engine.load(`(module
    (memory i64 1 2)
    (table i64 1 2 funcref)
    (func (export "load") (param i64) (result i32) (i32.load8_u (local.get 0)))
    (func (export "table") (param i64) (result i32) (ref.is_null (table.get (local.get 0))))
    (func (export "grow") (param i64) (result i64) (memory.grow (local.get 0))))`);
  assert.equal(engine.invoke('table', 0n), 1);
  for (const address of [1n << 32n, -(1n << 32n), -1n]) {
    assert.throws(() => engine.invoke('load', address), /memory out of bounds/);
    assert.throws(() => engine.invoke('table', address), /table out of bounds/);
    assert.equal(engine.invoke('grow', address), -1n);
  }
  assert.equal(engine.invoke('grow', 1n), 1n);
});

// Checked-in wire bytes cover features WABT's GC text reader cannot emit.
async function fixture(name) {
  const root = new URL(`./fixtures/spec3/${name}`, import.meta.url);
  return {
    source: await readFile(new URL(root.href + '.wat'), 'utf8'),
    bytes: Uint8Array.from(Buffer.from((await readFile(new URL(root.href + '.hex'), 'utf8')).replace(/\s/g, ''), 'hex'))
  };
}

for (const name of ['gc', 'recursive']) {
  test(`wiw-opt.wasm: ${name} wire types, constructors and constants agree with native execution`, async () => {
    const {source, bytes} = await fixture(name);
    const native = (await WebAssembly.instantiate(bytes)).instance.exports;
    const text = await createInterpreter(binary);
    const wire = await createInterpreter(binary);
    text.load(source); wire.loadBinary(bytes);
    for (const entry of Object.keys(native)) {
      const expected = native[entry]();
      assert.equal(text.invoke(entry), expected, `${entry} text`);
      assert.equal(wire.invoke(entry), expected, `${entry} binary`);
    }
    // Every truncation must fail before it can expose a partially loaded module.
    for (let length = 0; length < bytes.length; length++) {
      const prefix = bytes.subarray(0, length);
      if (!WebAssembly.validate(prefix)) assert.throws(() => wire.loadBinary(prefix), /syntax|reference|operand|capacity/, `prefix ${length}`);
    }
    wire.loadBinary(bytes);
    assert.equal(wire.invoke(name === 'gc' ? 'global' : 'run'), 42);
  });
}

test('wiw-opt.wasm: binary exception tags and try tables preserve payloads and uncaught exceptions', async () => {
  const {source, bytes} = await fixture('exceptions');
  // The flag is confined to the independent native oracle process.
  const nativeFlags = WebAssembly.validate(bytes) ? [] : ['--experimental-wasm-exnref'];
  const native = JSON.parse(execFileSync(process.execPath, [...nativeFlags, '--input-type=module', '-e', `
    const {instance} = await WebAssembly.instantiate(Buffer.from(process.argv[1], 'hex'));
    let trapped = false;
    try {instance.exports.uncaught()} catch (error) {trapped = error instanceof WebAssembly.Exception}
    console.log(JSON.stringify({value: instance.exports.run(42), trapped}));
  `, Buffer.from(bytes).toString('hex')], {encoding: 'utf8'}));
  assert.deepEqual(native, {value: 42, trapped: true});
  for (const format of ['text', 'binary']) {
    const engine = await createInterpreter(binary);
    if (format === 'text') engine.load(source); else engine.loadBinary(bytes);
    assert.equal(engine.invoke('run', 42), native.value);
    assert.throws(() => engine.invoke('uncaught'), WiwException);
    assert.equal(engine.invoke('run', -7), -7);
  }
});

test('wiw-opt.wasm: aggregate constants resolve and declare nested forward function references', async () => {
  const engine = await createInterpreter(binary);
  engine.load(`(module
    (type $f (func (result i32)))
    (type $s (struct (field (ref $f))))
    (global $g (ref $s) (struct.new $s (ref.func $answer)))
    (func $answer (type $f) (i32.const 42))
    (func (export "run") (result i32) (call_ref $f (struct.get $s 0 (global.get $g)))))`);
  assert.equal(engine.invoke('run'), 42);
});
