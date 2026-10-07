import {runtimeNames} from './runtime.js';
import assert from 'node:assert/strict';
import {after,before,test} from 'node:test';
import {mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {createBootstrapInterpreter} from './runtime.js';

let directory,source,binary,names;
before(async () => {
  directory=await mkdtemp(join(tmpdir(),'wiw-mnemonics-'));
  const engine=await readFile(new URL('../build/wiw.wat',import.meta.url),'utf8');
  const end=engine.lastIndexOf(')');
  source=engine.slice(0,end)+`
    ;; Probe the engine's own matcher with an exact token ending at linear memory's boundary.
    (func (export "lookup") (param $p i32) (param $n i32) (result i32)
      (global.set $tok (local.get $p))
      (global.set $len (local.get $n))
      (call $opcode))
  `+engine.slice(end);
  const wat=join(directory,'probe.wat');
  binary=join(directory,'probe-opt.wasm');
  await writeFile(wat,source);
  execFileSync('wat2wasm',[wat,'-o',binary]);
  execFileSync('wasm-opt',['--enable-bulk-memory','--enable-sign-ext','--enable-nontrapping-float-to-int','-O4','--converge','--strip-debug','--strip-producers',binary,'-o',binary]);
  names=(await readFile(new URL('../scripts/opcodes.tsv',import.meta.url),'utf8'))
    .split('\n').filter(line => line && !line.startsWith('#'))
    .map(line => {const [id,name]=line.split(/\s+/);return [Number(id),name];});
});
after(async () => {if (directory) await rm(directory,{recursive:true,force:true});});

for (const runtime of runtimeNames) {
  test(`${runtime}: all mnemonic families reject altered lengths, case and every suffix byte at memory end`,async () => {
    let lookup;
    if (runtime==='bootstrap') {
      const {instance}=await WebAssembly.instantiate(await readFile(binary));
      lookup=text => {
        const bytes=Buffer.from(text);
        const pointer=instance.exports.memory.buffer.byteLength-bytes.length;
        new Uint8Array(instance.exports.memory.buffer).set(bytes,pointer);
        return instance.exports.lookup(pointer,bytes.length);
      };
    } else {
      const parent=await createBootstrapInterpreter(new URL('../build/wiw-opt.wasm',import.meta.url));
      parent.load(source);
      parent.setFuel(10000000);
      lookup=text => {
        const bytes=Buffer.from(text);
        const pointer=65536-bytes.length;
        parent.writeMemory(pointer,bytes);
        return parent.invoke('lookup',pointer,bytes.length);
      };
    }
    assert.equal(lookup(''),0);
    for (const [id,name] of names) {
      assert.equal(lookup(name),id,name);
      assert.equal(lookup(name+'x'),0,name+'x');
      assert.equal(lookup(name.toUpperCase()),0,name.toUpperCase());
      for (let index=0;index<name.length;index++) {
        const altered=name.slice(0,index)+'#'+name.slice(index+1);
        assert.equal(lookup(altered),0,altered);
      }
      assert.equal(lookup(name),id,`${name} after rejected tokens`);
    }
  });
}
