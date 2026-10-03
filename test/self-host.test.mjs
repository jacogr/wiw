import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';
import { createInterpreter } from '../wiw.mjs';
const encode = text => new TextEncoder().encode(text);
// Hand-encoded MVP module exporting answer() -> 42; no guest compilation is involved.
const constantBinary = Uint8Array.from([0, 97, 115, 109, 1, 0, 0, 0,
  1, 5, 1, 96, 0, 1, 127, 3, 2, 1, 0,
  7, 10, 1, 6, 97, 110, 115, 119, 101, 114, 0, 0,
  10, 6, 1, 4, 0, 65, 42, 11]);

// Adapt an interpreted engine's exported ABI; source and arguments live in its guest memory.
function interpreted(parent) {
  const call = (name, ...args) => parent.invoke(name, ...args);
  const check = code => assert.equal(code, 0, `interpreted status ${code}, byte ${call('error_offset')}`);
  return {
    load(source) {
      const bytes = encode(source);
      const pages = Math.ceil((4096 + bytes.length) / 65536);
      // Growth is host preparation, while the interpreted engine reserves its own arenas in load.
      if (pages > 1) assert.notEqual(parent.growMemory(pages), -1);
      parent.writeMemory(4096, bytes);
      check(call('load', 4096, bytes.length));
      check(call('initialize'));
    },
    loadBinary(bytes) {
      const pages = Math.ceil((4096 + bytes.length) / 65536);
      if (pages > 1) assert.notEqual(parent.growMemory(pages), -1);
      parent.writeMemory(4096, bytes);
      check(call('load_binary', 4096, bytes.length));
      check(call('initialize'));
    },
    invoke(name, ...args) {
      const p = call('host_base'), bytes = encode(name), at = Math.ceil((p + bytes.length) / 8) * 8;
      parent.writeMemory(p, bytes);
      const slots = new Uint8Array(args.length * 8), view = new DataView(slots.buffer);
      const target = call('export_function', p, bytes.length);
      check(call('error_code'));
      args.forEach((value, n) => {
        const type = call('function_param_type', target, n);
        if (type === 3) view.setFloat32(n * 8, value, true);
        else if (type === 4) view.setFloat64(n * 8, value, true);
        else view.setBigInt64(n * 8, BigInt(value), true);
      });
      parent.writeMemory(at, slots);
      const value = call('invoke64', p, bytes.length, at, args.length);
      check(call('error_code'));
      const type = call('result_type');
      if (type >= 3) {
        const result = new DataView(new ArrayBuffer(8));
        result.setBigInt64(0, value, true);
        return type === 3 ? result.getFloat32(0, true) : result.getFloat64(0, true);
      }
      return type === 2 ? value : type === 1 ? Number(BigInt.asIntN(32, value)) : undefined;
    },
    setFuel: fuel => call('set_fuel', fuel),
    readMemory: (offset, length) => parent.readMemory(call('guest_memory_base') + offset, length),
    writeMemory: (offset, bytes) => parent.writeMemory(call('guest_memory_base') + offset, bytes),
    growMemory: pages => call('grow_guest_memory', pages),
    call
  };
}
for (const binary of ['wiw.wasm', 'wiw-opt.wasm']) {
  test(`${binary}: interpreter executes fixtures through its own WAT`, async () => {
    const outer = await createInterpreter(new URL(`../build/${binary}`, import.meta.url));
    const source = await readFile(new URL('../build/wiw.wat', import.meta.url), 'utf8');
    outer.load(source); outer.setFuel(100000000);
    const inner = interpreted(outer);
    for (const [file, cases] of [
      ['start', [['answer', [], 42], ['count', [], 1]]],
      ['constant', [['answer', [], 42]]], ['arithmetic', [['answer', [], 42]]],
      ['functions', [['answer', [], 42], ['subtract', [100, 58], 42]]],
      ['control', [['sum', [9], 45], ['factorial', [5], 120]]],
      ['resources', [['answer', [], 42], ['next', [7], 7], ['next', [5], 12]]],
      ['float', [['double', [1.25], 2.5], ['rounded', [], Math.fround(1.00000006)], ['zero', [1], -0], ['zero', [0], 3]]],
      ['i64', [['increment', [0x123456789abcdef0n], 0x123456789abcdef1n]]],
      ['tables', [['increment', [0x123456789abcdef0n], 0x123456789abcdef1n], ['factorial', [5], 120]]]
    ]) {
      inner.load(await readFile(new URL(`./${file}.wat`, import.meta.url), 'utf8'));
      for (const [name, args, expected] of cases) assert.equal(inner.invoke(name, ...args), expected, `${file}/${name}`);
    }
    inner.loadBinary(constantBinary);
    assert.equal(inner.invoke('answer'), 42);
    assert.throws(() => inner.loadBinary(new Uint8Array()), /interpreted status 1/);
    assert.throws(() => inner.load('(module (func (result i64) i32.const 1))'), /interpreted status 7/);
    inner.load('(module (func (export \"run\") (loop br 0)))');
    inner.setFuel(5);
    assert.throws(() => inner.invoke('run'), /interpreted status 12/);
    inner.setFuel(100000);
    inner.load('(module (func (export \"run\") (result i64) i64.const 1 i64.const 0 i64.div_s))');
    assert.throws(() => inner.invoke('run'), /interpreted status 8/);
    inner.load('(module (func (export "run") (result i32) i32.const 42))');
    assert.equal(inner.invoke('run'), 42);
    // The engine running as WAT also suspends and resumes imported i64 functions.
    inner.load('(module (import "env" "f" (func $f (param i64) (result i64))) (func (export "run") (result i64) i64.const 0x123456789abcdef0 call $f))');
    assert.equal(inner.invoke('run'), 0n);
    assert.equal(inner.call('pending_import'), 0);
    const pending = inner.call('pending_args');
    assert.equal(new DataView(outer.readMemory(pending, 8).buffer).getBigInt64(0, true), 0x123456789abcdef0n);
    assert.equal(inner.call('resume64', 0x123456789abcdef1n, 0), 0x123456789abcdef1n);
    assert.equal(inner.call('error_code'), 0);

    // A start running inside an interpreted engine must finalize only after its import resumes.
    inner.load('(module (import "env" "s" (func $s)) (global $g (mut i32) (i32.const 0)) (func $init call $s i32.const 42 global.set $g) (start $init) (func (export "run") (result i32) global.get $g))');
    assert.equal(inner.call('pending_import'), 0);
    assert.equal(inner.call('resume64', 0n, 0), 0n);
    assert.equal(inner.call('error_code'), 0);
    assert.equal(inner.invoke('run'), 42);
    assert.throws(() => inner.load('(module (func $s unreachable) (start $s))'), /interpreted status 13/);
    inner.load('(module (func (export "run") (result i32) i32.const 42))');
    assert.equal(inner.invoke('run'), 42);

    // Inception: the interpreted copy parses and runs another copy, which runs a fixture.
    inner.load(source); inner.setFuel(100000000);
    outer.setFuel(4000000000);
    const deepest = interpreted(inner);
    deepest.loadBinary(constantBinary);
    assert.equal(deepest.invoke('answer'), 42);
    deepest.load(await readFile(new URL('./i64.wat', import.meta.url), 'utf8'));
    assert.equal(deepest.invoke('increment', 0x123456789abcdef0n), 0x123456789abcdef1n);
    deepest.load(await readFile(new URL('./tables.wat', import.meta.url), 'utf8'));
    assert.equal(deepest.invoke('increment', 0x123456789abcdef0n), 0x123456789abcdef1n);
    assert.equal(deepest.invoke('factorial', 5), 120);
    deepest.load(await readFile(new URL('./start.wat', import.meta.url), 'utf8'));
    assert.equal(deepest.invoke('answer'), 42);
    assert.equal(deepest.invoke('count'), 1);
    deepest.load(await readFile(new URL('./float.wat', import.meta.url), 'utf8'));
    assert.equal(deepest.invoke('double', 1.25), 2.5);
    assert.equal(deepest.invoke('rounded'), Math.fround(1.00000006));
    assert.equal(deepest.invoke('zero', 1), -0);
    deepest.load(await readFile(new URL('./control.wat', import.meta.url), 'utf8'));
    assert.equal(deepest.invoke('factorial', 5), 120);
  });
}
