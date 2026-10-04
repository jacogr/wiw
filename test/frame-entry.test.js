import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createBootstrapInterpreter,createInterpreter} from '../wiw.js';

const binary = new URL('../build/wiw-opt.wasm',import.meta.url);
const zero = {type:'v128',bits:0n};
for (const [runtime,create] of [['bootstrap',createBootstrapInterpreter],['interpreted',createInterpreter]]) {
  test(`${runtime}: frame entry copies maximum vector parameters and clears both ends of the local arena`,async () => {
    const engine = await create(binary);
    const params = `(param ${'v128 '.repeat(128)})`;
    const locals = `(local ${'v128 '.repeat(960)})`;
    const args = Array.from({length:128},(_,index) => `(local.get ${index})`).join(' ');
    const values = Array.from({length:128},(_,index) => ({type:'v128',bits:(BigInt(index+1)<<120n)|BigInt(index+1001)}));
    for (const instruction of ['call','return_call']) {
      engine.load(`(module
        (func $check ${params} (result v128 v128 v128) ${locals}
          local.get 127 local.get 128 local.get 1087)
        (func $step ${params} (result v128 v128 v128) ${locals}
          (local.set 128 (local.get 0)) (local.set 1087 (local.get 127))
          (${instruction} $check ${args}))
        (func (export "run") ${params} (result i32 v128 v128 v128)
          i32.const 123 (call $step ${args})))`);
      for (let repeat=0;repeat<2;repeat++) {
        assert.deepEqual(engine.invokeRaw('run',...values),[{type:'i32',bits:123n},values[127],zero,zero]);
      }
    }
  });
}
