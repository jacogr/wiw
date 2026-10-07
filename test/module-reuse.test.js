import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import {createBootstrapInterpreter,createInterpreter} from '../wiw.js';

// Sharing compiled bootstrap code must never share interpreter or guest state.
for (const [name,create] of [['bootstrap',createBootstrapInterpreter],['interpreted',createInterpreter]]) {
  test(`${name}: compiled module creates isolated concurrent instances`,async()=>{
    const module=await WebAssembly.compile(await readFile(new URL('../build/wiw-opt.wasm',import.meta.url)));
    const [left,right]=await Promise.all([create(module),create(module)]);
    const source=`(module (memory (export "m") 1 3)
      (global (export "g") (mut i32) (i32.const 41))
      (func (export "run") (result i32) global.get 0)
      (func (export "spin") loop br 0 end))`;
    left.load(source);right.load(source);
    left.setGlobal('g',7);left.writeMemory(0,Uint8Array.of(99));
    assert.equal(left.growMemory(1),1);
    assert.equal(right.getGlobal('g'),41);assert.equal(right.readMemory(0,1)[0],0);
    assert.throws(()=>right.readMemory(65536,1));
    left.setFuel(5);assert.throws(()=>left.invoke('spin'),/exhausted fuel/);
    assert.equal(right.invoke('run'),41);
    const exported=left.exportFunction('run');
    right.load('(module (func (export "run") (result i32) i32.const 42))');
    assert.equal(exported(),7);assert.equal(right.invoke('run'),42);
    assert.throws(()=>right.load('(module (func (result i64) i32.const 1))'),/operand stack/);
    assert.equal(left.getGlobal('g'),7);assert.equal(left.readMemory(0,1)[0],99);
    const fresh=await create(module);fresh.load(source);
    assert.equal(fresh.invoke('run'),41);assert.equal(fresh.readMemory(0,1)[0],0);
  });
}
