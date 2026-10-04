import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createBootstrapInterpreter, createInterpreter} from '../wiw.js';

const binary = new URL('../build/wiw-opt.wasm', import.meta.url);
for (const [runtime, create] of [['bootstrap', createBootstrapInterpreter], ['interpreted', createInterpreter]]) {
  test(`${runtime}: completed indirect types retain live table selection and survive reloads`, async () => {
    const engine = await create(binary);
    const source = `(module
      (type $expected (func (param i32) (result i32)))
      (type $equivalent (func (param i32) (result i32)))
      (rec (type $nominal (func (param i32) (result i32))) (type $extra (struct (field i32))))
      (table 1 funcref)
      (func $first (param i32) (result i32) (i32.add (local.get 0) (i32.const 11)))
      (func $second (type $equivalent) (i32.add (local.get 0) (i32.const 22)))
      (func $wrong (param i64) (result i64) (local.get 0))
      (func $nominal (type $nominal) (local.get 0))
      (elem (i32.const 0) $first)
      (elem declare func $second $wrong $nominal)
      (func (export "run") (param i32 i32) (result i32)
        (call_indirect (type $expected) (local.get 0) (local.get 1)))
      (func (export "tail") (param i32 i32) (result i32)
        (return_call_indirect (type $expected) (local.get 0) (local.get 1)))
      (func (export "inline") (param i32 i32) (result i32)
        (call_indirect (param i32) (result i32) (local.get 0) (local.get 1)))
      (func (export "first") (table.set (i32.const 0) (ref.func $first)))
      (func (export "second") (table.set (i32.const 0) (ref.func $second)))
      (func (export "wrong") (table.set (i32.const 0) (ref.func $wrong)))
      (func (export "nominal") (table.set (i32.const 0) (ref.func $nominal)))
      (func (export "null") (table.set (i32.const 0) (ref.null func))))`;
    engine.load(source);
    for (let repeat = 0; repeat < 2; repeat++) {
      for (const [target, expected] of [['first',18], ['second',29]]) {
        engine.invoke(target);
        for (const call of ['run','tail','inline']) assert.equal(engine.invoke(call,7,0),expected);
      }
      for (const target of ['wrong','nominal','null']) {
        engine.invoke(target);
        for (const call of ['run','tail','inline']) assert.throws(() => engine.invoke(call,7,0), target==='null' ? /undefined element/ : /indirect call type mismatch/);
      }
      engine.invoke('first');
      assert.equal(engine.invoke('run',7,0),18);
      for (const index of [1,-1]) assert.throws(() => engine.invoke('run',7,index), /undefined element/);
    }
    // Reused declaration and type indices acquire the new module's widths.
    engine.load(`(module (type $t (func (param i64) (result i64)))
      (table funcref (elem $f))
      (func $f (type $t) (i64.add (local.get 0) (i64.const 7)))
      (func (export "run") (param i64) (result i64)
        (call_indirect (type $t) (local.get 0) (i32.const 0))))`);
    assert.equal(engine.invoke('run',0x123456789abcdef0n),0x123456789abcdef7n);
    assert.throws(() => engine.load('(module (table 1 funcref) (func i32.const 0 call_indirect (type $missing)))'), /reference/);
    engine.load(source); assert.equal(engine.invoke('tail',7,0),18);
  });

  test(`${runtime}: indirect calls preserve declared function subtyping`, async () => {
    const engine = await create(binary);
    engine.load(`(module
      (type $base (sub (func (param i32) (result i32))))
      (type $child (sub $base (func (param i32) (result i32))))
      (func $child (type $child) (i32.add (local.get 0) (i32.const 33)))
      (func $unrelated (param i32) (result i32) (local.get 0))
      (table funcref (elem $child $unrelated))
      (func (export "run") (param i32 i32) (result i32)
        (call_indirect (type $base) (local.get 0) (local.get 1))))`);
    for (let repeat = 0; repeat < 2; repeat++) {
      assert.equal(engine.invoke('run',7,0),40);
      assert.throws(() => engine.invoke('run',7,1), /indirect call type mismatch/);
    }
  });

  test(`${runtime}: shared-table foreign types remain current after table updates and consumer reload`, async () => {
    const provider = await create(binary), consumer = await create(binary);
    provider.load(`(module (table (export "t") 1 funcref)
      (func $scalar (param i32) (result i32) (i32.add (local.get 0) (i32.const 1)))
      (func $pair (param i32) (result i32 i64) (i32.add (local.get 0) (i32.const 2)) (i64.const 99))
      (elem (i32.const 0) $scalar) (elem declare func $pair)
      (func (export "scalar") (table.set (i32.const 0) (ref.func $scalar)))
      (func (export "pair") (table.set (i32.const 0) (ref.func $pair))))`);
    const scalar = '(type $scalar (func (param i32) (result i32)))';
    const pair = '(type $pair (func (param i32) (result i32 i64)))';
    for (const types of [scalar+pair,pair+scalar]) {
      consumer.load(`(module ${types} (table (import "p" "t") 1 funcref)
        (func (export "run") (param i32) (result i32) (call_indirect (type $scalar) (local.get 0) (i32.const 0)))
        (func (export "pair") (param i32) (result i32 i64) (call_indirect (type $pair) (local.get 0) (i32.const 0))))`,
      {p:provider.exportNamespace()});
      provider.invoke('scalar'); assert.equal(consumer.invoke('run',41),42);
      provider.invoke('pair'); assert.deepEqual(consumer.invoke('pair',41),[43,99n]);
      assert.throws(() => consumer.invoke('run',41), /indirect call type mismatch/);
      provider.invoke('scalar'); assert.equal(consumer.invoke('run',41),42);
    }
  });
}
