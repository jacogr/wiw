import {runtimeFactories} from './runtime.js';
import assert from 'node:assert/strict';
import {test} from 'node:test';

const binary = new URL('../build/wiw-opt.wasm',import.meta.url);
const vector = {type:'v128',bits:0xfedcba98765432100123456789abcdefn};
for (const [runtime,create] of runtimeFactories) {
  test(`${runtime}: active local high bases survive nested calls, tail replacement and import resumption`,async () => {
    const engine = await create(binary);
    const reference = {identity:'local-base'};
    engine.load(`(module
      (import "env" "invert" (func $invert (param v128) (result v128)))
      (func $forward (param v128) (result v128) (local v128)
        (local.set 1 (local.get 0))
        (local.set 1 (call $invert (local.get 1))) (local.get 1))
      (func $child (param v128) (result v128) (return_call $forward (local.get 0)))
      (func (export "run") (param v128 externref) (result v128 externref v128) (local v128)
        (local.set 2 (local.get 0))
        (call $child (local.get 0)) drop
        (local.get 2) (local.get 1) (local.get 2)))`,
    {env:{invert:bits => bits^((1n<<128n)-1n)}});
    for (const bits of [vector.bits,1n<<127n,0n,vector.bits]) {
      const value = {type:'v128',bits};
      assert.deepEqual(engine.invokeRaw('run',value,{type:'externref',value:reference}),
        [value,{type:'externref',value:reference},value]);
    }
  });

  test(`${runtime}: local high bases refresh after guest and imported exception unwinding`,async () => {
    const provider = await create(binary),engine = await create(binary);
    provider.load('(module (tag (export "t")) (func (export "fail") throw 0))');
    for (const operation of ['throw $t','call $fail']) {
      engine.load(`(module
        (import "p" "t" (tag $t)) (import "p" "fail" (func $fail))
        (func $child (local v128)
          (local.set 0 (v128.const i64x2 -1 -1)) ${operation})
        (func (export "run") (param v128) (result v128) (local v128)
          (local.set 1 (local.get 0))
          (block $caught (try_table (catch $t $caught) (call $child)))
          (local.get 1)))`,{p:provider.exportNamespace()});
      for (const bits of [vector.bits,1n<<127n,0n,vector.bits]) {
        const value = {type:'v128',bits};
        assert.deepEqual(engine.invokeRaw('run',value),value);
      }
    }
  });
}
