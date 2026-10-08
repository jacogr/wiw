import assert from 'node:assert/strict';
import {test} from 'node:test';
import fs from 'node:fs';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {WASI} from 'node:wasi';
import {runtimeFactories} from './runtime.js';
import {createWasiHost,WasiExit} from './helpers/wasi.js';

const source=`(module
  (import "wasi_snapshot_preview1" "fd_read" (func $read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_open" (func $open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_seek" (func $seek (param i32 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_tell" (func $tell (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_close" (func $close (param i32) (result i32)))
  (memory (export "memory") 1 2)
  (data (i32.const 128) "input.txt")
  (func $ok (param i32) local.get 0 if unreachable end)
  (func (export "_start") (local $fd i32)
    i32.const 0 i32.const 200 i32.store
    i32.const 4 i32.const 3 i32.store
    i32.const 0 i32.const 0 i32.const 1 i32.const 64 call $read call $ok
    i32.const 64 i32.load i32.const 3 i32.ne if unreachable end
    i32.const 1 memory.grow i32.const 1 i32.ne if unreachable end
    i32.const 65536 i32.const 0x5a5958 i32.store
    i32.const 0 i32.const 65536 i32.store
    i32.const 1 i32.const 0 i32.const 1 i32.const 68 call $write call $ok
    i32.const 68 i32.load i32.const 3 i32.ne if unreachable end
    i32.const 3 i32.const 0 i32.const 128 i32.const 9 i32.const 0
    i64.const 102 i64.const 0 i32.const 0 i32.const 72 call $open call $ok
    i32.const 72 i32.load local.set $fd
    local.get $fd i64.const 4294967303 i32.const 0 i32.const 80 call $seek call $ok
    local.get $fd i32.const 88 call $tell call $ok
    i32.const 80 i64.load i64.const 4294967303 i64.ne if unreachable end
    i32.const 88 i64.load i64.const 4294967303 i64.ne if unreachable end
    local.get $fd i64.const 0 i32.const 0 i32.const 80 call $seek call $ok
    i32.const 0 i32.const 512 i32.store
    i32.const 4 i32.const 5 i32.store
    local.get $fd i32.const 0 i32.const 1 i32.const 92 call $read call $ok
    local.get $fd call $close call $ok
    i32.const 3 call $close call $ok)
  (func (export "bad") (result i32)
    i32.const 0 i32.const 131072 i32.store
    i32.const 4 i32.const 1 i32.store
    i32.const 1 i32.const 0 i32.const 1 i32.const 68 call $write))`;

for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: test WASI bridge matches native file IO, growth, i64 offsets and bounds`,async()=>{
    const directory=await mkdtemp(join(tmpdir(),'wiw-wasi-'));
    const descriptors=[];
    const options=label=>{
      const stdin=fs.openSync(join(directory,'stdin'),'r'),stdout=fs.openSync(join(directory,label+'-out'),'w');
      const stderr=fs.openSync(join(directory,label+'-err'),'w');
      descriptors.push(stdin,stdout,stderr);
      return {args:[],env:{},preopens:{'/usr':directory},stdin,stdout,stderr};
    };
    try {
      await writeFile(join(directory,'stdin'),'ABC');await writeFile(join(directory,'input.txt'),'hello-world');
      const wat=join(directory,'guest.wat'),wasm=join(directory,'guest.wasm');
      await writeFile(wat,source);execFileSync('wat2wasm',[wat,'-o',wasm]);
      const binary=await readFile(wasm),nativeWasi=new WASI({...options('native'),version:'preview1'});
      const {instance}=await WebAssembly.instantiate(binary,nativeWasi.getImportObject());
      assert.equal(nativeWasi.start(instance),0);
      const expected=instance.exports.bad();assert.notEqual(expected,0);
      const engine=await create();
      for(const format of ['text','binary']) {
        const host=createWasiHost(engine,options(format));
        if(format==='text')engine.load(source,host.imports);else engine.loadBinary(binary,host.imports);
        assert.equal(host.start(),0);assert.throws(()=>host.start(),/already started/);
        assert.equal(host.invoke('bad'),expected,'a pointer at guest end remains out of bounds');
        for(const [offset,length] of [[64,32],[200,3],[512,5],[65536,4]]) {
          assert.deepEqual(engine.readMemory(offset,length),new Uint8Array(instance.exports.memory.buffer,offset,length));
        }
        assert.equal(await readFile(join(directory,format+'-out'),'utf8'),'XYZ');
        assert.equal(await readFile(join(directory,format+'-err'),'utf8'),'');
      }
      assert.equal(await readFile(join(directory,'native-out'),'utf8'),'XYZ');
    }finally {
      for(const fd of descriptors)fs.closeSync(fd);
      await rm(directory,{recursive:true,force:true});
    }
  });

  test(`${runtime}: test WASI process exit preserves its code and leaves the interpreter usable`,async()=>{
    const engine=await create(),host=createWasiHost(engine,{args:[],env:{}});
    engine.load(`(module
      (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
      (memory 1)
      (func (export "_start") i32.const 7 call $exit unreachable)
      (func (export "exit") i32.const -1 call $exit)
      (func (export "answer") (result i32) i32.const 42))`,host.imports);
    assert.equal(host.start(),7);
    assert.equal(host.invoke('answer'),42);
    assert.throws(()=>host.invoke('exit'),error=>error instanceof WasiExit&&error.code===4294967295);
    assert.equal(engine.invoke('answer'),42);
    const automatic=createWasiHost(engine,{args:[],env:{},stdout:1});
    engine.load(`(module
      (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
      (memory 1)
      (func $init i32.const 1 i32.const 0 i32.const 0 i32.const 4 call $write drop)
      (start $init)
      (func (export "answer") (result i32) i32.const 42))`,automatic.imports);
    assert.equal(automatic.invoke('answer'),42,'WASI is available during module start');
  });
}
