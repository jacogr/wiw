import {runtimeNames} from './runtime.js';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import {createBootstrapInterpreter} from './runtime.js';

const binary=new URL('../build/wiw-opt.wasm',import.meta.url);
for(const runtime of runtimeNames) {
  test(`${runtime}: implicit signature interning retains earliest indices, exact collisions and recursive identity`,async()=>{
    let call,write;
    if(runtime==='bootstrap') {
      const {instance}=await WebAssembly.instantiate(await readFile(binary));
      call=(name,...args)=>instance.exports[name](...args);
      write=(bytes,at=4096)=>new Uint8Array(instance.exports.memory.buffer).set(bytes,at);
    } else {
      const parent=await createBootstrapInterpreter(binary);
      parent.load(await readFile(new URL('../build/wiw.wat',import.meta.url),'utf8'));
      parent.setFuel(10000000);
      call=(name,...args)=>parent.invoke(name,...args);
      write=(bytes,at=4096)=>parent.writeMemory(at,bytes);
    }
    const load=source=>{
      const bytes=Buffer.from(source);
      write(bytes);
      assert.equal(call('load',4096,bytes.length),0);
    };
    const heap=index=>call('type_heap',call('function_heap_type',index));
    const voidTypes='(type (func)) '.repeat(16);
    load(`(module ${'(type (func (param i32) (result i32))) '.repeat(32)}
      (func (param i32) (result i32) local.get 0))`);
    assert.equal(heap(0),0);
    load(`(module ${voidTypes}
      (func (param i32) (result i32) local.get 0)
      (func (param i32) (result i32) local.get 0)
      (func (param i64) (result i64) local.get 0))`);
    assert.equal(heap(0),16);assert.equal(heap(1),16);assert.equal(heap(2),17);
    // Reference signatures deliberately share a coarse hash but must remain structurally distinct.
    load(`(module ${'(type (func (param funcref) (result funcref))) '.repeat(16)}
      (func (param externref) (result externref) local.get 0)
      (func (param funcref) (result funcref) local.get 0))`);
    assert.equal(heap(0),16);assert.equal(heap(1),0);
    load(`(module ${voidTypes}
      (rec (type (func (param i32) (result i32))) (type (struct (field i32))))
      (func (param i32) (result i32) local.get 0))`);
    assert.equal(heap(0),18);
    load(`(module ${voidTypes}
      (type $base (sub (func (param i32) (result i32))))
      (type $child (sub $base (func (param i32) (result i32))))
      (func (param i32) (result i32) local.get 0))`);
    assert.equal(heap(0),18);
    // Different concrete reference IDs with equal heap declarations must reach the same candidate.
    load(`(module (type $a (struct (field i32))) (type $b (struct (field i32)))
      ${'(type (func)) '.repeat(14)}
      (type (func (param (ref null $a)) (result i32)))
      (func (param (ref null $b)) (result i32) i32.const 42))`);
    assert.equal(heap(0),16);
    // At capacity, equivalent concrete references must reuse rather than append a signature.
    load(`(module (type $a (struct (field i32))) (type $b (struct (field i32)))
      ${'(type (func)) '.repeat(765)}
      (type (func (param (ref null $a)) (result i32)))
      (func (param (ref null $b)) (result i32) i32.const 42))`);
    assert.equal(heap(0),767);
    // Matching the first declaration at capacity must not attempt to append a new type.
    const full=`(module ${'(type (func (param i32) (result i32))) '.repeat(768)}
      (func (param i32) (result i32) local.get 0))`;
    load(full);
    assert.equal(heap(0),0);
    // Keep the arena base identical while float parsing reuses the previous bucket scratch.
    const float='(module (func (export "run") (result f64) f64.const 1e-300))';
    load(float+' '.repeat(full.length-float.length));
    assert.equal(call('initialize'),0);
    call('set_fuel',1000);
    const bits=new DataView(new ArrayBuffer(8));bits.setFloat64(0,1e-300,true);
    assert.equal(call('invoke64',4096+float.indexOf('run'),3,0,0),bits.getBigInt64(0,true));
    // Trusted foreign result installation invalidates both the derived reference and retained index.
    load('(module (type (func (result i32))) (type (func (result i64))) (func (result i32) i32.const 42))');
    assert.equal(heap(0),0);
    write(Uint8Array.of(2,0,0,0),61440);
    assert.equal(call('foreign_results',0,61440,1),0);
    assert.equal(heap(0),1);
    load('(module (func (param f64) (result f64) local.get 0))');
    assert.equal(heap(0),0);assert.equal(call('heap_param_type',0,0),4);
  });
}
