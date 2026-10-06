import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createBootstrapInterpreter,createInterpreter} from '../wiw.js';

const binary=new URL('../build/wiw-opt.wasm',import.meta.url);
for(const [runtime,create] of [['bootstrap',createBootstrapInterpreter],['interpreted',createInterpreter]]) {
  test(`${runtime}: growth retains packed and empty memories, zeroes new pages and charges no-op fuel`,async()=>{
    const engine=await create(binary);
    engine.load(`(module
      (memory $first 1 3) (memory $empty 0 2) (memory $last i64 1 3)
      (data (memory $first) (i32.const 0) "A")
      (data (memory $last) (i64.const 0) "B")
      (func (export "first") (param i32) (result i32) (i32.load8_u $first (local.get 0)))
      (func (export "empty") (param i32) (result i32) (i32.load8_u $empty (local.get 0)))
      (func (export "last") (param i64) (result i32) (i32.load8_u $last (local.get 0)))
      (func (export "growFirst") (param i32) (result i32) (memory.grow $first (local.get 0)))
      (func (export "growEmpty") (param i32) (result i32) (memory.grow $empty (local.get 0)))
      (func (export "growLast") (param i64) (result i64) (memory.grow $last (local.get 0))))`);
    assert.equal(engine.invoke('growFirst',0),1);
    assert.equal(engine.growMemory(0),1);
    assert.equal(engine.invoke('growEmpty',0),0);
    assert.equal(engine.invoke('growLast',0n),1n);
    assert.equal(engine.invoke('growFirst',1),1);
    assert.equal(engine.invoke('first',0),65);
    assert.equal(engine.invoke('last',0n),66);
    assert.deepEqual(engine.readMemory(65536,65536),new Uint8Array(65536));
    assert.equal(engine.invoke('growFirst',2),-1);
    assert.equal(engine.invoke('growFirst',-1),-1);
    assert.equal(engine.invoke('growEmpty',1),0);
    for(const address of [0,1,16384,65535]) assert.equal(engine.invoke('empty',address),0);
    assert.equal(engine.invoke('last',0n),66);
    assert.equal(engine.invoke('growLast',1n),1n);
    for(const address of [65536n,65537n,81920n,131071n]) assert.equal(engine.invoke('last',address),0);
    assert.equal(engine.invoke('growLast',-1n),-1n);
    assert.equal(engine.invoke('growLast',0n),2n);
    engine.setFuel(1);
    assert.throws(()=>engine.invoke('growFirst',0),/exhausted fuel/);
    engine.setFuel(2);
    assert.equal(engine.invoke('growFirst',0),2);
    engine.setFuel(100000);
    assert.equal(engine.invoke('first',0),65);
    assert.equal(engine.invoke('last',0n),66);
  });

  test(`${runtime}: bulk copies retain overlap, alias identity, cross-memory selection and trap atomicity`,async()=>{
    const provider=await create(binary),engine=await create(binary);
    provider.load('(module (memory (export "m") 1 3))');
    engine.load(`(module
      (memory $a (import "env" "m") 1 3)
      (memory $alias (import "env" "m") 1 3)
      (memory $other 1)
      (data (memory $other) (i32.const 0) "XYZ")
      (func (export "same") (param i32 i32 i32)
        (memory.copy $a $a (local.get 0) (local.get 1) (local.get 2)))
      (func (export "alias") (param i32 i32 i32)
        (memory.copy $a $alias (local.get 0) (local.get 1) (local.get 2)))
      (func (export "cross") (memory.copy $a $other (i32.const 20) (i32.const 0) (i32.const 3)))
      (func (export "other") (result i32) (i32.load8_u $other (i32.const 0)))
      (func (export "grow") (result i32) (memory.grow $alias (i32.const 1))))`,{env:provider.exportNamespace()});
    const expected=Uint8Array.from({length:65536},(_,index)=>(index*37+19)&255);
    provider.writeMemory(0,expected);
    for(const [name,destination,source,length] of [['same',1,0,19],['alias',0,3,17],['same',7,7,25]]) {
      engine.invoke(name,destination,source,length);expected.copyWithin(destination,source,source+length);
      assert.deepEqual(provider.readMemory(0,65536),expected);
    }
    for(const name of ['same','alias']) {
      engine.invoke(name,65536,65536,0);
      for(const args of [[0,65535,2],[65535,0,2],[65537,0,0],[0,65537,0]]) {
        assert.throws(()=>engine.invoke(name,...args),/memory out of bounds/);
        assert.deepEqual(provider.readMemory(0,65536),expected);
      }
    }
    engine.invoke('cross');expected.set(Buffer.from('XYZ'),20);
    assert.deepEqual(provider.readMemory(0,65536),expected);
    assert.equal(engine.invoke('grow'),1);
    assert.equal(engine.invoke('other'),88);
    assert.deepEqual(provider.readMemory(0,65536),expected);
    assert.deepEqual(provider.readMemory(65536,65536),new Uint8Array(65536));
    engine.invoke('cross');
    assert.deepEqual([...provider.readMemory(20,3)],[88,89,90]);
  });
}
