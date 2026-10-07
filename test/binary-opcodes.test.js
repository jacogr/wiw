import {runtimeNames} from './runtime.js';
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile,writeFile,mkdtemp,rm} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createBootstrapInterpreter} from './runtime.js';

const binary=new URL('../build/wiw-opt.wasm',import.meta.url);
const table=await readFile(new URL('../scripts/opcodes.tsv',import.meta.url),'utf8');
const names=new Map(table.split('\n').filter(line=>line && !line.startsWith('#')).map(line=>{
  const fields=line.trim().split(/\s+/);return [Number(fields[7]),fields[1]];
}).filter(([code])=>code>=0));
names.set(1045,names.get(1044));names.set(1047,names.get(1046));
const original=await readFile(new URL('../build/wiw.wat',import.meta.url),'utf8');
// Expose only test hooks on the interpreter itself; no guest module is compiled here.
const source=original.replace(/\)\s*$/,`
  ;; Reset the private decoded-text cursor and seed a previous error for boundary tests.
  (func (export "wire-reset") (param $used i32) (param $error i32)
    (global.set $bin-out (i32.const 4096))
    (global.set $bin-used (local.get $used))
    (global.set $error (local.get $error))
    (global.set $tok (i32.const 4096)))
  ;; Publish the test cursor without exposing mutable state in the production ABI.
  (func (export "wire-used") (result i32) (global.get $bin-used))
  (export "wire-opname" (func $binary-opname))
)`);
const limit=1048576,out=4096;

async function adapter(runtime,directory) {
  if(runtime==='bootstrap') {
    const wat=join(directory,'engine.wat'),wasm=join(directory,'engine.wasm');
    await writeFile(wat,source);
    execFileSync('wat2wasm',[wat,'-o',wasm]);
    execFileSync('wasm-opt',['--enable-simd','--enable-bulk-memory','--enable-sign-ext','--enable-nontrapping-float-to-int','-O4','--converge','--strip-debug','--strip-producers',wasm,'-o',wasm]);
    const {instance:{exports:e}}=await WebAssembly.instantiate(await readFile(wasm));
    e.memory.grow(17);
    return {call:(name,...args)=>e[name](...args),
      read:(at,n)=>new Uint8Array(e.memory.buffer,at,n).slice(),
      write:(at,bytes)=>new Uint8Array(e.memory.buffer,at,bytes.length).set(bytes)};
  }
  const parent=await createBootstrapInterpreter(binary);
  parent.load(source);parent.setFuel(10000000);assert.ok(parent.growMemory(17)>=0);
  return {call:(name,...args)=>parent.invoke(name,...args),
    read:(at,n)=>parent.readMemory(at,n),write:(at,bytes)=>parent.writeMemory(at,bytes)};
}

for(const runtime of runtimeNames) {
  test(`${runtime}: every wire mnemonic, alias and hole preserves exact text and bounded stores`,async()=>{
    const directory=await mkdtemp(join(tmpdir(),'wiw-wire-'));
    try {
      const engine=await adapter(runtime,directory);
      const keys=[...Array.from({length:1057},(_,key)=>key),-1,0x7fffffff,0xffffffff];
      for(const key of keys) {
        const expected=names.get(key);
        engine.call('wire-reset',0,0);
        engine.write(out-1,new Uint8Array(64).fill(0xa5));
        assert.equal(engine.call('wire-opname',key),expected===undefined?0:1,`wire ${key}`);
        assert.equal(engine.call('error_code'),0);
        const length=expected===undefined?0:Buffer.byteLength(expected+' ');
        assert.equal(engine.call('wire-used'),length);
        assert.equal(engine.read(out-1,1)[0],0xa5);
        assert.equal(engine.read(out+length,1)[0],0xa5);
        if(expected!==undefined) assert.equal(Buffer.from(engine.read(out,length)).toString(),expected+' ');
      }
      for(const [key,name] of names) {
        const bytes=Buffer.from(name+' '),start=limit-bytes.length;
        engine.call('wire-reset',start,0);
        engine.write(out+start-1,new Uint8Array(bytes.length+3).fill(0xa5));
        assert.equal(engine.call('wire-opname',key),1);
        assert.equal(engine.call('error_code'),0);
        assert.equal(engine.call('wire-used'),limit);
        assert.deepEqual(Buffer.from(engine.read(out+start,bytes.length)),bytes);
        assert.equal(engine.read(out+start-1,1)[0],0xa5);
        assert.equal(engine.read(out+limit,1)[0],0xa5);
        // One byte less must fail without touching bytes past the expansion limit.
        engine.call('wire-reset',start+1,0);
        engine.write(out+start,new Uint8Array(bytes.length+3).fill(0xa5));
        assert.equal(engine.call('wire-opname',key),1);
        assert.equal(engine.call('error_code'),6);
        assert.ok(engine.call('wire-used')<=limit);
        assert.equal(engine.read(out+start,1)[0],0xa5);
        assert.equal(engine.read(out+limit,1)[0],0xa5);
        assert.equal(engine.read(out+limit+1,1)[0],0xa5);
      }
      // The first decoder error and cursor survive subsequent emission attempts.
      engine.call('wire-reset',17,8);engine.write(out+17,new Uint8Array(32).fill(0xa5));
      assert.equal(engine.call('wire-opname',734),1);
      assert.equal(engine.call('error_code'),8);assert.equal(engine.call('wire-used'),17);
      assert.deepEqual(engine.read(out+17,32),new Uint8Array(32).fill(0xa5));
    } finally {await rm(directory,{recursive:true,force:true});}
  });
}
