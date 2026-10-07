import {runtimeFactories} from './runtime.js';
import assert from 'node:assert/strict';
import {test} from 'node:test';

const binary = new URL('../build/wiw-opt.wasm',import.meta.url);
for (const [runtime,create] of runtimeFactories) {
  test(`${runtime}: mixed dispatch families retain raw results through direct, indirect and reference calls`,async () => {
    const engine = await create(binary);
    engine.load(`(module
      (type $t (func (param i32) (result i32)))
      (memory 1)
      (table funcref (elem $leaf))
      (elem declare func $indirect)
      (global $three i32 (i32.const 3))
      (func $leaf (type $t)
        local.get 0 global.get $three i32.mul return)
      (func $indirect (type $t)
        (return_call_indirect (type $t) (local.get 0) (i32.const 0)))
      (func $reference (type $t)
        (return_call_ref $t (local.get 0) (ref.func $indirect)))
      (func (export "run") (param i32) (result i32 i64 f32 f64 v128)
        (block $skip
          (br_if $skip (i32.eqz (local.get 0))) nop)
        (i32.store (i32.const 0) (call $reference (local.get 0)))
        (select (i32.load (i32.const 0)) (i32.const 0) (local.get 0))
        (i64.div_s (i64.const -9) (i64.const 2))
        (f32.copysign (f32.const 0) (f32.const -1))
        (f64.mul (f64.const 1.5) (f64.const 2))
        (v128.store (i32.const 16) (v128.const i64x2 1 -1))
        (v128.xor (v128.load (i32.const 16)) (v128.const i64x2 3 0))))`);
    for (const input of [0,7,255,256,0]) {
      assert.deepEqual(engine.invokeRaw('run',{type:'i32',bits:BigInt(input)}),[
        {type:'i32',bits:BigInt(input*3)},
        {type:'i64',bits:BigInt.asUintN(64,-4n)},
        {type:'f32',bits:0x80000000n},
        {type:'f64',bits:0x4008000000000000n},
        {type:'v128',bits:0xffffffffffffffff0000000000000002n}
      ]);
    }
  });

  test(`${runtime}: routed exception rethrows preserve payloads and recover after traps and reloads`,async () => {
    const engine = await create(binary);
    const source = `(module
      (tag $t (param i64))
      (func $raise (param i64)
        (block $caught (result i64 exnref)
          (try_table (catch_ref $t $caught)
            (throw $t (local.get 0)))
          unreachable)
        throw_ref drop)
      (func (export "run") (param i64) (result i64)
        (block $caught (result i64)
          (try_table (catch $t $caught)
            (call $raise (local.get 0)))
          unreachable))
      (func (export "trap")
        ref.null exn throw_ref))`;
    for (let reload=0;reload<2;reload++) {
      engine.load(source);
      for (const value of [0n,-1n,-(1n<<63n)]) {
        assert.equal(engine.invoke('run',value),value);
        assert.throws(() => engine.invoke('trap'),/null reference at byte/);
        assert.equal(engine.invoke('run',value),value);
      }
    }
  });
}
