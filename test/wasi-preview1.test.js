import assert from 'node:assert/strict';
import {test} from 'node:test';
import {WASI} from 'node:wasi';
import {mkdtemp,mkdir,writeFile,readFile,rm,readdir,readlink} from 'node:fs/promises';
import fs from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {execFileSync} from 'node:child_process';
import {runtimeFactories} from './runtime.js';
import {createWasiHost} from '../wasi.js';

// Preview 1 lowered ABI signatures, checked by linking the same imports to native Node WASI.
const signatures={
  args_get:'ii',args_sizes_get:'ii',environ_get:'ii',environ_sizes_get:'ii',clock_res_get:'ii',clock_time_get:'iIi',
  fd_advise:'iIIi',fd_allocate:'iII',fd_close:'i',fd_datasync:'i',fd_fdstat_get:'ii',fd_fdstat_set_flags:'ii',
  fd_fdstat_set_rights:'iII',fd_filestat_get:'ii',fd_filestat_set_size:'iI',fd_filestat_set_times:'iIIi',
  fd_pread:'iiiIi',fd_pwrite:'iiiIi',fd_prestat_get:'ii',fd_prestat_dir_name:'iii',fd_read:'iiii',fd_readdir:'iiiIi',
  fd_renumber:'ii',fd_seek:'iIii',fd_sync:'i',fd_tell:'ii',fd_write:'iiii',
  path_create_directory:'iii',path_filestat_get:'iiiii',path_filestat_set_times:'iiiiIIi',path_link:'iiiiiii',
  path_open:'iiiiiIIii',path_readlink:'iiiiii',path_remove_directory:'iii',path_rename:'iiiiii',path_symlink:'iiiii',
  path_unlink_file:'iii',poll_oneoff:'iiii',proc_exit:'i',proc_raise:'i',random_get:'ii',sched_yield:'',
  sock_accept:'iii',sock_recv:'iiiiii',sock_send:'iiiii',sock_shutdown:'ii'
};
const source=`(module ${Object.entries(signatures).map(([name,types])=>
  `(import "wasi_snapshot_preview1" "${name}" (func $${name} ${types?`(param ${[...types].map(t=>t==='I'?'i64':'i32').join(' ')})`:''} ${name==='proc_exit'?'':'(result i32)'}))`).join('')}
  (memory (export "memory") 1)
  ${Object.entries(signatures).map(([name,types])=>`(func (export "${name}") ${types?`(param ${[...types].map(t=>t==='I'?'i64':'i32').join(' ')})`:''}
    ${name==='proc_exit'?'':'(result i32)'} ${[...types].map((_,i)=>`local.get ${i}`).join(' ')} call $${name})`).join('')})`;
const text=s=>new TextEncoder().encode(s);

async function pair(create,body) {
  const directory=await mkdtemp(join(tmpdir(),'wiw-preview1-'));let host,wasi;
  try {
    const wat=join(directory,'guest.wat'),wasm=join(directory,'guest.wasm');await writeFile(wat,source);
    execFileSync('wat2wasm',[wat,'-o',wasm]);const binary=await readFile(wasm);
    const roots=[join(directory,'native'),join(directory,'wiw')];for(const root of roots){await mkdir(root);await writeFile(join(root,'input'),'abcdef');}
    const options=root=>({args:['guest','héllo'],env:{TEST:'value=42',UNICODE:'λ'},preopens:{'/sandbox':root}});
    wasi=new WASI({...options(roots[0]),version:'preview1',returnOnExit:true});
    const {instance}=await WebAssembly.instantiate(binary,wasi.getImportObject());wasi.initialize(instance);
    const engine=await create();host=createWasiHost(engine,options(roots[1]));engine.loadBinary(binary,host.imports);host.initialize();
    assert.deepEqual(Object.keys(host.imports.wasi_snapshot_preview1).sort(),Object.keys(signatures).sort());
    const native={call:(name,...args)=>instance.exports[name](...args),read:(p,n)=>new Uint8Array(instance.exports.memory.buffer,p,n).slice(),
      write:(p,value)=>new Uint8Array(instance.exports.memory.buffer,p,value.length).set(value),view:()=>new DataView(instance.exports.memory.buffer)};
    const wiw={call:(name,...args)=>host.invoke(name,...args),read:(p,n)=>engine.readMemory(p,n,'memory'),
      write:(p,value)=>engine.writeMemory(p,value,'memory'),view:()=>new DataView(engine.readMemory(0,65536).buffer)};
    await body({native,wiw,host,engine,roots});
  } finally {
    host?.close();
    // Native fixture descriptors are owned by that fixture, never standard streams.
    if(wasi)for(let fd=3;fd<20;fd++)wasi.wasiImport.fd_close(fd);
    await rm(directory,{recursive:true,force:true});
  }
}

for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: all Preview 1 import signatures link and invalid syscalls preserve native errno behavior`,async()=>{
    await pair(create,({native,wiw})=>{
      for(const [name,types] of Object.entries(signatures)) {
        if(name==='proc_exit')continue;
        const args=[...types].map(t=>t==='I'?0n:0);
        if(name.startsWith('fd_')||name.startsWith('sock_')||name.startsWith('path_')) {
          args[name==='path_symlink'?2:0]=9999;
        }else if(name==='proc_raise')args[0]=-1;
        else if(name==='random_get'){args[0]=65536;args[1]=1;}
        else if(name==='clock_time_get')args[2]=65536;
        else if(name==='clock_res_get')args[1]=65536;
        else if(name==='poll_oneoff'){args[1]=65536;args[2]=1;}
        else if(name!=='sched_yield')args[0]=65536;
        assert.equal(wiw.call(name,...args),native.call(name,...args),name);
      }
    });
  });

  test(`${runtime}: argv, environment, preopens, clocks, randomness and polling copy complete wasm32 records`,async()=>{
    await pair(create,({native,wiw})=>{
      for(const name of ['args_sizes_get','environ_sizes_get']) {
        assert.equal(native.call(name,0,4),0);assert.equal(wiw.call(name,0,4),0);
        assert.deepEqual(wiw.read(0,8),native.read(0,8));
        const count=native.view().getUint32(0,true),length=native.view().getUint32(4,true);
        const getter=name==='args_sizes_get'?'args_get':'environ_get';
        assert.equal(native.call(getter,64,256),0);assert.equal(wiw.call(getter,64,256),0);
        assert.deepEqual(wiw.read(64,count*4),native.read(64,count*4));assert.deepEqual(wiw.read(256,length),native.read(256,length));
      }
      for(const guest of [native,wiw]) {
        assert.equal(guest.call('fd_prestat_get',3,512),0);
        assert.equal(guest.view().getUint32(516,true),8);assert.equal(guest.call('fd_prestat_dir_name',3,520,8),0);
        assert.deepEqual(guest.read(520,8),text('/sandbox'));
        assert.equal(guest.call('clock_res_get',1,600),0);assert.ok(guest.view().getBigUint64(600,true)>0n);
        assert.equal(guest.call('clock_time_get',1,1n,608),0);const before=guest.view().getBigUint64(608,true);
        assert.equal(guest.call('clock_time_get',1,1n,608),0);assert.ok(guest.view().getBigUint64(608,true)>=before);
        guest.write(640,new Uint8Array(34).fill(0xcc));assert.equal(guest.call('random_get',641,32),0);
        assert.equal(guest.read(640,1)[0],0xcc);assert.equal(guest.read(673,1)[0],0xcc);
        assert.notDeepEqual(guest.read(641,32),new Uint8Array(32).fill(0xcc));
        const subscription=new Uint8Array(48),view=new DataView(subscription.buffer);
        view.setBigUint64(0,42n,true);view.setUint32(16,1,true);guest.write(704,subscription);
        assert.equal(guest.call('poll_oneoff',704,768,1,800),0);
        assert.equal(guest.view().getUint32(800,true),1);assert.equal(guest.view().getBigUint64(768,true),42n);
        assert.equal(guest.view().getUint16(776,true),0);assert.equal(guest.read(778,1)[0],0);
      }
    });
  });

  test(`${runtime}: filesystem creation, positional IO, metadata, renumbering, links and removal match native`,async()=>{
    await pair(create,async({native,wiw,roots})=>{
      const errno=[];
      for(const guest of [native,wiw]) {
        const call=(name,...args)=>{const result=guest.call(name,...args);errno.push(result);assert.equal(result,0,name);};
        guest.write(2100,text('new'));guest.write(2110,text('renamed'));guest.write(2130,text('link'));guest.write(2140,text('sym'));guest.write(2150,text('dir'));
        call('path_create_directory',3,2150,3);
        call('path_open',3,0,2100,3,1,0x600077n,0n,0,0);const fd=guest.view().getUint32(0,true);
        guest.write(200,text('hello'));
        const iov=new Uint8Array(8),view=new DataView(iov.buffer);view.setUint32(0,200,true);view.setUint32(4,5,true);guest.write(16,iov);
        call('fd_write',fd,16,1,24);assert.equal(guest.view().getUint32(24,true),5);
        call('fd_pwrite',fd,16,1,2n,24);call('fd_tell',fd,32);assert.equal(guest.view().getBigUint64(32,true),5n);
        call('fd_filestat_get',fd,64);assert.equal(guest.view().getBigUint64(96,true),7n);
        call('fd_filestat_set_size',fd,6n);call('fd_fdstat_get',fd,64);
        call('fd_sync',fd);call('fd_datasync',fd);
        view.setUint32(0,256,true);view.setUint32(4,6,true);guest.write(16,iov);
        call('fd_pread',fd,16,1,0n,24);assert.deepEqual(guest.read(256,6),text('hehell'));
        call('path_open',3,0,2100,3,0,0x600077n,0n,0,4);const other=guest.view().getUint32(4,true);
        call('fd_renumber',fd,other);call('fd_close',other);
        call('path_rename',3,2100,3,3,2110,7);
        call('path_link',3,0,2110,7,3,2130,4);
        call('path_symlink',2110,7,3,2140,3);
        call('path_readlink',3,2140,3,256,32,24);assert.equal(guest.view().getUint32(24,true),7);
        assert.deepEqual(guest.read(256,7),text('renamed'));
        call('path_filestat_get',3,0,2110,7,64);assert.equal(guest.view().getBigUint64(96,true),6n);
        const entries=guest.call('fd_readdir',3,1024,1024,0n,24);assert.equal(entries,0);
        assert.ok(guest.view().getUint32(24,true)>0);
        call('path_unlink_file',3,2130,4);call('path_unlink_file',3,2140,3);
        call('path_unlink_file',3,2110,7);call('path_remove_directory',3,2150,3);
      }
      assert.deepEqual(await readFile(join(roots[0],'input')),await readFile(join(roots[1],'input')));
      assert.deepEqual(await readdir(roots[0]),await readdir(roots[1]));
      assert.deepEqual(errno.slice(0,errno.length/2),errno.slice(errno.length/2));
    });
  });

  test(`${runtime}: close releases guest-opened and renumbered descriptors without closing borrowed output`,async()=>{
    await pair(create,async({wiw,host,roots})=>{
      wiw.write(100,text('input'));
      assert.equal(wiw.call('path_open',3,0,100,5,0,102n,0n,0,0),0);
      const fd=wiw.view().getUint32(0,true);
      assert.equal(wiw.call('path_open',3,0,100,5,0,102n,0n,0,4),0);
      const target=wiw.view().getUint32(4,true);assert.equal(wiw.call('fd_renumber',fd,target),0);
      // Linux exposes real descriptor targets; the portable assertions below also cover other hosts.
      const opened=[];
      if(fs.existsSync('/proc/self/fd'))for(const name of await readdir('/proc/self/fd')) {
        try{if(await readlink(`/proc/self/fd/${name}`)===join(roots[1],'input'))opened.push(Number(name));}catch{}
      }
      host.close();host.close();assert.throws(()=>host.invoke('fd_close',target),/closed/);
      for(const actual of opened)assert.throws(()=>fs.fstatSync(actual),{code:'EBADF'});
      assert.ok(fs.fstatSync(1));
    });
  });
}

for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: signed seek offsets and unsigned i64 rights/offsets preserve native wire values`,async()=>{
    await pair(create,({native,wiw})=>{
      const results=[];
      for(const guest of [native,wiw]) {
        guest.write(2100,text('input'));
        assert.equal(guest.call('path_open',3,0,2100,5,0,0xe001ffn,0n,0,0),0);
        const fd=guest.view().getUint32(0,true);
        const iov=new Uint8Array(8),view=new DataView(iov.buffer);view.setUint32(0,256,true);view.setUint32(4,1,true);guest.write(16,iov);
        const output=[];
        for(const offset of [-1n,1n<<63n])output.push(guest.call('fd_pread',fd,16,1,offset,24));
        output.push(guest.call('fd_fdstat_set_rights',fd,-1n,0n));
        assert.equal(guest.call('fd_seek',fd,-1n,2,32),0);assert.equal(guest.view().getBigUint64(32,true),5n);
        output.push(guest.call('fd_advise',fd,0n,1n,0));output.push(guest.call('fd_allocate',fd,0n,1n));
        assert.equal(guest.call('fd_filestat_set_times',fd,123000000000n,234000000000n,5),0);
        assert.equal(guest.call('fd_filestat_get',fd,64),0);assert.equal(guest.view().getBigUint64(112,true),234000000000n);
        assert.equal(guest.call('path_filestat_set_times',3,0,2100,5,123000000000n,234000000000n,5),0);
        assert.equal(guest.call('fd_fdstat_set_flags',fd,0),0);
        assert.equal(guest.call('fd_fdstat_set_rights',fd,102n,0n),0);
        assert.equal(guest.call('fd_fdstat_get',fd,64),0);assert.equal(guest.view().getBigUint64(72,true),102n);
        assert.equal(guest.call('fd_close',fd),0);results.push(output);
      }
      assert.deepEqual(results[1],results[0]);
    });
  });
}
