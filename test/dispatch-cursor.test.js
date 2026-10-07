import {runtimeFactories} from './runtime.js';
import assert from 'node:assert/strict';
import {test} from 'node:test';

const binary=new URL('../build/wiw-opt.wasm',import.meta.url);
for (const [runtime,create] of runtimeFactories) {
  test(`${runtime}: record cursors follow alternating branch-table targets and different callee ends without extra fuel`,async () => {
    const engine=await create(binary);
    const source=`(module
      (func $empty (export "empty"))
      (func $short (param i32) (result i32)
        call $empty (i32.add (local.get 0) (i32.const 1)))
      (func $long (param i32) (result i32)
        nop nop (i32.add (local.get 0) (i32.const 7)) return nop)
      (func (export "one") (result i32) i32.const 42)
      (func (export "run") (param i32) (result i32) (local i32)
        (block $outer
          (block $middle
            (block $inner
              (br_table $inner $middle $outer (local.get 0)))
            (local.set 1 (call $short (local.get 0))) (br $outer))
          (local.set 1 (call $long (local.get 0))))
        (local.get 1)))`;
    engine.load(source);
    engine.setFuel(0);
    assert.equal(engine.invoke('empty'),undefined);
    assert.throws(() => engine.invoke('one'),
      new RegExp(`exhausted fuel at byte ${source.indexOf('i32.const 42')}$`));
    engine.setFuel(1);
    assert.equal(engine.invoke('one'),42);
    engine.setFuel(10000);
    for (const input of [0,1,2,-1,1,0,2,0]) {
      assert.equal(engine.invoke('run',input),input===0 ? 1 : input===1 ? 8 : 0);
    }
  });

  test(`${runtime}: byte cursors survive memory growth, imported exception unwinding, tail suspension and shifted reload arenas`,async () => {
    const provider=await create(binary),engine=await create(binary);
    provider.load(`(module (tag $t (export "t") (param i32))
      (func (export "fail") (param i32) (throw $t (local.get 0))))`);
    const called=[];
    for (const padding of [0,4097]) {
      const source=`(;${' '.repeat(padding)};)(module
        (import "p" "t" (tag $t (param i32)))
        (import "p" "fail" (func $fail (param i32)))
        (import "env" "step" (func $step (param i32) (result i32)))
        (memory 1 3)
        (func $thrower (param i32) (call $fail (local.get 0)))
        (func $tail (param i32) (result i32) (return_call $step (local.get 0)))
        (func (export "run") (param i32) (result i32)
          (drop (memory.grow (i32.const 1)))
          (block $caught (result i32)
            (try_table (catch $t $caught) (call $thrower (local.get 0)))
            unreachable)
          (call $tail (local.get 0)) i32.add memory.size i32.add))`;
      engine.load(source,{p:provider.exportNamespace(),env:{step:value => {called.push(value);return value+10;}}});
      for (const [index,input] of [0,7,-1].entries()) {
        assert.equal(engine.invoke('run',input),2*input+10+Math.min(index+2,3));
      }
    }
    assert.deepEqual(called,[0,7,-1,0,7,-1]);
  });
}
