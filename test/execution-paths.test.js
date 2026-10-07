import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createBootstrapInterpreter,createInterpreter} from '../wiw.js';

for(const [runtime,create] of [['bootstrap',createBootstrapInterpreter],['interpreted',createInterpreter]]) {
  test(`${runtime}: fast operand sequences retain caller values through imports, branches and recovery`,async()=>{
    const engine=await create();
    let fail=false;
    engine.load(`(module
      (import "env" "step" (func $step (param i32) (result i32)))
      (func $inner (param i32) (result i32) local.get 0 call $step i32.const 1 i32.add)
      (func (export "run") (param i32) (result i32) (local $sum i32)
        i32.const 40 local.get 0 call $inner i32.add local.set $sum
        (block (result i32) i32.const -1 local.get $sum br 0))
      (func (export "exhaust") (result i32) i32.const 40 i32.const 2 i32.add))`,
      {env:{step:value=>{if(fail)throw new Error('step failed');return value+1;}}});
    assert.equal(engine.invoke('run',0),42);
    fail=true;
    assert.throws(()=>engine.invoke('run',0),/host import/);
    fail=false;
    assert.equal(engine.invoke('run',0),42);
    engine.setFuel(2);
    assert.throws(()=>engine.invoke('exhaust'),/exhausted fuel/);
    engine.setFuel(3);
    assert.equal(engine.invoke('exhaust'),42);
    engine.setFuel(100);
    assert.equal(engine.invoke('run',10),52);
  });
}
