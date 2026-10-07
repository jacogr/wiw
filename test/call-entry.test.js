import {runtimeFactories} from './runtime.js';
import assert from 'node:assert/strict';
import {test} from 'node:test';

const binary=new URL('../build/wiw-opt.wasm',import.meta.url);
const vector=0xfedcba98765432100123456789abcdefn;
for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: tail entry at the last call frame preserves implicit roots and vector results`,async()=>{
    const engine=await create(binary);
    engine.load(`(module
      (func $finish (param v128) (result v128 i32)
        local.get 0 i32.const 42 br 0)
      (func $recurse (export "run") (param i32 v128) (result v128 i32)
        local.get 0
        (if (result v128 i32)
          (then local.get 0 i32.const 1 i32.sub local.get 1 call $recurse)
          (else local.get 1 return_call $finish)))
      (func $empty)
      (func (export "empty") return_call $empty))`);
    assert.deepEqual(engine.invoke('run',511,vector),[vector,42]);
    assert.throws(()=>engine.invoke('run',512,vector),/resource limit/);
    assert.deepEqual(engine.invoke('run',511,vector),[vector,42]);
    assert.equal(engine.invoke('empty'),undefined);
  });
  test(`${runtime}: full local frames clear both vector halves on repeated tail entry`,async()=>{
    const engine=await create(binary);
    engine.load(`(module
      (func $repeat (export "run") (param i32 v128) (result v128 i32)
        (local ${'v128 '.repeat(1086)})
        local.get 2 v128.any_true
        local.get 1087 v128.any_true i32.or
        if unreachable end
        v128.const i32x4 -1 -1 -1 -1 local.set 2
        v128.const i32x4 -1 -1 -1 -1 local.set 1087
        local.get 0
        if
          local.get 0 i32.const 1 i32.sub local.get 1 return_call $repeat
        end
        local.get 1 i32.const 42 br 0))`);
    assert.deepEqual(engine.invoke('run',3,vector),[vector,42]);
    assert.deepEqual(engine.invoke('run',2,vector),[vector,42]);
  });

  test(`${runtime}: single-parameter call entry respects the control capacity`,async()=>{
    const engine=await create(binary);
    engine.load(`(module
      (func $finish (param i32) (result i32) local.get 0)
      (func $recurse (export "run") (param i32) (result i32)
        ${'block '.repeat(7)}
        local.get 0
        if
          local.get 0 i32.const 1 i32.sub call $recurse return
        else
          block i32.const 42 call $finish return end
        end
        ${'end '.repeat(7)}
        unreachable))`);
    // Each recursive frame keeps its root, seven blocks and one if active.
    assert.equal(engine.invoke('run',453),42);
    assert.throws(()=>engine.invoke('run',454),/resource limit/);
    assert.throws(()=>engine.invoke('run',454),/resource limit/);
    assert.equal(engine.invoke('run',453),42);
  });
}
