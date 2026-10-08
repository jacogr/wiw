import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {runtimeFactories} from './runtime.js';

// Float results are reinterpreted so payloads and signed zero remain observable as raw bits.
const loads=[
  ['i32.load',4,'i32','',b=>b.readInt32LE()],
  ['i32.load8_s',1,'i32','',b=>b.readInt8()],
  ['i32.load8_u',1,'i32','',b=>b.readUInt8()],
  ['i32.load16_s',2,'i32','',b=>b.readInt16LE()],
  ['i32.load16_u',2,'i32','',b=>b.readUInt16LE()],
  ['i64.load',8,'i64','',b=>b.readBigInt64LE()],
  ['i64.load8_s',1,'i64','',b=>BigInt(b.readInt8())],
  ['i64.load8_u',1,'i64','',b=>BigInt(b.readUInt8())],
  ['i64.load16_s',2,'i64','',b=>BigInt(b.readInt16LE())],
  ['i64.load16_u',2,'i64','',b=>BigInt(b.readUInt16LE())],
  ['i64.load32_s',4,'i64','',b=>BigInt(b.readInt32LE())],
  ['i64.load32_u',4,'i64','',b=>BigInt(b.readUInt32LE())],
  ['f32.load',4,'i32','i32.reinterpret_f32',b=>b.readInt32LE()],
  ['f64.load',8,'i64','i64.reinterpret_f64',b=>b.readBigInt64LE()]
];
const bytes=Buffer.from([0x45,0x23,0xc1,0xff,0xef,0xcd,0xab,0xff]);
const wideBytes=Buffer.from([0x80,0xff,0xc0,0x7f,0,0,0xf8,0x7f]);
const escaped=b=>[...b].map(n=>`\\${n.toString(16).padStart(2,'0')}`).join('');

for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: local-address scalar loads preserve raw bits, memory selection and bounds`,async()=>{
    const engine=await create(),directory=await mkdtemp(join(tmpdir(),'wiw-local-load-'));
    const source=`(module (memory $narrow 1) (memory $wide i64 1)
      (data (memory $narrow) (i32.const 3) "${escaped(bytes)}")
      (data (memory $wide) (i64.const 3) "${escaped(wideBytes)}")
      ${loads.flatMap(([op,,type,cast],index)=>['narrow','wide'].map(memory=>`
        (func (export "${memory}${index}") (param ${memory==='wide'?'i64':'i32'}) (result ${type})
          local.get 0 ${op} $${memory} offset=1 align=1 ${cast})`)).join('')})`;
    try {
      const wat=join(directory,'guest.wat'),wasm=join(directory,'guest.wasm');
      await writeFile(wat,source);execFileSync('wat2wasm',['--enable-all',wat,'-o',wasm]);
      for(const format of ['text','binary']) {
        if(format==='text')engine.load(source);else engine.loadBinary(await readFile(wasm));
        for(const [index,[,width,type,,value]] of loads.entries()) for(const memory of ['narrow','wide']) {
          const name=`${memory}${index}`,address=n=>memory==='wide'?BigInt(n):n;
          assert.equal(engine.invoke(name,address(2)),value(memory==='wide'?wideBytes:bytes),`${format}/${name}`);
          assert.equal(engine.invoke(name,address(65536-width-1)),type==='i64'?0n:0,'last complete access fits');
          assert.throws(()=>engine.invoke(name,address(65536-width)),/memory out of bounds/);
          assert.throws(()=>engine.invoke(name,address(-1)),/memory out of bounds/);
          if(memory==='wide')assert.throws(()=>engine.invoke(name,0x100000002n),/memory out of bounds/);
          assert.equal(engine.invoke(name,address(2)),value(memory==='wide'?wideBytes:bytes),'a trapped access does not corrupt memory selection');
        }
      }
      // Repeated reloads must replace cached load markers and resolve the new adjacent opcode.
      engine.load('(module (func (export "run") (param i32) (result i32) local.get 0 i32.const 1 i32.add))');
      assert.equal(engine.invoke('run',41),42);
      engine.load('(module (memory 1) (func (export "run") (param i32) (result i32) local.get 0 nop i32.load))');
      assert.equal(engine.invoke('run',0),0,'a non-adjacent load uses ordinary execution');
    }finally {await rm(directory,{recursive:true,force:true});}
  });

  test(`${runtime}: local-address load fusion retains source, fuel and temporary operand limits`,async()=>{
    const engine=await create();
    const source='(module (memory 1) (func (export "run") (param i32) (result i32) local.get 0 i32.load offset=1 i32.const 42 i32.add))';
    engine.load(source);
    const positions=['local.get 0','i32.load','i32.const 42','i32.add'].map(op=>source.indexOf(op));
    for(let fuel=0;fuel<4;fuel++) {
      engine.setFuel64(BigInt(fuel));
      assert.throws(()=>engine.invoke('run',0),new RegExp(`exhausted fuel at byte ${positions[fuel]}$`));
    }
    engine.setFuel64(4n);assert.equal(engine.invoke('run',0),42);
    engine.setFuel64(1n);
    assert.throws(()=>engine.invoke('run',65535),new RegExp(`exhausted fuel at byte ${positions[1]}$`));
    engine.setFuel64(2n);
    assert.throws(()=>engine.invoke('run',65535),new RegExp(`memory out of bounds at byte ${positions[1]}$`));
    engine.setFuel64(100000n);
    for(const count of [4094,4095]) {
      const full=`(module (memory 1)
        (func $load (local i32) local.get 0 i32.load drop)
        (func (export "run") (result v128)
        v128.const i64x2 123456 -654321 ${'i32.const 0 '.repeat(count)}
        call $load ${'drop '.repeat(count)}))`;
      engine.load(full);
      if(count===4094)assert.equal(engine.invoke('run'),123456n|(BigInt.asUintN(64,-654321n)<<64n));
      else assert.throws(()=>engine.invoke('run'),new RegExp(`resource limit at byte ${full.indexOf('local.get 0')}$`));
    }
  });
}
