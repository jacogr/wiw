import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createBootstrapInterpreter,createInterpreter} from '../wiw.js';

const binary=new URL('../build/wiw-opt.wasm',import.meta.url);
const annotations=[
  '(@note "(; string ;)" (; comment ;) (nested))',
  '(@note "")',
  '(@note "(" (nested "λ") ";)")',
  String.raw`(@note "\28\3b" (nested "\u{1f600}") "\22")`,
  '(@note "before" ;; ignored )\n (nested) "after")',
  '(@"quoted name" "payload" (nested))'
];
for(const [runtime,create] of [['bootstrap',createBootstrapInterpreter],['interpreted',createInterpreter]]) {
  test(`${runtime}: annotation strings preserve following syntax and never join data segments`,async()=>{
    const directory=await mkdtemp(join(tmpdir(),'wiw-annotations-'));
    try {
      const engine=await create(binary);
      for(const annotation of annotations) {
        const source=`(module ${annotation}
          (memory (export "memory") 1)
          (data (i32.const 0) "A" ${annotation} "B")
          (func (export "run") (result i32) ${annotation} i32.const 42)
          ${annotation}) ${annotation}`;
        const wat=join(directory,'guest.wat'),wasm=join(directory,'guest.wasm');
        await writeFile(wat,source);
        // Native compilation is an independent oracle; guests still run through wiw's text/binary loaders.
        execFileSync('wat2wasm',['--enable-annotations',wat,'-o',wasm]);
        const bytes=await readFile(wasm),native=(await WebAssembly.instantiate(bytes)).instance.exports;
        for(const encoded of [false,true]) {
          if(encoded) engine.loadBinary(bytes); else engine.load(source);
          assert.equal(engine.invoke('run'),native.run(),annotation);
          assert.deepEqual(engine.readMemory(0,4),new Uint8Array(native.memory.buffer,0,4),annotation);
        }
      }
      // A malformed payload must keep its string offset and leave a subsequent valid load usable.
      for(const payload of [String.raw`"\q"`,String.raw`"\u{d800}"`,'"unfinished']) {
        const source=`(module (@note ${payload}))`;
        assert.throws(()=>engine.load(source),new RegExp(`syntax at byte ${source.indexOf('"')+1}$`));
        engine.load('(module (@note "" (nested)) (func (export "run") (result i32) i32.const 42))');
        assert.equal(engine.invoke('run'),42);
      }
    } finally {await rm(directory,{recursive:true,force:true});}
  });
}
