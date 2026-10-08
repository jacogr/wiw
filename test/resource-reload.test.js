import assert from 'node:assert/strict';
import {test} from 'node:test';
import {runtimeFactories} from './runtime.js';

for(const [runtime,create] of runtimeFactories) test(`${runtime}: reused global/import records reset aliases, categories and raw high halves`,async()=>{
  const provider=await create(),consumer=await create();
  provider.load(`(module (memory (export "m") 1) (table (export "t") 1 funcref)
    (global (export "g") (mut i32) (i32.const 7)) (tag (export "e") (param i32)))`);
  const bindings=provider.exportNamespace();
  // Equal padded lengths keep all descriptor addresses unchanged across reload.
  const load=(source,imports={})=>consumer.load(source.padEnd(4096),imports);
  load(`(module (import "env" "g" (global $a (mut i32))) (import "env" "g" (global $b (mut i32)))
    (export "a" (global $a)) (export "b" (global $b)))`,{env:bindings});
  consumer.setGlobal('b',99);assert.equal(consumer.getGlobal('a'),99);assert.equal(provider.getGlobal('g'),99);
  load(`(module (global (export "a") (mut i32) (i32.const 42))
    (global (export "b") (mut i64) (i64.const 99))
    (global (export "v") (mut v128) (v128.const i64x2 1 0x8000000000000000)))`);
  assert.equal(consumer.getGlobal('a'),42);assert.equal(consumer.getGlobal('b'),99n);
  assert.equal(consumer.getGlobal('v'),(1n<<127n)|1n);
  consumer.setGlobal('b',123n);assert.equal(consumer.getGlobal('a'),42);
  for(const [name,type] of [['g','global (mut i32)'],['m','memory 1'],['t','table 1 funcref'],['e','tag (param i32)']]) {
    for(const inline of [false,true]) {
      load(`(module (import "env" "${name}" (${type})))`,{env:bindings});
      const imported=inline?'(func $f (import "env" "f") (param i64) (result i64))':
        '(import "env" "f" (func $f (param i64) (result i64)))';
      load(`(module ${imported} (func (export "run") (result i64) i64.const 41 call $f))`,{env:{f:x=>x+1n}});
      assert.equal(consumer.invoke('run'),42n,`${name}/${inline}`);
    }
  }
  load(`(module (import "env" "m" (memory $a 1)) (import "env" "m" (memory $b 1))
    (func (export "size") (result i32) memory.size $b))`,{env:bindings});
  assert.equal(consumer.invoke('size'),1);
  load(`(module (memory $a 1) (memory $b 2)
    (func (export "size") (result i32) memory.size $b)
    (func (export "peek") (result i32) i32.const 0 i32.load8_u $b))`);
  assert.equal(consumer.invoke('size'),2);consumer.writeMemory(0,Uint8Array.of(123));assert.equal(consumer.invoke('peek'),0);
  load('(module (func (export "run") (result i32) i32.const 0))');
  assert.equal(consumer.invoke('run'),0);assert.throws(()=>consumer.readMemory(0,1),/no guest memory/);
  load('(module (global (export "v") v128 (v128.const i64x2 0 0)))');
  assert.equal(consumer.getGlobal('v'),0n);
});
