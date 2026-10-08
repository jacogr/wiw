import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {runtimeFactories} from './runtime.js';

for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: taken parameter guards retain exact fuel, false bodies, mixed arguments and reloads`,async()=>{
    const directory=await mkdtemp(join(tmpdir(),'wiw-guard-return-')),engine=await create();
    const source=`(module
      (type $t (func (param v128 i32 v128 i64)))
      (global $seen (export "seen") (mut i64) (i64.const 0))
      (func $guard (type $t) (local v128 i64)
        local.get 1 if return end
        local.get 4 v128.any_true if unreachable end
        local.get 5 i64.eqz i32.eqz if unreachable end
        local.get 3 global.set $seen)
      (table 1 funcref) (elem (i32.const 0) $guard)
      (func (export "direct") (param v128 i32 i64) (result v128)
        local.get 0 local.get 0 local.get 1 local.get 0 local.get 2 call $guard)
      (func (export "indirect") (param v128 i32 i64) (result v128)
        local.get 0 local.get 0 local.get 1 local.get 0 local.get 2 i32.const 0 call_indirect (type $t))
      (func (export "reference") (param v128 i32 i64) (result v128)
        local.get 0 local.get 0 local.get 1 local.get 0 local.get 2 ref.func $guard call_ref $t)
      (func (export "tail") (param v128 i32 i64)
        local.get 0 local.get 1 local.get 0 local.get 2 return_call $guard))`;
    try {
      const wat=join(directory,'guest.wat'),wasm=join(directory,'guest.wasm');
      await writeFile(wat,source);execFileSync('wat2wasm',['--enable-all',wat,'-o',wasm]);
      for(const format of ['text','binary']) {
        if(format==='text')engine.load(source);else engine.loadBinary(await readFile(wasm));
        engine.setFuel64(100000n);
        for(const name of ['direct','indirect','reference']) for(const condition of [1,-1,-2147483648,0,1,0]) {
          const bits=0xfedcba98765432100123456789abcdefn;
          engine.setGlobal('seen',-1n);
          assert.equal(engine.invoke(name,bits,condition,123456789012345n),bits,`${format}/${name}/${condition}`);
          assert.equal(engine.getGlobal('seen'),condition===0?123456789012345n:-1n);
        }
        for(const condition of [1,0]) {
          engine.setGlobal('seen',-1n);assert.equal(engine.invoke('tail',0n,condition,42n),undefined);
          assert.equal(engine.getGlobal('seen'),condition===0?42n:-1n);
        }
      }
      const fuelSource=`(module
        (func $guard (param $condition i32) (local i64 v128) local.get $condition if return end)
        (func (export "run") (result i32) i32.const 1 call $guard i32.const 42))`;
      engine.load(fuelSource);
      const offsets=[fuelSource.indexOf('i32.const 1'),fuelSource.indexOf('call $guard'),
        fuelSource.indexOf('local.get $condition'),fuelSource.indexOf('if return'),fuelSource.indexOf('return end'),fuelSource.indexOf('i32.const 42')];
      for(let fuel=0;fuel<6;fuel++) {
        engine.setFuel64(BigInt(fuel));
        assert.throws(()=>engine.invoke('run'),new RegExp(`exhausted fuel at byte ${offsets[fuel]}$`));
      }
      engine.setFuel64(6n);assert.equal(engine.invoke('run'),42);
      engine.setFuel64(100000n);
      // Same function index and source length must not retain a marker for a different body.
      engine.load('(module (global (export "seen") (mut i32) (i32.const 0)) (func $g (param i32) i32.const 42 global.set 0) (func (export "run") i32.const 1 call $g))');
      engine.invoke('run');assert.equal(engine.getGlobal('seen'),42);
      let calls=0;
      engine.load('(module (import "host" "g" (func $g (param i32))) (func (export "run") i32.const 1 call $g))',{host:{g:()=>{calls++;}}});
      engine.invoke('run');assert.equal(calls,1);
      engine.load('(module (global (export "seen") (mut i32) (i32.const 0)) (func $g (param i32) local.get 0 i32.eqz if return end i32.const 42 global.set 0) (func (export "run") i32.const 1 call $g))');
      engine.invoke('run');assert.equal(engine.getGlobal('seen'),42,'a different predicate retains normal dispatch');
    }finally {await rm(directory,{recursive:true,force:true});}
  });

  test(`${runtime}: guarded returns retain frame, label and full-operand capacity boundaries`,async()=>{
    const engine=await create();engine.setFuel64(100000n);
    const guard='(func $guard (param i32) local.get 0 if return end)';
    const labels=`(module ${guard} (func $rec (export "run") (param i32)
      ${'block '.repeat(7)}local.get 0 if
        local.get 0 i32.const 1 i32.sub call $rec
      else i32.const 1 call $guard end ${'end '.repeat(7)}))`;
    engine.load(labels);
    assert.equal(engine.invoke('run',453),undefined);
    // 455 frames each hold an implicit root, seven blocks and one if: 4,095 labels.
    assert.throws(()=>engine.invoke('run',454),new RegExp(`resource limit at byte ${labels.indexOf('if return')}$`));
    assert.equal(engine.invoke('run',0),undefined);
    const recursive=`(module ${guard} (func $rec (export "run") (param i32)
      local.get 0 if local.get 0 i32.const 1 i32.sub call $rec else i32.const 1 call $guard end))`;
    engine.load(recursive);
    assert.equal(engine.invoke('run',510),undefined);
    assert.throws(()=>engine.invoke('run',511),new RegExp(`resource limit at byte ${recursive.indexOf('call $guard')}$`));
    assert.equal(engine.invoke('run',0),undefined,'resource failures preserve later calls');
    const full=`(module ${guard}
      (func (export "run") (result v128) v128.const i64x2 123 456 ${'i32.const 0 '.repeat(4094)}i32.const 1 call $guard ${'drop '.repeat(4094)}))`;
    engine.load(full);engine.setFuel64(100000n);
    assert.equal(engine.invoke('run'),123n|(456n<<64n),'the original parameter read fits after its argument is consumed');
  });
}
