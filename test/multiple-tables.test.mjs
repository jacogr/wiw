import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createInterpreter} from '../wiw.mjs';
for (const binary of ['wiw.wasm', 'wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: multiple table types keep opaque values and growth independent`, async () => {
    const engine = await createInterpreter(url);
    engine.load(`(module (table $functions (export "f") 2 4 funcref) (table $objects (export "e") 3 5 externref)
      (func (export "put") (param i32 externref) local.get 0 local.get 1 table.set $objects)
      (func (export "get") (param i32) (result externref) local.get 0 table.get $objects)
      (func (export "grow") (param externref i32) (result i32) local.get 0 local.get 1 table.grow $objects)
      (func (export "size") (result i32) table.size $functions)
      (func (export "copy") (param i32 i32 i32) local.get 0 local.get 1 local.get 2 table.copy $objects $objects))`);
    const object = Object.freeze({answer: 42});
    for (const value of [object, undefined, false, 0, -0, '', Promise.resolve(42), null]) {
      engine.invoke('put', 1, value);
      assert.ok(Object.is(engine.invoke('get', 1), value));
      engine.invoke('copy', 2, 1, 1);
      assert.ok(Object.is(engine.invoke('get', 2), value));
    }
    assert.equal(engine.invoke('grow', object, 2), 3);
    assert.equal(engine.invoke('get', 4), object);
    assert.equal(engine.invoke('size'), 2);
    assert.equal(engine.invoke('grow', object, 1), -1);
    const consumer = await createInterpreter(url);
    consumer.load(`(module (table $f (import "p" "f") 2 4 funcref) (table $e (import "p" "e") 3 5 externref)
      (func (export "get") (param i32) (result externref) local.get 0 table.get $e))`, {p: engine.exportNamespace()});
    assert.equal(consumer.invoke('get', 4), object);
    const mismatch = await createInterpreter(url);
    assert.throws(() => mismatch.load('(module (table (import "p" "e") 1 funcref))', {p: engine.exportNamespace()}), /signature mismatch/);
  });
  test(`${binary}: repeated imports alias writes and growth during the same invocation`, async () => {
    const provider = await createInterpreter(url), engine = await createInterpreter(url);
    provider.load('(module (table (export "e") 1 4 externref))');
    engine.load(`(module (table $a (import "p" "e") 1 4 externref) (table $b (import "p" "e") 1 4 externref)
      (func (export "put") (param externref) (result externref) i32.const 0 local.get 0 table.set $a i32.const 0 table.get $b)
      (func (export "grow") (param externref) (result i32) local.get 0 i32.const 2 table.grow $a drop table.size $b)
      (func (export "get") (result externref) i32.const 2 table.get $b))`, {p: provider.exportNamespace()});
    const object = {};
    assert.equal(engine.invoke('put', object), object);
    assert.equal(engine.invoke('grow', object), 3);
    assert.equal(engine.invoke('get'), object);
  });
  test(`${binary}: table namespaces, type compatibility and descriptor capacity validate`, async () => {
    const engine = await createInterpreter(url);
    for (const source of [
      '(module (table $t 1 funcref) (table $t 1 externref))',
      '(module (table $f 1 funcref) (table $e 1 externref) (func unreachable table.copy $f $e))',
      '(module (table 1 externref) (func unreachable call_indirect))',
      '(module (table 1 externref) (func unreachable ref.null func i32.const 0 table.grow drop))',
      '(module (table 1 externref) (func unreachable i32.const 0 ref.null func i32.const 0 table.fill))'
    ]) assert.throws(() => engine.load(source), /reference|operand stack/);
    engine.load(`(module ${'(table 0 externref)'.repeat(32)})`);
    assert.throws(() => engine.load(`(module ${'(table 0 externref)'.repeat(33)})`), /resource limit/);
  });
}
