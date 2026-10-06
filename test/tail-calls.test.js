import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createBootstrapInterpreter, createInterpreter} from '../wiw.js';

const binary = new URL('../build/wiw-opt.wasm', import.meta.url);
const vector = {type: 'v128', bits: 0xfedcba98765432100123456789abcdefn};
const zero = {type: 'v128', bits: 0n};
for (const [runtime, create] of [['bootstrap', createBootstrapInterpreter], ['interpreted', createInterpreter]]) {
  test(`${runtime}: tail frame replacement preserves callers, vector arguments and cleared locals`, async () => {
    const engine = await create(binary);
    for (const instruction of ['return_call $finish', 'return_call_indirect (type $t)', 'return_call_ref $t']) {
      const selector = instruction.includes('indirect') ? '(i32.const 0)' : instruction.includes('_ref') ? '(ref.func $finish)' : '';
      engine.load(`(module
        (type $t (func (param v128 i32) (result v128 i32 v128)))
        (table funcref (elem $finish))
        (func $finish (type $t) (local v128)
          (local.get 0) (local.get 1) (local.get 2))
        (func $hop (param i32 v128) (result v128 i32 v128) (local v128 i32)
          (local.set 2 (v128.const i64x2 -1 -1)) (local.set 3 (i32.const 99))
          (i32.const 777)
          (${instruction} (local.get 1) (local.get 0) ${selector}))
        (func (export "run") (param v128) (result i32 v128 i32 v128)
          (i32.const 123) (call $hop (i32.const 42) (local.get 0))))`);
      for (let repeat = 0; repeat < 2; repeat++) {
        assert.deepEqual(engine.invokeRaw('run', vector), [{type:'i32',bits:123n}, vector, {type:'i32',bits:42n}, zero]);
      }
    }
    // A self tail call must also reset locals when its descriptor is unchanged.
    engine.load(`(module (func $run (export "run") (param i32) (result i32) (local i32)
      (if (local.get 1) (then unreachable))
      (if (result i32) (i32.eqz (local.get 0)) (then (local.get 1))
        (else (local.set 1 (i32.const 99)) (return_call $run (i32.sub (local.get 0) (i32.const 1)))))))`);
    assert.equal(engine.invoke('run', 1000), 0);
    engine.setFuel(50);
    assert.throws(() => engine.invoke('run', 1000), /exhausted fuel/);
    engine.setFuel(100000);
    assert.equal(engine.invoke('run', 1000), 0);
    // A parameterless callee clears slots that previously held caller parameters.
    engine.load(`(module
      (func $zero (result v128) (local v128) (local.get 0))
      (func (export "run") (param v128) (result v128) (return_call $zero)))`);
    assert.deepEqual(engine.invokeRaw('run', vector), zero);
  });

  test(`${runtime}: self tail calls retain the root, caller operands and both vector halves`, async () => {
    const engine = await create(binary);
    for (const instruction of ['return_call $step', 'return_call_indirect (type $t)', 'return_call_ref $t']) {
      const selector = instruction.includes('indirect') ? '(i32.const 0)' : instruction.includes('_ref') ? '(ref.func $step)' : '';
      engine.load(`(module
        (type $t (func (param v128) (result v128 i32)))
        (table funcref (elem $step))
        (global $remaining (mut i32) (i32.const 0))
        (func $step (type $t)
          (if (i32.eqz (global.get $remaining))
            (then (return (local.get 0) (i32.const 42))))
          (global.set $remaining (i32.sub (global.get $remaining) (i32.const 1)))
          (block (loop
            (i32.const 777)
            (${instruction} (local.get 0) ${selector}))) unreachable)
        (func (export "run") (param v128) (result i32 v128 i32)
          (global.set $remaining (i32.const 1000))
          (i32.const 123) (call $step (local.get 0))))`);
      const expected = [{type:'i32',bits:123n}, vector, {type:'i32',bits:42n}];
      for (let repeat = 0; repeat < 2; repeat++) assert.deepEqual(engine.invokeRaw('run', vector), expected);
      engine.setFuel(50);
      assert.throws(() => engine.invokeRaw('run', vector), /exhausted fuel/);
      engine.setFuel(100000);
      assert.deepEqual(engine.invokeRaw('run', vector), expected);
    }
  });

  test(`${runtime}: mutual tails refresh callee ends and result shapes while retaining caller values`, async () => {
    const engine = await create(binary);
    for (const mode of ['direct', 'indirect', 'reference']) {
      const tail = (target, index) => mode === 'direct'
        ? `(return_call ${target} (local.get 0))`
        : mode === 'indirect'
          ? `(return_call_indirect (type $t) (local.get 0) (i32.const ${index}))`
          : `(return_call_ref $t (local.get 0) (ref.func ${target}))`;
      engine.load(`(module
        (type $t (func (param v128) (result v128 i32)))
        (table funcref (elem $first $second))
        (global $remaining (mut i32) (i32.const 0))
        (func $noop)
        (func $first (type $t)
          (if (result v128 i32) (i32.eqz (global.get $remaining))
            (then (local.get 0) (i32.const 42))
            (else
              (call $noop)
              (global.set $remaining (i32.sub (global.get $remaining) (i32.const 1)))
              (block (loop (i32.const 777) ${tail('$second', 1)}))
              unreachable)))
        (func $second (param v128) (result v128 i32)
          (if (i32.eqz (global.get $remaining))
            (then (return (local.get 0) (i32.const 43))))
          (global.set $remaining (i32.sub (global.get $remaining) (i32.const 1)))
          (block (loop (i64.const 999) ${tail('$first', 0)}))
          unreachable)
        (func (export "even") (param v128) (result i32 v128 i32)
          (global.set $remaining (i32.const 1000))
          (i32.const 123) (call $first (local.get 0)))
        (func (export "odd") (param v128) (result i32 v128 i32)
          (global.set $remaining (i32.const 1001))
          (i32.const 123) (call $first (local.get 0))))`);
      for (let repeat = 0; repeat < 2; repeat++) {
        assert.deepEqual(engine.invokeRaw('even', vector), [{type:'i32',bits:123n}, vector, {type:'i32',bits:42n}]);
        assert.deepEqual(engine.invokeRaw('odd', vector), [{type:'i32',bits:123n}, vector, {type:'i32',bits:43n}]);
      }
      engine.setFuel(50);
      assert.throws(() => engine.invokeRaw('odd', vector), /exhausted fuel/);
      engine.setFuel(100000);
      assert.deepEqual(engine.invokeRaw('odd', vector), [{type:'i32',bits:123n}, vector, {type:'i32',bits:43n}]);
    }
  });

  test(`${runtime}: reference dispatch keeps null traps and exact fuel boundaries`, async () => {
    const engine = await create(binary);
    const source = `(module
      (type $t (func (result i32)))
      (func $zero (type $t) (i32.const 11))
      (func $one (type $t) (i32.const 22))
      (elem declare func $zero $one)
      (global $target (mut (ref null $t)) (ref.func $zero))
      (func (export "run") (result i32) (return_call_ref $t (global.get $target)))
      (func (export "zero") (global.set $target (ref.func $zero)))
      (func (export "one") (global.set $target (ref.func $one)))
      (func (export "null") (global.set $target (ref.null $t))))`;
    engine.load(source);
    assert.equal(engine.invoke('run'), 11); // Function index zero is a non-null reference.
    engine.invoke('one'); assert.equal(engine.invoke('run'), 22);
    engine.invoke('null'); assert.throws(() => engine.invoke('run'), /null reference/);
    engine.invoke('zero');
    // The global read consumes one unit before reaching the reference call.
    engine.setFuel(1);
    assert.throws(() => engine.invoke('run'), new RegExp(`exhausted fuel at byte ${source.indexOf('return_call_ref')}$`));
    // Creating the reference also consumes one unit; its global write must not execute.
    assert.throws(() => engine.invoke('one'), new RegExp(`exhausted fuel at byte ${source.indexOf('global.set', source.indexOf('(export "one")'))}$`));
    engine.setFuel(100000);
    assert.equal(engine.invoke('run'), 11);
  });

  test(`${runtime}: imported tail calls suspend with arguments and retain caller operands`, async () => {
    const engine = await create(binary);
    const reference = {name: 'tail argument'};
    engine.load(`(module
      (func $host (import "env" "host") (param externref v128) (result externref v128))
      (func $hop (param externref v128) (result externref v128)
        (i32.const 777) (return_call $host (local.get 0) (local.get 1)))
      (func (export "run") (param externref v128) (result i32 externref v128)
        (i32.const 123) (call $hop (local.get 0) (local.get 1))))`,
    {env: {host: (ref, bits) => { assert.equal(ref, reference); assert.equal(bits, vector.bits); return [ref, bits]; }}});
    assert.deepEqual(engine.invokeRaw('run', {type:'externref',value:reference}, vector),
      [{type:'i32',bits:123n}, {type:'externref',value:reference}, vector]);
  });
}
