import assert from 'node:assert/strict';import {test} from 'node:test';import {runtimeFactories} from './runtime.js';
for(const [runtime,create] of runtimeFactories) test(`${runtime}: table fill, growth and declared initializers preserve references, boundaries, aliases and fuel`,async()=>{
 const engine=await create(),source=`(module (type $F (func (result i32)))
  (func $first (type $F) i32.const 42) (func $second (type $F) i32.const 99) (elem declare func $first $second)
  (table (export "t") 4096 4096 funcref)
  (func (export "first") (param i32 i32) local.get 0 ref.func $first local.get 1 table.fill)
  (func (export "second") (param i32 i32) local.get 0 ref.func $second local.get 1 table.fill)
  (func (export "null") (param i32 i32) local.get 0 ref.null func local.get 1 table.fill)
  (func (export "get") (param i32) (result i32) local.get 0 call_indirect (type $F))
  (func (export "isNull") (param i32) (result i32) local.get 0 table.get ref.is_null))`;
 engine.load(source);
 const observer=await create();observer.load(`(module (table (import "p" "t") 4096 funcref)
   (func (export "null") (param i32) (result i32) local.get 0 table.get ref.is_null))`,{p:engine.exportNamespace()});
 for(const count of [0,1,2,3,7,8,9,16,17,31,32,33,4095,4096])for(const name of ['first','second','null']){
  engine.invoke('second',0,4096);const start=count===4096?0:1;engine.invoke(name,start,count);
  for(const index of new Set([0,start,Math.min(start+count-1,4095),Math.min(start+count,4095),4095])){
   const filled=index>=start&&index<start+count;
   assert.equal(engine.invoke('isNull',index),filled&&name==='null'?1:0,`${name}/${count}/${index}`);
   assert.equal(observer.invoke('null',index),filled&&name==='null'?1:0);
   if(!(filled&&name==='null'))assert.equal(engine.invoke('get',index),filled&&name==='first'?42:99);
  }
 }
 engine.invoke('first',0,4096);
 for(const args of [[4096,1],[4097,0],[-1,0],[1,-1]]){assert.throws(()=>engine.invoke('second',...args),/table.*bounds/);assert.equal(engine.invoke('get',0),42);assert.equal(engine.invoke('get',4095),42);}
 engine.invoke('null',4096,0);
 engine.setFuel(3);assert.throws(()=>engine.invoke('second',0,4096),new RegExp(`exhausted fuel at byte ${source.indexOf('table.fill',source.indexOf('(export "second")'))}$`));
 engine.setFuel(100000);assert.equal(engine.invoke('get',4095),42);engine.setFuel(4);engine.invoke('second',0,4096);engine.setFuel(100000);assert.equal(engine.invoke('get',4095),99);
 // Opaque externrefs repeat without changing identity, including null and undefined.
 engine.load(`(module (table $t (export "t") 1 65 externref)
  (func (export "grow") (param externref i32) (result i32) local.get 0 local.get 1 table.grow $t)
  (func (export "get") (param i32) (result externref) local.get 0 table.get $t))`);
 for(const value of [{answer:42},undefined,null]){engine.load(`(module (table $t 1 65 externref)
  (func (export "grow") (param externref i32) (result i32) local.get 0 local.get 1 table.grow $t)
  (func (export "get") (param i32) (result externref) local.get 0 table.get $t))`);assert.equal(engine.invoke('grow',value,64),1);assert.equal(engine.invoke('get',1),value);assert.equal(engine.invoke('get',64),value);assert.equal(engine.invoke('grow',value,1),-1);assert.equal(engine.invoke('get',64),value);}
 engine.load(`(module (type $F (func (result i32))) (func $answer (type $F) i32.const 42)
  (table 4096 funcref (ref.func $answer)) (func (export "get") (param i32) (result i32) local.get 0 call_indirect (type $F)))`);
 assert.equal(engine.invoke('get',0),42);assert.equal(engine.invoke('get',4095),42);
 // A nonuniform reference word is repeated, then active elements override only their own range.
 engine.load(`(module (type $F (func (result i32)))
  (func $first (type $F) i32.const 42) (func $second (type $F) i32.const 99)
  (table 4096 funcref (ref.func $second)) (elem (i32.const 17) func $first)
  (func (export "get") (param i32) (result i32) local.get 0 call_indirect (type $F)))`);
 for(const index of [0,16,17,18,4095]) assert.equal(engine.invoke('get',index),index===17?42:99);

});
