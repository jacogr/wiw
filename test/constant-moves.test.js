import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {runtimeFactories} from './runtime.js';

const fields=[
  ['i32','i32','',['0','-1','-2147483648','2147483647','0x80000001']],
  ['i64','i64','',['0','-1','-9223372036854775808','9223372036854775807','0xfedcba9876543210']],
  ['f32','i32','i32.reinterpret_f32',['0','-0','1.5','inf','-inf','nan:0x412345','nan:0x12345','-nan:0x12345']],
  ['f64','i64','i64.reinterpret_f64',['0','-0','1.5','inf','-inf','nan:0x8000000002345','nan:0x2345','-nan:0x2345']]
];
for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: scalar constant assignments preserve complete integer and float encodings through text and binary`,async()=>{
    const directory=await mkdtemp(join(tmpdir(),'wiw-constant-moves-')),engine=await create();
    try {
      const cases=[];
      for(const [type,result,cast,values] of fields) for(const kind of ['set','tee']) for(const literal of values) {
        const name=`f${cases.length}`,move=kind==='set'?'local.set $a local.get $a':'local.tee $a';
        cases.push({name,body:`(func (export "${name}") (result ${result} ${result}) (local $a ${type})
          ${type}.const ${literal} ${move} ${cast} local.get $a ${cast})`});
      }
      const source=`(module ${cases.map(c=>c.body).join('\n')})`,wat=join(directory,'guest.wat'),wasm=join(directory,'guest.wasm');
      await writeFile(wat,source);execFileSync('wat2wasm',[wat,'-o',wasm]);const bytes=await readFile(wasm),{instance}=await WebAssembly.instantiate(bytes);
      for(const format of ['text','binary']) {
        if(format==='text')engine.load(source);else engine.loadBinary(bytes);
        for(const {name} of cases) assert.deepEqual(engine.invoke(name),instance.exports[name](),`${format}/${name}`);
      }
      assert.throws(()=>engine.load('(module (func (local f64) i32.const 42 local.set 0))'),/operand stack/);
      // Constants at a function end must not inspect a following function's records.
      engine.load('(module (func (export "last") (result i32) i32.const 42) (func (param i32) local.get 0 drop))');
      assert.equal(engine.invoke('last'),42);
    } finally {await rm(directory,{recursive:true,force:true});}
  });

  test(`${runtime}: constant assignments preserve fuel, capacity, caller vectors and callback recovery`,async()=>{
    const engine=await create();
    for(const [type,result,cast] of fields) for(const kind of ['set','tee']) {
      const instructions=[`${type}.const 42`,`local.${kind} $a`,...(kind==='set'?['local.get $a']:[]),...(cast?[cast]:[])];
      const source=`(module (func (export "run") (result ${result}) (local $a ${type}) ${instructions.join(' ')}))`;
      engine.load(source);
      for(let fuel=0;fuel<instructions.length;fuel++) {
        engine.setFuel(fuel);assert.throws(()=>engine.invoke('run'),new RegExp(`exhausted fuel at byte ${source.indexOf(instructions[fuel])}$`));
        engine.setFuel(instructions.length);
        const value=engine.invoke('run');assert.equal(value,type==='i32'?42:type==='i64'?42n:type==='f32'?1109917696:4631107791820423168n);
      }
    }
    engine.setFuel(100000);
    for(const type of ['i32','i64']) for(const kind of ['set','tee']) for(const padding of [4095,4096]) {
      const source=`(module (func $calculate ${padding===4095?'(result i32)':''} (local ${type})
          ${type}.const 42 local.${kind} 0 ${kind==='set'?'local.get 0':''} ${type==='i64'?'i32.wrap_i64':''} ${padding===4096?'drop':''})
        (func (export "run") (result i32) ${'i32.const 1 '.repeat(padding)} call $calculate ${'i32.add '.repeat(padding===4096?padding-1:padding)}))`;
      engine.load(source);
      if(padding===4095)assert.equal(engine.invoke('run'),4137);
      else assert.throws(()=>engine.invoke('run'),new RegExp(`resource limit at byte ${source.indexOf(type+'.const 42')}$`));
    }
    engine.load(`(module (func $calculate (result i32) (local i32) i32.const 42 local.tee 0)
      (func (export "run") (param v128) (result v128)
        local.get 0 call $calculate i32.const 42 i32.ne if unreachable end))`);
    const vector=0xfedcba98765432100123456789abcdefn;assert.equal(engine.invoke('run',vector),vector);
    let fail=false;
    engine.load(`(module (import "env" "sink" (func $sink (param i32)))
      (func (export "run") (result i32) (local i32) i32.const 42 local.tee 0 call $sink local.get 0))`,
      {env:{sink:value=>{assert.equal(value,42);if(fail)throw new Error('sink failed');}}});
    assert.equal(engine.invoke('run'),42);fail=true;assert.throws(()=>engine.invoke('run'),/host import/);
    fail=false;assert.equal(engine.invoke('run'),42);
  });
}
