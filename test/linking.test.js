import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createInterpreter} from './runtime.js';

for (const binary of ['wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: resource aliases share growth, global mutations, and unexported table functions`, async () => {
    const provider = await createInterpreter(url), consumer = await createInterpreter(url);
    provider.load(`(module
      (memory (export "memory") (export "alias") 1 3)
      (global $g (export "g") (mut i32) (i32.const 42))
      (table (export "table") 2 3 funcref)
      (func $private (result i32) global.get $g)
      (elem (i32.const 0) $private)
      (func (export "call") (result i32) i32.const 0 call_indirect (result i32)))`);
    const namespace = provider.exportNamespace();
    assert.equal(namespace.memory, namespace.alias);
    consumer.load(`(module
      (memory (import "p" "alias") 0 4)
      (global $g (import "p" "g") (mut i32))
      (table (import "p" "table") 1 4 funcref)
      (func $private (result i32) global.get $g i32.const 1 i32.add)
      (elem (i32.const 0) $private)
      (func (export "change") (param i32) local.get 0 global.set $g)
      (func (export "call") (result i32) i32.const 0 call_indirect (result i32))
      (func (export "grow") (result i32) i32.const 1 memory.grow))`, {p: namespace});
    consumer.invoke('change', 8);
    assert.equal(provider.getGlobal('g'), 8);
    assert.equal(provider.invoke('call'), 9); assert.equal(consumer.invoke('call'), 9);
    consumer.writeMemory(1, Uint8Array.of(42)); assert.equal(provider.readMemory(1, 1)[0], 42);
    assert.equal(consumer.invoke('grow'), 1); assert.equal(provider.readMemory(65536, 1)[0], 0);
    provider.setGlobal('g', 13); assert.equal(consumer.invoke('call'), 14);
    const stale = provider.exportFunction('call');
    provider.load('(module (func (export "call") (result i32) i32.const 99))');
    assert.throws(() => stale(), /stale/);
    assert.throws(() => consumer.invoke('call'), /stale/);
  });

  test(`${binary}: completed segments and failed starts preserve linked resource writes`, async () => {
    const provider = await createInterpreter(url), consumer = await createInterpreter(url);
    provider.load(`(module (memory (export "m") 1) (table (export "t") 1 funcref)
      (func (export "call") (result i32) i32.const 0 call_indirect (result i32)))`);
    const imports = {p: provider.exportNamespace()};
    assert.throws(() => consumer.load(`(module (memory (import "p" "m") 1)
      (data (i32.const 0) "bad") (data (i32.const 65536) "x"))`, imports), /memory out of bounds/);
    assert.deepEqual([...provider.readMemory(0, 3)], [98, 97, 100]);
    assert.throws(() => consumer.load(`(module (memory (import "p" "m") 1) (table (import "p" "t") 1 funcref)
      (data (i32.const 0) "bad") (func $f (result i32) i32.const 7)
      (elem (i32.const 0) $f) (elem (i32.const 1) $f))`, imports), /element out of bounds/);
    assert.deepEqual([...provider.readMemory(0, 3)], [98, 97, 100]);
    assert.equal(provider.invoke('call'), 7);
    assert.throws(() => consumer.load(`(module (memory (import "p" "m") 1) (table (import "p" "t") 1 funcref)
      (func $f (result i32) i32.const 42) (elem (i32.const 0) $f)
      (func $start i32.const 0 i32.const 42 i32.store8 unreachable) (start $start))`, imports), /unreachable/);
    assert.equal(provider.readMemory(0, 1)[0], 42);
    assert.equal(provider.invoke('call'), 42);
    assert.throws(() => consumer.invoke('anything'), /no loaded module/);
  });

  test(`${binary}: raw forwarding retains signaling float bits and rejects stale bindings after same-name reloads`, async () => {
    const provider = await createInterpreter(url), consumer = await createInterpreter(url);
    const source = '(module (func (export "f") (param f32) (result f32) local.get 0))';
    provider.load(source);
    consumer.load('(module (func (export "f") (import "p" "f") (param f32) (result f32)))', {p: provider.exportNamespace()});
    const signaling = {type: 'f32', bits: 0xff800001n};
    assert.deepEqual(consumer.invokeRaw('f', signaling), signaling);
    provider.load(source);
    assert.throws(() => consumer.invokeRaw('f', signaling), /host import/);
  });
}

for (const binary of ['wiw-opt.wasm']) {
  test(`${binary}: function and resource imports fit together at their independent limits`, async () => {
    const provider = await createInterpreter(new URL(`../build/${binary}`, import.meta.url));
    const consumer = await createInterpreter(new URL(`../build/${binary}`, import.meta.url));
    provider.load('(module (global (export "g") i32 (i32.const 42)) (memory (export "m") 1) (table (export "t") 1 funcref))');
    const functions = Array.from({length: 512}, () => '(import "p" "f" (func (param i32) (result i32)))').join('\n');
    const globals = Array.from({length: 128}, () => '(import "p" "g" (global i32))').join('\n');
    const exports = Array.from({length: 128}, (_, i) => `(export "g${i}" (global ${i}))`).join('\n');
    consumer.load(`(module ${functions} ${globals}
      (import "p" "m" (memory 1)) (import "p" "t" (table 1 funcref))
      (export "f" (func 511)) ${exports})`, {p: {...provider.exportNamespace(), f: n => n + 1}});
    assert.equal(consumer.invoke('f', 41), 42);
    for (let i = 0; i < 128; i++) assert.equal(consumer.getGlobal(`g${i}`), 42);
  });
}
