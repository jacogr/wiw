import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {runtimeFactories,createTag} from './runtime.js';
const bytes=s=>new TextEncoder().encode(s);

async function binary(source) {
  const dir=await mkdtemp(join(tmpdir(),'wiw-arena-'));
  try {
    await writeFile(join(dir,'guest.wat'),source);
    execFileSync('wat2wasm',['--enable-gc',join(dir,'guest.wat'),'-o',join(dir,'guest.wasm')]);
    return await readFile(join(dir,'guest.wasm'));
  } finally {await rm(dir,{recursive:true,force:true});}
}

for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: enlarged instruction streams preserve text/binary results and reload layouts`,async()=>{
    const source=`(module (func (export "run") (result i32) ${'nop '.repeat(131073)} i32.const 42))`;
    const small=await create(); assert.throws(()=>small.load(source),/resource limit/);
    const i=await create(undefined,{limits:{instructions:140000}}); i.setFuel(200000);
    i.load(source); assert.equal(i.invoke('run'),42);
    i.loadBinary(await binary(source)); assert.equal(i.invoke('run'),42);
    i.load('(module (memory 1) (func (export "run") (result i32) i32.const 7))');
    i.writeMemory(0,bytes('safe')); assert.equal(i.invoke('run'),7);
    i.load(source); assert.equal(i.invoke('run'),42);
  });

  test(`${runtime}: expanded type names, heap fields and binary type maps retain concrete references`,async()=>{
    const types=Array.from({length:900},(_,n)=>`(type $S${n} (struct (field i32)))`).join('');
    const source=`(module ${types} (func (export "run") (result i32) i32.const 42 struct.new $S899 struct.get $S899 0))`;
    const small=await create(); assert.throws(()=>small.load(source),/resource limit/);
    const i=await create(undefined,{limits:{types:1024,fields:40000}});
    i.load(source); assert.equal(i.invoke('run'),42);
    const functionTypes=`(module ${Array.from({length:900},(_,n)=>`(type $T${n} (func (param i32)))`).join('')} (func (export "run") (result i32) i32.const 42))`;
    i.loadBinary(await binary(functionTypes)); assert.equal(i.invoke('run'),42);
    i.load(`(module (type $Wide (struct ${'(field i32) '.repeat(32769)}))
      (func (export "run") (result i32) struct.new_default $Wide struct.get $Wide 32768))`);
    assert.equal(i.invoke('run'),0); i.collectGarbage();
  });

  test(`${runtime}: expanded imports and tags preserve late bindings and tag identities`,async()=>{
    const source=`(module ${Array.from({length:1025},(_,n)=>`(import "h" "f" (func $f${n} (result i32)))`).join('')}
      (func (export "run") (result i32) call $f1024))`;
    const small=await create(); assert.throws(()=>small.load(source,{h:{f:()=>42}}),/resource limit/);
    const i=await create(undefined,{limits:{imports:1100,tags:300}});
    i.load(source,{h:{f:()=>42}}); assert.equal(i.invoke('run'),42);
    i.load(`(module ${Array.from({length:257},(_,n)=>`(tag $t${n} (export "t${n}"))`).join('')}
      (func (export "throw") throw $t256))`);
    const tag=i.getTag('t256'); assert.throws(()=>i.invoke('throw'),error=>error.is(tag));
    i.load('(module)'); assert.throws(()=>i.getTag(),/no guest tag/);
  });

  test(`${runtime}: wider table arenas, declarations and imported aliases preserve entries and growth`,async()=>{
    const i=await create(undefined,{limits:{tables:48,tableEntries:6000}});
    i.load(`(module ${'(table 0 funcref) '.repeat(32)}
      (table (export "t") i64 5000 6000 externref))`);
    const object={}; i.setTable(4999n,object,'t'); assert.equal(i.getTable(4999n,'t'),object);
    assert.equal(i.growTable(1000n,object,'t'),5000); assert.equal(i.tableSize('t'),6000);
    assert.equal(i.getTable(5999n,'t'),object); assert.equal(i.growTable(1n,object,'t'),-1);
    const consumer=await create(undefined,{limits:{tableEntries:6000}});
    consumer.load('(module (table (import "p" "t") i64 5000 6000 externref) (export "t" (table 0)))',{p:i.exportNamespace()});
    assert.equal(consumer.getTable(5999n,'t'),object); consumer.setTable(0n,42,'t'); assert.equal(i.getTable(0n,'t'),42);
  });

  test(`${runtime}: larger data pools and segment vectors initialize correctly from text and binary`,async()=>{
    const i=await create(undefined,{limits:{dataBytes:80000,dataSegments:160,elementSegments:160,elementEntries:5000,tableEntries:5000}});
    const source=`(module (memory 2) (table 1 funcref) (func $f)
      (data (i32.const 0) "${'A'.repeat(70000)}") ${'(data "") '.repeat(130)}
      ${'(elem func $f) '.repeat(129)})`;
    i.load(source); assert.deepEqual(i.readMemory(69990,10),bytes('AAAAAAAAAA'));
    i.loadBinary(await binary(source)); assert.deepEqual(i.readMemory(69990,10),bytes('AAAAAAAAAA'));
    i.load(`(module (table 4100 funcref) (func $f) (elem (i32.const 0) ${'$f '.repeat(4100)}))`);
    assert.equal(i.getTable(4099)(),undefined);
  });

  test(`${runtime}: large parameter/result vectors and named locals preserve numeric and vector high slots`,async()=>{
    const i=await create(undefined,{limits:{parameters:320,results:320,locals:2200}});
    const params=Array.from({length:300},(_,n)=>`(param $p${n} v128)`).join('');
    i.load(`(module (func (export "run") ${params} (result ${'v128 '.repeat(300)})
      ${Array.from({length:300},(_,n)=>`local.get $p${n} `).join('')}))`);
    const args=Array.from({length:300},(_,n)=>(BigInt(n+1)<<100n)|BigInt(n));
    assert.deepEqual(i.invoke('run',...args),args);
    assert.deepEqual(i.invokeRaw('run',...args.map(bits=>({type:'v128',bits}))),args.map(bits=>({type:'v128',bits})));
    i.load(`(module (func (export "run") (result i32) ${Array.from({length:2000},(_,n)=>`(local $x${n} i32)`).join('')}
      i32.const 42 local.set $x1999 local.get $x1999))`);
    assert.equal(i.invoke('run'),42);
    i.load('(module (func (export "run") (result i32) i32.const 7))'); assert.equal(i.invoke('run'),7);
  });

  test(`${runtime}: large guest exception payload maps retain managed roots above position 128`,async()=>{
    const i=await create(undefined,{limits:{parameters:320,results:320}});
    i.load(`(module (type $S (struct (field i32))) (tag $t (param ${'i64 '.repeat(299)} (ref $S)))
      (global $g (mut exnref) (ref.null exn))
      (func (export "capture")
        block $caught (result exnref) try_table (catch_all_ref $caught)
          ${'i64.const 1073741824 '.repeat(299)} i32.const 42 struct.new $S throw $t end unreachable end global.set $g)
      (func (export "check") (result i32) (local $result i32)
        block $caught (result ${'i64 '.repeat(299)} (ref $S))
          try_table (catch $t $caught) global.get $g throw_ref end unreachable end
        struct.get $S 0 local.set $result ${'drop '.repeat(299)} local.get $result))`);
    i.invoke('capture'); assert.equal(i.collectGarbage(),0); assert.equal(i.invoke('check'),42);
    const tag=createTag(new Array(300).fill('externref'));
    const object={}; let error;
    i.load(`(module (tag $t (import "h" "t") (param ${'externref '.repeat(300)}))
      (import "h" "throw" (func $throw))
      (func (export "run") (result ${'externref '.repeat(300)})
        block $caught (result ${'externref '.repeat(300)}) try_table (catch $t $caught) call $throw end unreachable end))`,
      {h:{t:tag,throw:()=>{throw error;}}});
    error=i.createException(tag,...new Array(300).fill(object));
    assert.deepEqual(i.invoke('run'),new Array(300).fill(object));
  });

  test(`${runtime}: larger live GC heaps retain objects and reject exhausted allocations cleanly`,async()=>{
    const i=await create(undefined,{limits:{gcHeapBytes:32*1024*1024}});
    i.load(`(module (type $A (array i32))
      (func (export "new") (result (ref $A)) i32.const 1100000 array.new_default $A)
      (func (export "len") (param (ref $A)) (result i32) local.get 0 array.len))`);
    const object=i.invoke('new'); assert.equal(i.invoke('len',object),1100000);
    assert.throws(()=>i.invoke('new'),/resource limit/); assert.equal(i.invoke('len',object),1100000);
    assert.equal(i.collectGarbage(),0);
    i.load('(module (func (export "run") (result i32) i32.const 42))'); assert.equal(i.invoke('run'),42);
  });
  test(`${runtime}: expanded operand, control and folded syntax stacks preserve nesting`,async()=>{
    const i=await create(undefined,{limits:{operands:5000,controls:5000,syntaxDepth:5000}});
    i.load(`(module (func (export "run") (result i32) ${'i32.const 1 '.repeat(4500)} ${'drop '.repeat(4500)} i32.const 42))`);
    assert.equal(i.invoke('run'),42);
    i.load(`(module (func (export "run") (result i32) ${'block '.repeat(4200)} ${'end '.repeat(4200)} i32.const 42))`);
    assert.equal(i.invoke('run'),42);
    i.load(`(module (func (export "run") (result i32) ${'(block '.repeat(300)} ${')'.repeat(300)} i32.const 42))`);
    assert.equal(i.invoke('run'),42);
  });

  test(`${runtime}: expanded memory descriptors and branch target storage remain isolated`,async()=>{
    const i=await create(undefined,{limits:{memories:600,auxiliarySlots:150000}});
    i.load(`(module ${'(memory 0) '.repeat(512)} (memory (export "last") 1)
      (func (export "run") (result i32) block i32.const 0 br_table ${'0 '.repeat(131073)} end i32.const 42))`);
    assert.equal(i.invoke('run'),42); i.writeMemory(0,bytes('safe'),'last');
    assert.deepEqual(i.readMemory(0,4,'last'),bytes('safe'));
  });

  test(`${runtime}: enlarged result shape records and binary expansion preserve late functions`,async()=>{
    const i=await create(undefined,{limits:{resultShapes:5000,binaryTextBytes:2*1024*1024,dataBytes:200000}});
    i.load(`(module ${Array.from({length:4200},(_,n)=>`(func $f${n} (result i32 i32) i32.const ${n} i32.const 42)`).join('')}
      (export "last" (func $f4199)))`);
    assert.deepEqual(i.invoke('last'),[4199,42]);
    const source=`(module (memory 3) (data (i32.const 0) "${'A'.repeat(180000)}"))`;
    i.loadBinary(await binary(source)); assert.deepEqual(i.readMemory(179996,4),bytes('AAAA'));
  });

  test(`${runtime}: enlarged float scratch preserves rounding and reloads`,async()=>{
    const i=await create(undefined,{limits:{floatLiteralBytes:12000}});
    i.load(`(module (func (export "run") (result f64) f64.const 1.${'0'.repeat(9000)}1))`);
    assert.equal(i.invoke('run'),1);
    i.load('(module (func (export "run") (result f64) f64.const 0x1.8p1))');
    assert.equal(i.invoke('run'),3);
  });

  test(`${runtime}: enlarged deferred signatures and reference descriptors resolve late types`,async()=>{
    const i=await create(undefined,{limits:{types:5000,indirectTypes:1500,referenceTypes:5000}});
    i.load(`(module (table 0 funcref) (func (export "run") (result i32) unreachable
      ${'call_indirect (param i32) '.repeat(1100)}))`);
    assert.throws(()=>i.invoke('run'),/unreachable/);
    i.load(`(module ${Array.from({length:4200},(_,n)=>`(type $S${n} (struct))`).join('')}
      (func (export "run") (result i32) ${Array.from({length:4200},(_,n)=>`ref.null $S${n} drop `).join('')} i32.const 42))`);
    assert.equal(i.invoke('run'),42);
  });

  test(`${runtime}: enlarged operand root maps preserve live references across calls`,async()=>{
    const source=`(module (func $f) (func (export "run") (param externref) (result externref)
      ${'local.get 0 '.repeat(1200)} ${'call $f '.repeat(1800)} ${'drop '.repeat(1199)}))`;
    const small=await create(); assert.throws(()=>small.load(source),/resource limit/);
    const i=await create(undefined,{limits:{gcMapBytes:8*1024*1024}});
    i.load(source); const object={}; assert.equal(i.invoke('run',object),object);
  });

  test(`${runtime}: enlarged constructor root scratch retains sibling constant objects`,async()=>{
    const i=await create(undefined,{limits:{gcTemporaries:1200}});
    i.load(`(module (type $S (struct (field i32)))
      (type $W (struct ${'(field (ref $S)) '.repeat(1100)}))
      (global $g (ref $W) (struct.new $W ${'(struct.new $S (i32.const 42)) '.repeat(1100)}))
      (func (export "run") (result i32) global.get $g struct.get $W 1099 struct.get $S 0))`);
    assert.equal(i.invoke('run'),42); i.collectGarbage(); assert.equal(i.invoke('run'),42);
  });

  test(`${runtime}: enlarged structural comparison stacks match deep equivalent type chains`,async()=>{
    const chain=p=>Array.from({length:1100},(_,n)=>`(type $${p}${n} (struct ${n?`(field (ref null $${p}${n-1}))`:''}))`).join('');
    const source=`(module ${chain('a')}${chain('b')}
      (func (export "run") (param (ref null $a1099)) (result (ref null $b1099)) local.get 0))`;
    const i=await create(undefined,{limits:{types:3000,typeComparisonDepth:1600},parentLimits:{callFrames:10000,operands:20000,controls:20000}});
    i.load(source); assert.equal(i.invoke('run',null),null);
  });

  test(`${runtime}: wide typed imports and exported forwarding preserve high halves`,async()=>{
    const options={limits:{parameters:320,results:320}};
    const provider=await create(undefined,options), consumer=await create(undefined,options);
    const types='v128 '.repeat(300), gets=Array.from({length:300},(_,n)=>`local.get ${n}`).join(' ');
    provider.load(`(module (func (export "run") (param ${types}) (result ${types}) ${gets}))`);
    consumer.load(`(module (import "p" "run" (func $f (param ${types}) (result ${types})))
      (func (export "run") (param ${types}) (result ${types}) ${gets} call $f))`,{p:provider.exportNamespace()});
    const values=Array.from({length:300},(_,n)=>(BigInt(n+1)<<100n)|BigInt(n));
    assert.deepEqual(consumer.invoke('run',...values),values);
    consumer.load(`(module (import "h" "f" (func $f (param ${types}) (result ${types})))
      (export "run" (func $f)))`,{h:{f:(...args)=>args}});
    assert.deepEqual(consumer.invoke('run',...values),values);
  });

  test(`${runtime}: host reference and forwarding quotas are independent and recover after exhaustion`,async()=>{
    const i=await create(undefined,{limits:{externalReferences:2}});
    i.load('(module (func (export "run") (param externref) (result externref) local.get 0))');
    const a={},b={}; assert.equal(i.invoke('run',a),a); assert.equal(i.invoke('run',b),b);
    assert.throws(()=>i.invoke('run',{}),/external reference resource limit/);
    assert.equal(i.invoke('run',a),a); i.load('(module)');
    const inner=await create(undefined,{limits:{forwardingDepth:2}});
    const middle=await create(undefined,{limits:{forwardingDepth:2}});
    const outer=await create(undefined,{limits:{forwardingDepth:2}});
    inner.load('(module (func (export "run") (result i32) i32.const 42))');
    const source='(module (import "p" "run" (func $f (result i32))) (export "run" (func $f)))';
    middle.load(source,{p:inner.exportNamespace()}); outer.load(source,{p:middle.exportNamespace()});
    assert.equal(middle.invoke('run'),42);
    assert.throws(()=>outer.invoke('run'),error=>{while(error.cause) error=error.cause; return /forwarding depth limit/.test(error.message);});
    assert.equal(middle.invoke('run'),42);
  });

  test(`${runtime}: oversized combined arenas fail before pointer wrap`,async()=>{
    const i=await create(undefined,{limits:{tables:65536,tableEntries:16777216}});
    assert.throws(()=>i.load('(module)'),/resource limit/);
    const healthy=await create(); healthy.load('(module (func (export "run") (result i32) i32.const 42))');
    assert.equal(healthy.invoke('run'),42);
  });

  test(`${runtime}: enlarged call frame records preserve deep recursion and recovery`,async()=>{
    const i=await create(undefined,{limits:{callFrames:6000,controls:16000,operands:12000}});
    i.setFuel(200000);
    i.load(`(module (func $f (export "run") (param $n i32) (result i32)
      local.get $n if (result i32) local.get $n i32.const 1 i32.sub call $f else i32.const 42 end))`);
    assert.equal(i.invoke('run',5000),42);
    assert.throws(()=>i.invoke('run',6000),/resource limit/);
    assert.equal(i.invoke('run',20),42);
  });

}
