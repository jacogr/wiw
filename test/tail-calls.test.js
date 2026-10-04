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
