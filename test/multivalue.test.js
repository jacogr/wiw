import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterpreter } from './runtime.js';
const source = `(module
  (type $pair (func (param i32) (result i32 i64)))
  (type $same (func (param i32) (result i32 i64)))
  (table funcref (elem $pair))
  (func $pair (export "pair") (type $pair) local.get 0 i64.const 0x123456789abcdef0)
  (func (export "direct") (param i32) (result i32 i64) local.get 0 call $pair)
  (func (export "indirect") (param i32) (result i32 i64) local.get 0 i32.const 0 call_indirect (type $same))
  (func (export "branch") (param i32) (result i32 i64)
    block (result i32 i64) i32.const 42 i64.const 7 local.get 0 br_if 0 drop drop i32.const 3 i64.const 4 end)
  (func (export "return") (result i32 f32 f64) i32.const 42 f32.const -0 f64.const nan:0x1 return))`;

for (const binary of ['wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);

  test(`${binary}: multivalue calls and branches preserve ordered raw results`, async () => {
    const dir = await mkdtemp(join(tmpdir(), 'wiw-multi-'));

    try {
      await writeFile(join(dir, 'guest.wat'), source);
      execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);

      const bytes = await readFile(join(dir, 'guest.wasm'));
      const native = (await WebAssembly.instantiate(bytes)).instance.exports;

      for (const encoded of [false, true]) {
        const engine = await createInterpreter(url);

        // Exercise the binary decoder with the same guest semantics as the WAT fixture.
        if (encoded) engine.loadBinary(bytes);
        else engine.load(source);

        for (const name of ['pair', 'direct', 'indirect', 'branch'])
          for (const arg of [0, 1, -1, 42]) assert.deepEqual(engine.invoke(name, arg), native[name](arg));

        assert.deepEqual(engine.invokeRaw('return'), [
          { type: 'i32', bits: 42n },
          { type: 'f32', bits: 0x80000000n },
          { type: 'f64', bits: 0x7ff0000000000001n }
        ]);
      }
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
  test(`${binary}: multivalue host imports and forwarding translate references and retain NaN payloads`, async () => {
    const provider = await createInterpreter(url),
      consumer = await createInterpreter(url);

    provider.load(
      '(module (func (export "f") (param externref) (result externref f64 i64) local.get 0 f64.const nan:0x1 i64.const 7))'
    );
    consumer.load(
      '(module (func $f (import "p" "f") (param externref) (result externref f64 i64)) (func (export "f") (param externref) (result externref f64 i64) local.get 0 call $f))',
      { p: provider.exportNamespace() }
    );

    const object = {};

    assert.deepEqual(consumer.invokeRaw('f', { type: 'externref', value: object }), [
      { type: 'externref', value: object },
      { type: 'f64', bits: 0x7ff0000000000001n },
      { type: 'i64', bits: 7n }
    ]);
    consumer.load('(module (func $f (export "f") (import "p" "f") (result i32 i64)))', { p: { f: () => [42, 7n] } });
    assert.deepEqual(consumer.invoke('f'), [42, 7n]);

    for (const f of [() => [42], () => [42, 7], () => 42, () => [42, 7n, 0]]) {
      consumer.load('(module (func (export "f") (import "p" "f") (result i32 i64)))', { p: { f } });
      assert.throws(() => consumer.invoke('f'), /host import/);
    }
  });
  test(`${binary}: multivalue signatures validate exact counts and ordered types`, async () => {
    const engine = await createInterpreter(url);

    for (const body of [
      'i32.const 1',
      'i64.const 1 i32.const 2',
      'i32.const 1 i64.const 2 i32.const 3',
      'block (result i64 i32) i64.const 1 i32.const 2 end'
    ])
      assert.throws(() => engine.load(`(module (func (result i32 i64) ${body}))`), /operand stack/);

    engine.load('(module (func (export "f") (param ' + 'i32 '.repeat(128) + ') (result i32) local.get 127))');
    assert.equal(engine.invoke('f', ...Array.from({ length: 128 }, (_, i) => i)), 127);
  });
}

for (const binary of ['wiw-opt.wasm']) {
  test(`${binary}: control parameters, loop inputs and implicit else match native`, async () => {
    const dir = await mkdtemp(join(tmpdir(), 'wiw-control-inputs-'));
    const source = `(module
      (type $pair (func (param i32 i64) (result i32 i64)))
      (func (export "pair") (result i32 i64) i32.const 42 i64.const 7 block (type $pair) end)
      (func (export "identity") (param i32) (result i32) i32.const 42 local.get 0 if (param i32) (result i32) end)
      (func (export "loop") (param i32) (result i32) local.get 0 loop (param i32) (result i32)
        i32.const 1 i32.sub local.tee 0 local.get 0 br_if 0 end))`;

    try {
      await writeFile(join(dir, 'guest.wat'), source);
      execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);

      const bytes = await readFile(join(dir, 'guest.wasm'));
      const native = (await WebAssembly.instantiate(bytes)).instance.exports;
      const engine = await createInterpreter(new URL(`../build/${binary}`, import.meta.url));

      for (const encoded of [false, true]) {
        // Exercise the binary decoder with the same guest semantics as the WAT fixture.
        if (encoded) engine.loadBinary(bytes);
        else engine.load(source);

        assert.deepEqual(engine.invoke('pair'), native.pair());

        for (const condition of [0, 1, -1])
          assert.equal(engine.invoke('identity', condition), native.identity(condition));

        for (const n of [1, 2, 7]) assert.equal(engine.invoke('loop', n), native.loop(n));
      }
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
}
