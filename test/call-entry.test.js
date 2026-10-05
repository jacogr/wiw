import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createBootstrapInterpreter,createInterpreter} from '../wiw.js';

const binary=new URL('../build/wiw-opt.wasm',import.meta.url);
const vector=0xfedcba98765432100123456789abcdefn;
for(const [runtime,create] of [['bootstrap',createBootstrapInterpreter],['interpreted',createInterpreter]]) {
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
}
