import assert from 'node:assert/strict';
import {after,before,test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {runtimeFactories,runtimeNames,createBootstrapInterpreter} from './runtime.js';

const fields=[['i8',1,'i32'],['i16',2,'i32'],['i32',4,'i32'],['i64',8,'i64'],
  ['f32',4,'i32'],['f64',8,'i64'],['v128',16,'v128']];
const escaped=bytes=>Array.from(bytes,byte=>'\\'+byte.toString(16).padStart(2,'0')).join('');
const raw=(bytes,field)=>{
  let bits=0n;for(let i=bytes.length-1;i>=0;i--)bits=(bits<<8n)|BigInt(bytes[i]);
  return field==='v128'?bits:field==='i64'||field==='f64'?BigInt.asIntN(64,bits):
    field==='i32'||field==='f32'?Number(BigInt.asIntN(32,bits)):Number(bits);
};
for(const [runtime,create] of runtimeFactories) test(`${runtime}: GC data constructors and partial initialization preserve bits, bounds, dropped segments and fuel`,async()=>{
  const engine=await create();
  for(const [field,width,result] of fields) {
    const payload=Buffer.from(Array.from({length:33*width+1},(_,i)=>(i*73+193)&255));
    // Include exact signed-zero and NaN payload encodings rather than performing floating arithmetic.
    if(field==='f32') payload.set([0,0,0,128,0x45,0x23,0xc1,0x7f,0x45,0x23,0x81,0x7f],1);
    if(field==='f64') payload.set([0,0,0,0,0,0,0,128,0x45,0x23,0,0,0,0,0xf8,0x7f,0x45,0x23,0,0,0,0,0xf0,0x7f],1);
    const get=field==='i8'||field==='i16'?'array.get_u':'array.get';
    const cast=field==='f32'?'i32.reinterpret_f32':field==='f64'?'i64.reinterpret_f64':'';
    const source=`(module (type $A (array (mut ${field}))) (data $d "${escaped(payload)}")
      (global $a (mut (ref null $A)) (ref.null $A))
      (func (export "new") (param i32 i32) local.get 0 local.get 1 array.new_data $A $d global.set $a)
      (func (export "default") (param i32) local.get 0 array.new_default $A global.set $a)
      (func (export "init") (param i32 i32 i32) global.get $a local.get 0 local.get 1 local.get 2 array.init_data $A $d)
      (func (export "get") (param i32) (result ${result}) global.get $a local.get 0 ${get} $A ${cast})
      (func (export "drop") data.drop $d)
      (func (export "null") ref.null $A i32.const -1 i32.const -1 i32.const 0 array.init_data $A $d))`;
    engine.load(source);
    for(const count of [0,1,2,3,7,8,9,16,17,31,32,33]) {
      engine.invoke('new',1,count);
      for(let i=0;i<count;i++) assert.equal(engine.invoke('get',i),raw(payload.subarray(1+i*width,1+(i+1)*width),field),`${field}/new/${count}/${i}`);
      engine.invoke('init',count,payload.length,0);
    }
    engine.invoke('default',33);
    engine.invoke('init',1,1,31);
    for(let i=0;i<33;i++) assert.equal(engine.invoke('get',i),i===0||i===32?(result==='i32'?0:0n):raw(payload.subarray(1+(i-1)*width,1+i*width),field),`${field}/partial/${i}`);
    const snapshot=Array.from({length:33},(_,i)=>engine.invoke('get',i));
    for(const args of [[32,0,2],[34,0,0],[-1,0,0],[0,0,-1]]) {
      assert.throws(()=>engine.invoke('init',...args),/array out of bounds/);
      assert.deepEqual(Array.from({length:33},(_,i)=>engine.invoke('get',i)),snapshot);
    }
    for(const args of [[0,payload.length,1],[0,payload.length+1,0],[0,-1,0],[0,2147483647,1]]) {
      assert.throws(()=>engine.invoke('init',...args),/memory out of bounds/);
      assert.deepEqual(Array.from({length:33},(_,i)=>engine.invoke('get',i)),snapshot);
    }
    assert.throws(()=>engine.invoke('null'),/null reference/);
    engine.setFuel(4);
    assert.throws(()=>engine.invoke('init',0,1,33),error=>{
      assert.equal(error.message,`exhausted fuel at byte ${source.indexOf('array.init_data')}`);return true;
    });
    engine.setFuel(10000000);assert.deepEqual(Array.from({length:33},(_,i)=>engine.invoke('get',i)),snapshot);
    engine.setFuel(5);engine.invoke('init',0,1,33);engine.setFuel(10000000);
    engine.invoke('drop');engine.invoke('init',33,0,0);engine.invoke('new',0,0);
    assert.throws(()=>engine.invoke('new',0,1),/memory out of bounds/);
    assert.throws(()=>engine.invoke('new',1,0),/memory out of bounds/);
  }

  engine.load(`(module (memory 1) (type $A (array (mut i8))) (data $d (i32.const 0) "a")
    (func (export "new") (param i32 i32) (result i32)
      local.get 0 local.get 1 array.new_data $A $d array.len))`);
  assert.equal(engine.invoke('new',0,0),0);
  assert.throws(()=>engine.invoke('new',0,1),/memory out of bounds/);
  assert.throws(()=>engine.invoke('new',1,0),/memory out of bounds/);
});

let directory,probe,binary;
before(async()=>{
  directory=await mkdtemp(join(tmpdir(),'wiw-gc-data-'));
  const source=await readFile(new URL('../build/wiw.wat',import.meta.url),'utf8'),end=source.lastIndexOf(')');
  probe=source.slice(0,end)+`
    ;; Expose the raw numeric copy helper only in temporary test engines.
    (func (export "copy_data") (param i32 i32 i32 i32)
      local.get 0 local.get 1 local.get 2 local.get 3 call $gc-data)
  `+source.slice(end);
  const wat=join(directory,'probe.wat');binary=join(directory,'probe-opt.wasm');await writeFile(wat,probe);
  execFileSync('wat2wasm',[wat,'-o',binary]);
  execFileSync('wasm-opt',['--enable-simd','--enable-bulk-memory','--enable-sign-ext','--enable-nontrapping-float-to-int','-O4','--converge','--strip-debug','--strip-producers',binary,'-o',binary]);
});
after(async()=>{if(directory)await rm(directory,{recursive:true,force:true});});
for(const runtime of runtimeNames) test(`${runtime}: GC numeric copies read exact source widths at physical memory end and clear poisoned padding`,async()=>{
  let write,read,copy;
  if(runtime==='bootstrap') {
    const {instance:{exports:e}}=await WebAssembly.instantiate(await readFile(binary));
    write=(p,bytes)=>new Uint8Array(e.memory.buffer).set(bytes,p);
    read=(p,n)=>new Uint8Array(e.memory.buffer,p,n).slice();copy=(...args)=>e.copy_data(...args);
  } else {
    const parent=await createBootstrapInterpreter();parent.load(probe);parent.setFuel(10000000);
    write=(p,bytes)=>parent.writeMemory(p,bytes);read=(p,n)=>parent.readMemory(p,n);
    copy=(...args)=>parent.invoke('copy_data',...args);
  }
  for(const width of [1,2,4,8,16]) for(const count of [1,2,3,7,8,9,16,17,33]) {
    const dest=8192,payload=Uint8Array.from({length:width*count},(_,i)=>(i*73+255)&255),source=65536-payload.length;
    write(dest-16,new Uint8Array(count*16+32).fill(0xa5));write(source,payload);copy(dest,source,count,width);
    const expected=new Uint8Array(count*16+32).fill(0xa5);
    for(let i=0;i<count;i++) {expected.fill(0,16+i*16,32+i*16);expected.set(payload.subarray(i*width,(i+1)*width),16+i*16);}
    assert.deepEqual(read(dest-16,expected.length),expected,`${width}/${count}`);
    assert.deepEqual(read(source,payload.length),payload);
  }
  copy(65536,65536,0,16);copy(65536,65536,0,1);
});
