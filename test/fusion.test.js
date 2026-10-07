import {runtimeFactories} from './runtime.js';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';

const operations=['add','sub','mul','and','or','xor','shl','shr_s','shr_u','rotl','rotr',
  'eq','ne','lt_s','lt_u','gt_s','gt_u','le_s','le_u','ge_s','ge_u'];
for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: adjacent integer sequences match native wrapping, shifts and comparisons`,async()=>{
    const directory=await mkdtemp(join(tmpdir(),'wiw-fusion-'));
    try {
      const cases=[];
      for(const type of ['i32','i64']) for(const operation of operations) for(const literal of ['1','-1',type==='i32'?'0x80000001':'0xfedcba9876543210']) {
        const result=operations.indexOf(operation)>=11?'i32':type;
        const name=`f${cases.length}`;
        cases.push({type,result,name,body:`(func (export "${name}") (param ${type}) (result ${result}) (local ${result})
          local.get 0 ${type}.const ${literal} ${type}.${operation} local.set 1 local.get 1)`});
      }
      const source=`(module ${cases.map(item=>item.body).join('\n')})`;
      const wat=join(directory,'guest.wat'),wasm=join(directory,'guest.wasm');
      await writeFile(wat,source);execFileSync('wat2wasm',[wat,'-o',wasm]);
      const {instance}=await WebAssembly.instantiate(await readFile(wasm));
      const engine=await create();engine.load(source);
      for(const {type,name} of cases) for(const value of type==='i32'?[-2147483648,-1,0,2147483647]:[-(1n<<63n),-1n,0n,(1n<<63n)-1n]) {
        assert.equal(engine.invoke(name,value),instance.exports[name](value),`${name}/${value}`);
      }
    } finally {await rm(directory,{recursive:true,force:true});}
  });

  test(`${runtime}: each sequence instruction retains exact fuel and recovery boundaries`,async()=>{
    const engine=await create();
    for(const [sequence,expected] of [
      [['local.get 0','i32.const 2','i32.add','local.set 0','local.get 0'],42],
      [['local.get 0','i32.const 2','i32.add','i32.const 3','i32.mul','local.set 0','local.get 0'],126],
      [['local.get 0','i32.const 2','i32.div_s'],20]
    ]) {
      const source=`(module (func (export "run") (param i32) (result i32) ${sequence.join(' ')}))`;
      engine.load(source);
      for(let fuel=0;fuel<sequence.length;fuel++) {
        engine.setFuel(fuel);
        const instruction=sequence[fuel];
        const at=fuel===sequence.length-1&&instruction==='local.get 0'?source.lastIndexOf(instruction):source.indexOf(instruction);
        assert.throws(()=>engine.invoke('run',40),new RegExp(`exhausted fuel at byte ${at}$`));
        engine.setFuel(sequence.length);assert.equal(engine.invoke('run',40),expected);
      }
    }
    let fail=false;
    const imported='(module (import "env" "step" (func $step (param i32) (result i32))) (func (export "run") (param i32) (result i32) local.get 0 i32.const 2 i32.add call $step i32.const 1 i32.add))';
    engine.load(imported,{env:{step:value=>{if(fail)throw new Error('step failed');return value+1;}}});
    const offsets=['local.get 0','i32.const 2','i32.add','call $step','i32.const 1','i32.add'];
    for(let fuel=0;fuel<offsets.length;fuel++) {
      engine.setFuel(fuel);
      const at=fuel===5?imported.lastIndexOf('i32.add'):imported.indexOf(offsets[fuel]);
      assert.throws(()=>engine.invoke('run',40),new RegExp(`exhausted fuel at byte ${at}$`));
      engine.setFuel(6);assert.equal(engine.invoke('run',40),44);
    }
    fail=true;assert.throws(()=>engine.invoke('run',40),/host import/);
    fail=false;assert.equal(engine.invoke('run',40),44);
    engine.setFuel(100);
    engine.load('(module (func (export "run") (param i32) (result i32) local.get 0 i32.const 0 i32.div_s))');
    assert.throws(()=>engine.invoke('run',40),/divide by zero/);
  });

  test(`${runtime}: sequences retain caller vectors, branches and temporary operand limits`,async()=>{
    const engine=await create();engine.setFuel(100000);
    const vector={type:'v128',bits:0xfedcba98765432100123456789abcdefn};
    engine.load(`(module
      (func $increment (param i32) (result i32) local.get 0 i32.const 2 i32.add local.set 0 local.get 0)
      (func (export "run") (param v128 i32) (result v128 i32)
        local.get 0 (block (result i32) local.get 1 call $increment br 0)))`);
    assert.deepEqual(engine.invokeRaw('run',vector,{type:'i32',bits:40n}),[vector,{type:'i32',bits:42n}]);
    // The callee validates with a small stack, but its caller's live operands leave two, one or zero slots.
    for(const padding of [4094,4095]) {
      const source=`(module
        (func $calculate (param i32) (result i32) local.get 0 i32.const 2 i32.add)
        (func (export "run") (result i32)
          ${'i32.const 1 '.repeat(padding)} i32.const 40 call $calculate ${'i32.add '.repeat(padding)}))`;
      engine.load(source);
      if(padding===4094) assert.equal(engine.invoke('run'),4136);
      else assert.throws(()=>engine.invoke('run'),new RegExp(`resource limit at byte ${source.indexOf('i32.const 2')}$`));
    }
    const full=`(module
      (func $calculate (result i32) (local i32) local.get 0 i32.const 2 i32.add)
      (func $padding (result i32) i32.const 1 call $calculate i32.add)
      (func (export "run") (result i32)
        ${'i32.const 1 '.repeat(4095)} call $padding ${'i32.add '.repeat(4095)}))`;
    engine.load(full);
    assert.throws(()=>engine.invoke('run'),new RegExp(`resource limit at byte ${full.indexOf('local.get 0')}$`));
    engine.load(`(module
      (func $calculate (param i32) (result i32) local.get 0 i32.const 2 i32.add)
      (func (export "run") (result i32)
        ${'i32.const 1 '.repeat(4093)} i32.const 40 call $calculate ${'i32.add '.repeat(4093)}))`);
    assert.equal(engine.invoke('run'),4135);
  });
}
