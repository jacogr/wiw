import {runtimeFactories} from './runtime.js';
import assert from 'node:assert/strict';
import {test} from 'node:test';

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: host snapshots preserve reference decoding, void results and maximum type vectors`, async () => {
    const engine = await create();
    engine.load(`(module
      (func $f (result i32) i32.const 42) (elem declare func $f)
      (func (export "mixed") (param externref v128 f64) (result funcref externref v128 f64)
        ref.func $f local.get 0 local.get 1 local.get 2)
      (func (export "void")))`);
    const value = {}, vector = (1n << 127n) | 123n, nan = 0x7ff0000000000123n;
    // Decoding the first function reference issues another signature query; later slots must survive.
    const result = engine.invokeRaw('mixed', {type:'externref',value}, {type:'v128',bits:vector}, {type:'f64',bits:nan});
    assert.equal(result[0].type,'funcref');
    assert.equal(result[0].value(),42);
    assert.deepEqual(result.slice(1),[{type:'externref',value},{type:'v128',bits:vector},{type:'f64',bits:nan}]);
    assert.equal(engine.invoke('void'),undefined);
    assert.deepEqual(engine.invokeRaw('void'),{type:null,bits:0n});
    const params = Array(128).fill('i32').join(' ');
    const values = Array.from({length:128},(_,i)=>`i32.const ${i}`).join(' ');
    engine.load(`(module
      (func (export "params") (param ${params}) (result i32) local.get 0 local.get 127 i32.add)
      (func (export "results") (result ${params}) ${values}))`);
    const expected = Array.from({length:128},(_,i)=>i);
    const signature = engine.signature('params');
    assert.equal(signature.params.length,128);
    signature.params.fill('v128');
    assert.equal(engine.invoke('params',...expected),127);
    assert.deepEqual(engine.invoke('results'),expected);
    assert.deepEqual(engine.invokeRaw('results'),expected.map(value=>({type:'i32',bits:BigInt(value)})));
  });
}
