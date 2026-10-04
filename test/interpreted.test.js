import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createInterpreter,createInterpretedInterpreter} from '../wiw.js';
for(const binary of ['wiw-opt.wasm']) {
  const url=new URL(`../build/${binary}`,import.meta.url);
  test(`${binary}: interpreted frontend preserves raw values, host suspension and reload isolation`,async()=>{
    const engine=await createInterpretedInterpreter(url);
    engine.load(`(module
      (func $host (import "env" "host") (param externref v128) (result externref v128 f64))
      (func (export "f") (param externref v128) (result externref v128 f64) local.get 0 local.get 1 call $host))`,
      {env:{host:(reference,bits)=>[reference,bits,-0]}});
    const reference={},bits=(1n<<127n)|42n;
    assert.deepEqual(engine.invokeRaw('f',{type:'externref',value:reference},{type:'v128',bits}),
      [{type:'externref',value:reference},{type:'v128',bits},{type:'f64',bits:1n<<63n}]);
    assert.throws(()=>engine.load('(module (func (result i64) i32.const 1))'),/operand stack/);
    engine.load('(module (func (export "f") (result f64) f64.const nan:0x1))');
    assert.deepEqual(engine.invokeRaw('f'),{type:'f64',bits:0x7ff0000000000001n});
    engine.loadBinary(Uint8Array.from([0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,3,2,1,0,7,5,1,1,102,0,0,10,6,1,4,0,65,42,11]));
    assert.equal(engine.invoke('f'),42);
    engine.load('(module (func (export "f") loop br 0 end))');engine.setFuel(5);
    assert.throws(()=>engine.invoke('f'),/exhausted fuel/);
    engine.load('(module (func (export "f") (result i32) i32.const 7))');
    assert.equal(engine.invoke('f'),7);
  });
  test(`${binary}: interpreted instances share resources and typed references across bootstrap and interpreted owners`,async()=>{
    const provider=await createInterpretedInterpreter(url),consumer=await createInterpretedInterpreter(url),native=await createInterpreter(url);
    provider.load(`(module (memory (export "m") 1 3) (table (export "t") 1 3 funcref)
      (global (export "v") (mut v128) (v128.const i64x2 7 0x1000000000))
      (func $f (export "f") (param externref) (result externref i64) local.get 0 i64.const 42)
      (elem (i32.const 0) func $f))`);
    const source=`(module (memory (import "p" "m") 1 3) (table (import "p" "t") 1 3 funcref)
      (global $v (import "p" "v") (mut v128))
      (func (export "call") (param externref) (result externref i64) local.get 0 i32.const 0 call_indirect (param externref) (result externref i64))
      (func (export "write") i32.const 0 i32.const 42 i32.store8)
      (func (export "grow") (result i32) i32.const 1 memory.grow)
      (func (export "get") (result v128) global.get $v)
      (func (export "set") (param v128) local.get 0 global.set $v))`;
    for(const engine of [consumer,native]) {
      engine.load(source,{p:provider.exportNamespace()});
      const reference={};assert.deepEqual(engine.invoke('call',reference),[reference,42n]);
      assert.equal(engine.invoke('get'),(1n<<100n)|7n);
      engine.invoke('write');assert.equal(provider.readMemory(0,1)[0],42);
      engine.invoke('set',(1n<<100n)|9n);assert.equal(provider.getGlobal('v'),(1n<<100n)|9n);
      provider.setGlobal('v',(1n<<100n)|7n);
    }
    assert.equal(consumer.invoke('grow'),1);assert.equal(provider.readMemory(131072,0).length,0);
  });
}
