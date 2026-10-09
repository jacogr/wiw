import assert from 'node:assert/strict';
import {test} from 'node:test';
import {runtimeFactories,WiwException} from './runtime.js';

const source=`(module
  (tag $t (export "t") (export "alias") (param i32 i64 f32 f64 v128 externref))
  (tag (export "other") (param i32 i64 f32 f64 v128 externref))
  (func (export "throw") (param i32 i64 f32 f64 v128 externref)
    local.get 0 local.get 1 local.get 2 local.get 3 local.get 4 local.get 5 throw $t))`;

for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: guest exception inspection retains tag identity and typed/raw payload snapshots`,async()=>{
    const i=await create(); i.load(source);
    const tag=i.getTag('t'),object={},vector=(0xfedcba9876543210n<<64n)|0x123456789abcdef0n;
    assert.equal(tag,i.getTag('alias')); assert.equal(tag,i.getTag(0));
    assert.deepEqual(i.tagSignature(tag),{params:['i32','i64','f32','f64','v128','externref']});
    let caught;
    try {i.invoke('throw',-7,-8n,-0,Infinity,vector,object);} catch(error){caught=error;}
    assert.ok(caught instanceof WiwException); assert.equal(caught.is(tag),true);
    assert.equal(caught.is(i.getTag('other')),false);
    assert.deepEqual(Array.from({length:6},(_,n)=>caught.getArg(tag,n)),[-7,-8n,-0,Infinity,vector,object]);
    assert.deepEqual(caught.getArgRaw(tag,0),{type:'i32',bits:0xfffffff9n});
    assert.deepEqual(caught.getArgRaw(tag,4),{type:'v128',bits:vector});
    assert.equal(caught.getArgRaw(tag,5).value,object);
    assert.throws(()=>caught.getArg(i.getTag('other'),0),/tag mismatch/);
    for(const index of [-1,6,NaN,0.5,0n]) assert.throws(()=>caught.getArg(tag,index),/index out of bounds/);
    assert.throws(()=>caught.is({}),/requires a wiw tag/);
    assert.throws(()=>new WiwException().is(tag),/uninitialized/);
    const raw=caught.getArgRaw(tag,0); raw.bits=0n;
    assert.equal(caught.getArgRaw(tag,0).bits,0xfffffff9n);
  });

  test(`${runtime}: host-created exceptions enter synchronous and asynchronous guest handlers`,async()=>{
    const i=await create(); let thrown;
    i.load(`(module (import "h" "throw" (func $throw))
      (tag $t (export "t") (param i32 externref))
      (func (export "catch") (result i32 externref)
        block $caught (result i32 externref)
          try_table (catch $t $caught) call $throw end unreachable end)
      (func (export "uncaught") call $throw))`,{h:{throw:()=>{throw thrown;}}});
    const object={},tag=i.getTag('t'); thrown=i.createException(tag,42,object);
    assert.equal(thrown.is(tag),true); assert.equal(thrown.getArg(tag,1),object);
    assert.deepEqual(i.invoke('catch'),[42,object]);
    assert.throws(()=>i.invoke('uncaught'),error=>error===thrown);
    i.load(`(module (import "h" "throw" (func $throw))
      (tag $t (export "t") (param i32))
      (func (export "catch") (result i32)
        block $caught (result i32) try_table (catch $t $caught) call $throw end unreachable end))`,
      {h:{throw:async()=>{await Promise.resolve(); throw i.createException('t',42);}}});
    assert.equal(await i.invokeAsync('catch'),42);
    assert.equal(await i.invokeAsync('catch'),42);
  });

  test(`${runtime}: raw host exceptions retain signaling float bits and both vector halves`,async()=>{
    const i=await create(); let thrown;
    i.load(`(module (import "h" "throw" (func $throw))
      (tag $t (export "t") (param f32 f64 v128))
      (func (export "catch") (result f32 f64 v128)
        block $caught (result f32 f64 v128) try_table (catch $t $caught) call $throw end unreachable end))`,
      {h:{throw:()=>{throw thrown;}}});
    const args=[{type:'f32',bits:0x7fa12345n},{type:'f64',bits:0x7ff123456789abcdn},{type:'v128',bits:(1n<<128n)-17n}];
    thrown=i.createExceptionRaw('t',...args);
    args[0].bits=0n;
    const expected=[{type:'f32',bits:0x7fa12345n},args[1],args[2]];
    assert.deepEqual(i.invokeRaw('catch'),expected);
    assert.deepEqual(await i.invokeRawAsync('catch'),expected);
    const tag=i.getTag('t'); assert.ok(Number.isNaN(thrown.getArg(tag,0)));
    assert.deepEqual(thrown.getArgRaw(tag,0),expected[0]);
  });

  test(`${runtime}: host exception creation rejects invalid selectors, arity and concrete reference types`,async()=>{
    const i=await create(); assert.throws(()=>i.getTag(),/no loaded module/);
    i.load(`(module (type $S (struct (field i32))) (type $A (array i32))
      (tag (export "t") (param (ref $S)))
      (func (export "new") (result (ref $S)) i32.const 42 struct.new $S)
      (func (export "bad") (result (ref $A)) i32.const 1 array.new_default $A))`);
    const object=i.invoke('new'),bad=i.invoke('bad'),tag=i.getTag('t');
    for(const selector of [-1,1,0.5,NaN,null,{},0n]) assert.throws(()=>i.getTag(selector),/invalid tag index|wiw tag/);
    assert.throws(()=>i.createException('missing',object),/unknown export/);
    assert.throws(()=>i.getTag('new'),/export kind mismatch/);
    assert.throws(()=>i.createException('t'),/argument mismatch/);
    for(const value of [null,bad,{}]) assert.throws(()=>i.createException('t',value),/payload type mismatch/);
    assert.throws(()=>i.createExceptionRaw('t',{type:'i32',bits:1n}),/raw argument type mismatch/);
    const error=i.createException('t',object); assert.equal(error.getArg(tag,0),object);
    i.collectGarbage(); assert.equal(error.getArgRaw(tag,0).value,object);
    const other=await create(); other.load('(module (tag (export "t") (param i32)))');
    assert.throws(()=>i.createException(other.getTag('t'),object),/does not belong/);
    i.load('(module)'); assert.throws(()=>error.is(tag),/stale tag binding/);
    assert.throws(()=>i.getTag(),/no guest tag/);
  });

  test(`${runtime}: shared tag aliases identify host exceptions across independently loaded instances`,async()=>{
    const p=await create(),c=await create(); p.load('(module (tag (export "t") (param i32 externref)))');
    const tag=p.getTag('t'),object={},error=p.createException(tag,42,object);
    c.load(`(module (tag $t (import "p" "t") (param i32 externref))
      (import "h" "throw" (func $throw)) (export "t" (tag $t))
      (func (export "catch") (result i32 externref)
        block $caught (result i32 externref) try_table (catch $t $caught) call $throw end unreachable end))`,
      {p:{t:tag},h:{throw:()=>{throw error;}}});
    assert.equal(error.is(c.getTag('t')),true);
    assert.deepEqual(c.invoke('catch'),[42,object]);
    const created=c.createException(tag,43,object);
    assert.equal(created.is(tag),true); assert.equal(created.getArg(tag,0),43);
    p.load('(module (tag (export "t") (param i32 externref)))');
    assert.equal(error.is(p.getTag('t')),false);
  });
}

for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: typed host payload inspection matches native WebAssembly exception APIs`,async()=>{
    const i=await create();
    i.load('(module (tag (export "t") (param i32 i64 f32 f64 externref)) (tag (export "other") (param i32 i64 f32 f64 externref)))');
    const types=['i32','i64','f32','f64','externref'],values=[-7,-8n,1.1,-0,{}];
    const tag=i.getTag('t'),other=i.getTag('other'),error=i.createException(tag,...values);
    const nativeTag=new WebAssembly.Tag({parameters:types}),nativeOther=new WebAssembly.Tag({parameters:types});
    const native=new WebAssembly.Exception(nativeTag,values);
    assert.equal(error.is(tag),native.is(nativeTag)); assert.equal(error.is(other),native.is(nativeOther));
    for(let n=0;n<values.length;n++) assert.ok(Object.is(error.getArg(tag,n),native.getArg(nativeTag,n)));
    const promise=Promise.resolve(42),opaque={get then(){throw Error('opaque');}};
    for(const value of [promise,opaque,undefined,null,NaN,-0]) {
      const exception=i.createException(tag,0,0n,0,0,value);
      assert.ok(Object.is(exception.getArg(tag,4),value));
    }
  });

  test(`${runtime}: unknown host tag identities use catch-all and preserve the original exception object`,async()=>{
    const p=await create(),c=await create(); p.load('(module (tag (export "t") (param i32)))');
    const error=p.createException('t',42);
    c.load(`(module (import "h" "throw" (func $throw))
      (func (export "catch") (result i32)
        block $caught try_table (catch_all $caught) call $throw end unreachable end i32.const 42)
      (func (export "uncaught") call $throw))`,{h:{throw:()=>{throw error;}}});
    assert.equal(c.invoke('catch'),42);
    assert.throws(()=>c.invoke('uncaught'),caught=>caught===error);
    assert.equal(error.getArg(p.getTag('t'),0),42);
  });

  test(`${runtime}: async start can create a void exception and handle it in the guest`,async()=>{
    const i=await create();
    await i.loadAsync(`(module (import "h" "throw" (func $throw)) (tag $t (export "t"))
      (global (export "g") (mut i32) (i32.const 0))
      (func $start block $caught try_table (catch $t $caught) call $throw end unreachable end
        i32.const 42 global.set 0) (start $start))`,{h:{throw:async()=>{
      await Promise.resolve(); const error=i.createException('t');
      assert.deepEqual(i.tagSignature('t'),{params:[]});
      assert.throws(()=>error.getArg(i.getTag('t'),0),/out of bounds/);
      throw error;
    }}});
    assert.equal(i.getGlobal('g'),42);
  });
}
