import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {createTag,WiwException,runtimeFactories} from './runtime.js';

const text=`(module (tag $a (import "h" "a") (param i32 externref))
  (tag $alias (import "h" "alias") (param i32 externref))
  (import "h" "throw" (func $throw))
  (export "a" (tag $a)) (export "alias" (tag $alias))
  (func (export "run") (result i32 externref)
    block $caught (result i32 externref) try_table (catch $alias $caught) call $throw end unreachable end))`;

for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: host-defined tags import with canonical aliases and survive guest reloads`,async()=>{
    const parameters=['i32','externref'],tag=createTag(parameters),other=createTag(parameters);
    parameters[0]='f32';
    const i=await create(),object={}; let error;
    const imports={h:{a:tag,alias:tag,throw:()=>{throw error;}}};
    i.load(text,imports);
    assert.equal(Object.isFrozen(tag),true); assert.equal(tag.kind,'tag');
    assert.equal(i.getTag('a'),tag); assert.equal(i.getTag('alias'),tag);
    assert.equal(i.exportNamespace().a,tag);
    assert.deepEqual(i.tagSignature(tag),{params:['i32','externref']});
    error=i.createException(tag,42,object);
    assert.equal(error.is(tag),true); assert.equal(error.is(other),false);
    assert.deepEqual(i.invoke('run'),[42,object]);
    i.load('(module)');
    assert.equal(error.is(tag),true); assert.equal(error.getArg(tag,0),42);
    assert.throws(()=>i.createException(tag,42,object),/does not belong/);
    i.load(text,imports); assert.deepEqual(i.invoke('run'),[42,object]);
  });

  test(`${runtime}: separately instantiated guests share host tag identities and async exceptions`,async()=>{
    const tag=createTag(['i32','externref']),p=await create(),c=await create(),object={};
    p.load('(module (tag (import "h" "tag") (param i32 externref)))',{h:{tag}});
    const error=p.createException(tag,42,object);
    c.load(text,{h:{a:tag,alias:tag,throw:async()=>{await Promise.resolve();throw error;}}});
    assert.deepEqual(await c.invokeAsync('run'),[42,object]);
    p.load('(module)');
    assert.deepEqual(await c.invokeAsync('run'),[42,object]);
    assert.equal(error.is(c.getTag('a')),true);
  });

  test(`${runtime}: host tag signatures reject kind, nullability and concrete heap mismatches`,async()=>{
    const i=await create(),tag=createTag(['externref']);
    for(const declaration of ['i32','funcref','(ref extern)','externref i32']) {
      assert.throws(()=>i.load(`(module (tag (import "h" "tag") (param ${declaration})))`,{h:{tag}}),/signature mismatch/);
    }
    i.load('(module (tag (import "h" "tag") (param externref)))',{h:{tag}});
    assert.deepEqual(i.tagSignature(tag),{params:['externref']});
    const any=createTag(['anyref']);
    assert.throws(()=>i.load('(module (type $S (struct (field i32))) (tag (import "h" "tag") (param (ref null $S))))',{h:{tag:any}}),/signature mismatch/);
    assert.throws(()=>i.load('(module (memory (import "h" "tag") 0))',{h:{tag}}),/signature mismatch/);
    const zero=createTag();
    i.load('(module (tag (import "h" "tag")))',{h:{tag:zero}});
    assert.deepEqual(i.tagSignature(zero),{params:[]});
  });

  test(`${runtime}: all host tag public value kinds retain their declared payload shape`,async()=>{
    const i=await create();
    const tag=createTag(['i32','i64','f32','f64','v128','funcref','externref','anyref','exnref']);
    i.load(`(module (tag (import "h" "tag") (param i32 i64 f32 f64 v128 funcref externref anyref exnref)))`,{h:{tag}});
    const vector=(1n<<128n)-1n,object={};
    const values=[42,-7n,-0,Infinity,vector,null,object,null,null];
    const error=i.createException(tag,...values);
    assert.ok(error instanceof WiwException);
    assert.deepEqual(values.map((_,index)=>error.getArg(tag,index)),values);
    assert.equal(error.getArgRaw(tag,4).bits,vector);
  });

  test(`${runtime}: host tag arity boundaries and invalid factory input are checked before imports`,async()=>{
    for(const value of [null,{},'i32',0]) assert.throws(()=>createTag(value),/must be an array/);
    for(const name of ['', 'i16','void','structref',null,1,{},'toString']) assert.throws(()=>createTag([name]),/unsupported tag parameter/);
    assert.throws(()=>createTag(new Array(1)),/unsupported tag parameter/);
    assert.throws(()=>createTag(new Array(129).fill('i32')),/maximum 128/);
    const tag=createTag(new Array(128).fill('i32')),i=await create();
    i.load(`(module (tag (import "h" "tag") (param ${new Array(128).fill('i32').join(' ')})))`,{h:{tag}});
    const values=Array.from({length:128},(_,index)=>index);
    const error=i.createException(tag,...values);
    assert.equal(error.getArg(tag,127),127);
  });

  test(`${runtime}: host tag import and uncaught payloads match native text/binary tag bindings`,async()=>{
    const directory=await mkdtemp(join(tmpdir(),'wiw-host-tags-'));
    try {
      const source=`(module (tag $t (import "h" "t") (param i32 f32 externref))
        (func (export "throw") (param externref) i32.const -7 f32.const 1.25 local.get 0 throw $t))`;
      await writeFile(join(directory,'guest.wat'),source);
      execFileSync('wat2wasm',[join(directory,'guest.wat'),'-o',join(directory,'guest.wasm')]);
      const binary=await readFile(join(directory,'guest.wasm'));
      for(const input of [source,binary]) {
        const tag=createTag(['i32','f32','externref']),nativeTag=new WebAssembly.Tag({parameters:['i32','f32','externref']});
        const i=await create(),object={};
        if(typeof input==='string') i.load(input,{h:{t:tag}}); else i.loadBinary(input,{h:{t:tag}});
        const {instance}=await WebAssembly.instantiate(binary,{h:{t:nativeTag}});
        let actual,expected;
        try {i.invoke('throw',object);} catch(error){actual=error;}
        try {instance.exports.throw(object);} catch(error){expected=error;}
        assert.ok(actual instanceof WiwException); assert.ok(expected instanceof WebAssembly.Exception);
        assert.equal(actual.is(tag),expected.is(nativeTag));
        for(let n=0;n<3;n++) assert.ok(Object.is(actual.getArg(tag,n),expected.getArg(nativeTag,n)));
      }
    } finally {await rm(directory,{recursive:true,force:true});}
  });
}
