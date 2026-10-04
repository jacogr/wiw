import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createInterpreter} from '../wiw.js';

const source = await readFile(new URL('./references.wat', import.meta.url), 'utf8');
async function compile(text, run) {
  const dir = await mkdtemp(join(tmpdir(), 'wiw-ref-'));
  try {
    await writeFile(join(dir, 'guest.wat'), text);
    execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);
    await run(new Uint8Array(await readFile(join(dir, 'guest.wasm'))));
  } finally {await rm(dir, {recursive: true, force: true});}
}
for (const binary of ['wiw.wasm', 'wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: reference text/binary guests match native nulls, identity, select and globals`, async () => {
    await compile(source, async bytes => {
      const native = (await WebAssembly.instantiate(bytes)).instance.exports;
      const engine = await createInterpreter(url);
      for (const encoded of [false, true]) {
        if (encoded) engine.loadBinary(bytes); else engine.load(source);
        assert.deepEqual(engine.signature('identity'), {params: ['externref'], result: 'externref'});
        assert.equal(engine.invoke('nullFunc'), native.nullFunc());
        assert.equal(engine.invoke('nullExtern'), native.nullExtern());
        assert.equal(engine.invoke('localNull'), native.localNull());
        for (const value of [null, undefined, {}, Symbol('x'), () => 7, 'hello', 42n, false, 0, -0, NaN]) {
          assert.equal(engine.invoke('identity', value), native.identity(value));
          assert.equal(engine.invoke('branch', value), native.branch(value));
          assert.equal(engine.invoke('isNull', value), native.isNull(value));
          assert.equal(engine.invoke('choose', value, null, 1), native.choose(value, null, 1));
          assert.equal(engine.invoke('choose', value, null, 0), native.choose(value, null, 0));
          engine.setGlobal('external', value); native.external.value = value;
          assert.equal(engine.getGlobal('external'), native.external.value);
          assert.deepEqual(engine.invokeRaw('identity', {type: 'externref', value}), {type: 'externref', value});
        }
        const fn = engine.exportFunction('answer');
        assert.equal(engine.invoke('functionIdentity', fn), fn);
        assert.equal(engine.invoke('functionIdentity', null), null);
        assert.equal(engine.invoke('functionIsNull', fn), 0);
        assert.equal(engine.invoke('functionIsNull', null), 1);
        engine.setGlobal('function', fn); assert.equal(engine.getGlobal('function'), fn);
        assert.equal(engine.getGlobal('function')(), 42);
        assert.throws(() => engine.invoke('functionIdentity', () => 1), /live wiw function/);
        assert.throws(() => engine.invokeRaw('functionIdentity', {type: 'funcref', bits: 1n}), /opaque value/);
        const payload = {type: 'f64', bits: 0x7ff0000000000042n};
        assert.deepEqual(engine.invokeRaw('chooseFloat', payload, {type: 'f64', bits: 0n}, {type: 'i32', bits: 1n}), payload);
        engine.load(source);
        assert.throws(() => engine.invoke('functionIdentity', fn), /live wiw function/);
        assert.equal(engine.getGlobal('external'), null);
      }
    });
  });

  test(`${binary}: reference forwarding translates local handles while retaining exact numeric bits`, async () => {
    const provider = await createInterpreter(url), consumer = await createInterpreter(url);
    provider.load(`(module
      (global (export "e") (mut externref) (ref.null extern))
      (global (export "f") (mut funcref) (ref.null func))
      (func (export "answer") (result i32) i32.const 42)
      (func (export "identity") (param externref) (result externref) local.get 0)
      (func (export "fn") (param funcref) (result funcref) local.get 0)
      (func (export "mixed") (param externref f64) (result f64) local.get 1))`);
    consumer.load(`(module
      (global $e (import "p" "e") (mut externref))
      (global $f (import "p" "f") (mut funcref))
      (import "p" "identity" (func $identity (param externref) (result externref)))
      (import "p" "fn" (func $fn (param funcref) (result funcref)))
      (import "p" "mixed" (func $mixed (param externref f64) (result f64)))
      (func (export "answer") (result i32) i32.const 7)
      (func (export "identity") (param externref) (result externref) local.get 0 call $identity)
      (func (export "fn") (param funcref) (result funcref) local.get 0 call $fn)
      (func (export "mixed") (param externref f64) (result f64) local.get 0 local.get 1 call $mixed)
      (func (export "setE") (param externref) local.get 0 global.set $e)
      (func (export "getE") (result externref) global.get $e)
      (func (export "setF") (param funcref) local.get 0 global.set $f)
      (func (export "getF") (result funcref) global.get $f)
      (export "e" (global $e)) (export "f" (global $f)))`, {p: provider.exportNamespace()});
    // Seed different external IDs and function indices in each instance before crossing.
    provider.invoke('identity', {}); consumer.invoke('identity', {});
    const object = {};
    assert.equal(consumer.invoke('identity', object), object);
    const fn = consumer.exportFunction('answer');
    assert.equal(consumer.invoke('fn', fn), fn);
    assert.equal(consumer.invoke('fn', fn)(), 7);
    consumer.invoke('setE', object); assert.equal(provider.getGlobal('e'), object);
    provider.setGlobal('e', undefined); assert.equal(consumer.invoke('getE'), undefined);
    consumer.invoke('setF', fn); assert.equal(provider.getGlobal('f'), fn);
    const providerFn = provider.exportFunction('answer');
    provider.setGlobal('f', providerFn); assert.equal(consumer.invoke('getF'), providerFn);
    const payload = {type: 'f64', bits: 0x7ff0000000000042n};
    assert.deepEqual(consumer.invokeRaw('mixed', {type: 'externref', value: object}, payload), payload);
    provider.load('(module)');
    assert.throws(() => consumer.invoke('fn', fn), /stale resource binding/);
  });

  test(`${binary}: host callbacks, imported initializers and reference limits keep values opaque`, async () => {
    const engine = await createInterpreter(url), provider = await createInterpreter(url);
    const opaque = Object.create(null);
    Object.defineProperty(opaque, 'then', {get() {throw new Error('opaque value was inspected');}});
    engine.load(`(module
      (import "env" "echo" (func $echo (param externref) (result externref)))
      (func (export "echo") (param externref) (result externref) local.get 0 call $echo))`, {env: {echo: value => value}});
    assert.equal(engine.invoke('echo', opaque), opaque);
    const promise = Promise.resolve(42);
    assert.equal(engine.invoke('echo', promise), promise);
    provider.load('(module (global (export "e") externref (ref.null extern)) (func (export "echo") (param externref) (result externref) local.get 0))');
    // Immutable reference globals can initialize another global through the imported prefix.
    engine.load('(module (global $i (import "p" "e") externref) (global (export "copy") externref (global.get $i)))', {p: provider.exportNamespace()});
    assert.equal(engine.getGlobal('copy'), null);
    provider.load('(module (func (export "f") (param i32) (result i32) local.get 0))');
    const fn = provider.exportFunction('f');
    engine.load(source);
    engine.setGlobal('function', fn);
    assert.equal(engine.getGlobal('function'), fn);
    assert.equal(engine.getGlobal('function')(42), 42);
    // Per-load external handles are bounded and never recycled while guest values can retain them.
    for (let i = 0; i < 65535; i++) engine.invoke('identity', {});
    assert.throws(() => engine.invoke('identity', {}), /reference resource limit/);
    engine.load(source); assert.equal(engine.invoke('identity', opaque), opaque);
  });

  test(`${binary}: concrete dead-code references, heap types and typed select validate`, async () => {
    const engine = await createInterpreter(url);
    for (const body of [
      'i32.const 0 ref.is_null drop', 'unreachable i64.const 0 ref.is_null drop', 'unreachable f32.const 0 ref.is_null drop', 'unreachable f64.const 0 ref.is_null drop',
      'ref.null func ref.null func i32.const 1 select drop',
      'unreachable ref.null extern ref.null extern i32.const 1 select drop',
      'ref.null func ref.null extern i32.const 1 select (result externref) drop',
      'i32.const 1 i32.const 2 i32.const 0 select (result i64) drop',
      'unreachable ref.null func select (result i32) drop'
    ]) assert.throws(() => engine.load(`(module (func ${body}))`), /operand stack/);
    for (const body of ['ref.null i32 drop', 'ref.null funcref drop', 'select (result i32 i32)'])
      assert.throws(() => engine.load(`(module (func ${body}))`), /syntax|unsupported|operand stack/);
    assert.throws(() => engine.load('(module (global funcref (ref.null extern)))'), /operand stack/);
    engine.load('(module (func unreachable ref.is_null drop) (func unreachable select (result externref) drop))');
    await compile('(module (func (export "null") (result funcref) ref.null func))', async bytes => {
      const invalid = bytes.slice();
      const index = invalid.findIndex((byte, i) => byte === 208 && invalid[i + 1] === 112);
      assert.ok(index > 0); invalid[index + 1] = 127;
      assert.equal(WebAssembly.validate(invalid), false);
      assert.throws(() => engine.loadBinary(invalid), /syntax/);
    });
    await compile('(module (func (export "choose") (param i32 i32 i32) (result i32) local.get 0 local.get 1 local.get 2 select (result i32)))', async bytes => {
      const index = bytes.findIndex((byte, i) => byte === 28 && bytes[i + 1] === 1 && bytes[i + 2] === 127);
      assert.ok(index > 0);
      for (const count of [0, 2]) {
        const invalid = bytes.slice(); invalid[index + 1] = count;
        assert.equal(WebAssembly.validate(invalid), false);
        assert.throws(() => engine.loadBinary(invalid), /syntax/);
      }
    });
    engine.load(source); assert.equal(engine.invoke('nullFunc'), null);
  });
}
