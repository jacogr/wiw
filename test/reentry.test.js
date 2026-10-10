import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {runtimeFactories} from './runtime.js';
const deferred=()=>Promise.withResolvers();
const leaf=error=>{while(error.cause)error=error.cause;return error;};

for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: synchronous callbacks reenter with distinct frames and recover from nested failures`,async()=>{
    const i=await create();
    i.load(`(module (import "h" "again" (func $again (param i32) (result i32)))
      (func (export "bad") unreachable)
      (func (export "run") (param $n i32) (result i32) (local $saved i32)
        local.get $n local.set $saved local.get $n
        if (result i32) local.get $n i32.const 1 i32.sub call $again else i32.const 1 end
        local.get $saved i32.add))`,{h:{again:n=>{
      assert.throws(()=>i.invoke('bad'),/unreachable/);
      assert.throws(()=>i.invoke('run','bad'),/i32/);
      assert.throws(()=>i.load('(module)'),/already invoking/);
      assert.throws(()=>i.collectGarbage(),/already invoking/);
      return i.invoke('run',n);
    }}});
    assert.equal(i.invoke('run',10),56); assert.equal(i.invoke('run',0),1);
  });

  test(`${runtime}: async nested imports protect outer GC locals and operands across allocation and growth`,async()=>{
    const i=await create(), gate=deferred();
    i.load(`(module (type $S (struct (field i32))) (type $A (array i32))
      (import "h" "outer" (func $outer (result i32))) (import "h" "wait" (func $wait))
      (memory (export "m") 1 3)
      (func (export "inner") (result i32) call $wait
        ${'i32.const 262144 array.new_default $A drop '.repeat(6)} i32.const 2)
      (func (export "run") (result i32) (local $s (ref null $S))
        i32.const 40 struct.new $S local.set $s i32.const 41 struct.new $S
        call $outer drop struct.get $S 0 local.get $s struct.get $S 0 i32.add))`,{h:{
      outer:async()=>{await Promise.resolve();const value=await i.invokeAsync('inner');assert.equal(value,2);return value;},
      wait:async()=>{await gate.promise;i.growMemory(1);i.writeMemory(0,new Uint8Array([42]));}
    }});
    const pending=i.invokeAsync('run');
    assert.throws(()=>i.invoke('inner'),/already invoking/);
    await assert.rejects(i.invokeAsync('inner'),/already invoking/);
    gate.resolve();assert.equal(await pending,81);assert.equal(i.readMemory(0,1)[0],42);
    assert.equal(i.memoryPages(),2);i.collectGarbage();
  });

  test(`${runtime}: directly exported imports and tail imports preserve nested vector high halves`,async()=>{
    const i=await create(); const bits=(42n<<100n)|7n;
    i.load(`(module (import "h" "outer" (func $outer (param v128) (result v128)))
      (import "h" "inner" (func $inner (param v128) (result v128)))
      (export "run" (func $outer)) (export "direct" (func $inner))
      (func (export "tail") (param v128) (result v128) local.get 0 return_call $inner))`,{h:{
      outer:value=>{assert.equal(i.invoke('tail',value),value);return i.invoke('direct',value);}, inner:x=>x
    }});
    assert.equal(i.invoke('run',bits),bits);assert.equal(await i.invokeAsync('run',bits),bits);
  });

  test(`${runtime}: nested exceptions stay inside their callback boundary until rethrown`,async()=>{
    const i=await create();let shouldThrow=false;
    i.load(`(module (import "h" "f" (func $f)) (tag $t (export "t") (param i32))
      (func (export "throw") i32.const 42 throw $t)
      (func (export "run") (result i32) block $caught (result i32)
        try_table (catch $t $caught) call $f end i32.const 7 end))`,{h:{f:()=>{
      if(shouldThrow)return i.invoke('throw');
      assert.throws(()=>i.invoke('throw'),e=>e.is(i.getTag('t'))&&e.getArg(i.getTag('t'),0)===42);
    }}});
    assert.equal(i.invoke('run'),7);shouldThrow=true;assert.equal(i.invoke('run'),42);
    assert.equal(await i.invokeAsync('run'),42);
  });

  test(`${runtime}: unawaited async children finish before outer completion or rejection`,async()=>{
    const i=await create(),gate=deferred();let child,fail=false;
    i.load(`(module (import "h" "outer" (func $outer (result i32))) (import "h" "wait" (func $wait))
      (global (export "g") (mut i32) (i32.const 0))
      (func (export "inner") call $wait i32.const 42 global.set 0)
      (func (export "run") (result i32) call $outer))`,{h:{
      outer:()=>{child=i.invokeAsync('inner');if(fail)throw new Error('outer failure');return 7;},
      wait:()=>gate.promise
    }});
    let finished=false;const pending=i.invokeAsync('run').then(x=>{finished=true;return x;});
    await Promise.resolve();assert.equal(finished,false);gate.resolve();assert.equal(await pending,7);await child;
    assert.equal(i.getGlobal('g'),42);fail=true;await assert.rejects(i.invokeAsync('run'),e=>leaf(e).message==='outer failure');
    await child;fail=false;assert.equal(await i.invokeAsync('run'),7);
  });

  test(`${runtime}: expired callback scopes and synchronous parents reject async overlap`,async()=>{
    const i=await create(),gate=deferred();let escaped;
    i.load(`(module (import "h" "f" (func $f (result i32)))
      (func (export "leaf") (result i32) i32.const 42) (func (export "run") (result i32) call $f))`,{h:{f:()=>{
      escaped=new Promise(resolve=>setTimeout(()=>{try{resolve(i.invoke('leaf'));}catch(e){resolve(e);}},20));
      return 7;
    }}});
    assert.equal(i.invoke('run'),7);
    i.load(`(module (import "h" "wait" (func $wait)) (func (export "run") call $wait)
      (func (export "leaf") (result i32) i32.const 42))`,{h:{wait:()=>gate.promise}});
    const pending=i.invokeAsync('run');assert.match((await escaped).message,/already invoking/);gate.resolve();await pending;
    let rejected;
    i.load('(module (import "h" "f" (func $f)) (func (export "leaf")) (func (export "run") call $f))',
      {h:{f:()=>{rejected=i.invokeAsync('leaf');rejected.catch(()=>{});}}});
    i.invoke('run');await assert.rejects(rejected,/asynchronous outer/);i.invoke('leaf');
  });

  test(`${runtime}: start callbacks reenter initialized exports and table-owned functions`,async()=>{
    const i=await create();
    const source=`(module (import "h" "start" (func $host))
      (table (export "t") 1 funcref) (func $hidden (result i32) i32.const 42) (elem (i32.const 0) $hidden)
      (global (export "g") (mut i32) (i32.const 0))
      (func (export "set") (param i32) local.get 0 global.set 0)
      (func $start call $host) (start $start))`;
    i.load(source,{h:{start:()=>i.invoke('set',i.getTable(0)())}});assert.equal(i.getGlobal('g'),42);
    await i.loadAsync(source,{h:{start:async()=>{await Promise.resolve();await i.invokeAsync('set',i.getTable(0)());}}});
    assert.equal(i.getGlobal('g'),42);
  });

  test(`${runtime}: callback cycles across instances return to the original suspended frame`,async()=>{
    const a=await create(),b=await create();
    a.load(`(module (import "h" "b" (func $b (result i32))) (func (export "leaf") (result i32) i32.const 40)
      (func (export "run") (result i32) i32.const 1 call $b i32.add))`,{h:{b:()=>b.invoke('run')}});
    b.load('(module (import "a" "leaf" (func $f (result i32))) (func (export "run") (result i32) call $f i32.const 1 i32.add))',
      {a:a.exportNamespace()});assert.equal(a.invoke('run'),42);
    b.load('(module (import "a" "leaf" (func $f (result i32))) (export "run" (func $f)))',{a:a.exportNamespaceAsync()});
    a.load(`(module (import "h" "b" (func $b (result i32))) (func (export "leaf") (result i32) i32.const 42)
      (func (export "run") (result i32) call $b))`,{h:{b:async()=>{await Promise.resolve();return b.invokeAsync('run');}}});
    // Reload invalidates old bindings; rebind B to the new A generation.
    b.load('(module (import "a" "leaf" (func $f (result i32))) (export "run" (func $f)))',{a:a.exportNamespaceAsync()});
    assert.equal(await a.invokeAsync('run'),42);
  });

  test(`${runtime}: nested fuel and call quotas preserve the outer continuation on failure`,async()=>{
    const i=await create(undefined,{limits:{callFrames:3}});
    i.load(`(module (import "h" "f" (func $f (result i32)))
      (func (export "leaf") (result i32) i32.const 42)
      (func (export "run") (result i32) call $f))`,{h:{f:()=>{
      i.setFuel(0);assert.throws(()=>i.invoke('leaf'),/exhausted fuel/);
      i.setFuel(10);assert.throws(()=>i.invoke('run'),e=>/resource limit/.test(leaf(e).message));
      i.setFuel(10);return i.invoke('leaf');
    }}});
    i.setFuel(1);assert.equal(i.invoke('run'),42);assert.equal(i.invoke('leaf'),42);
  });

  test(`${runtime}: raw async reference results remain opaque after nested reentry`,async()=>{
    const i=await create();const object={get then(){throw new Error('opaque');}};
    // Returning a thenable from an ordinary async function would assimilate it: use raw typed forwarding instead.
    i.load(`(module (import "h" "outer" (func $outer (result externref)))
      (import "h" "inner" (func $inner (result externref))) (export "run" (func $outer)) (export "leaf" (func $inner)))`,
      {h:{outer:()=>i.invoke('leaf'),inner:()=>object}});
    assert.equal((await i.invokeRawAsync('run')).value,object);
  });
}

for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: nested raw multivalue results preserve NaN payloads and both vector halves`,async()=>{
    const i=await create();
    const types='f32 v128 i64';
    i.load(`(module (import "h" "outer" (func $outer (result ${types})))
      (func (export "echo") (param ${types}) (result ${types}) local.get 0 local.get 1 local.get 2)
      (func (export "run") (result ${types}) call $outer))`,{h:{outer:()=>{
        const slots=[{type:'f32',bits:0x7fa12345n},{type:'v128',bits:(42n<<100n)|7n},{type:'i64',bits:0xffffffffffffffffn}];
        assert.deepEqual(i.invokeRaw('echo',...slots),slots);
        return [1.25,slots[1].bits,-1n];
      }}});
    assert.deepEqual(i.invokeRaw('run'),[{type:'f32',bits:0x3fa00000n},{type:'v128',bits:(42n<<100n)|7n},{type:'i64',bits:0xffffffffffffffffn}]);
    assert.deepEqual(await i.invokeAsync('run'),[1.25,(42n<<100n)|7n,-1n]);
  });

  test(`${runtime}: async sibling calls cannot replace an active child and rejected children restore ownership`,async()=>{
    const i=await create(),gate=deferred();let fail=true;
    i.load(`(module (import "h" "outer" (func $outer (result i32))) (import "h" "wait" (func $wait))
      (func (export "leaf") (result i32) i32.const 42)
      (func (export "child") call $wait) (func (export "run") (result i32) call $outer))`,{h:{
      outer:async()=>{
        const pending=i.invokeAsync('child');
        assert.throws(()=>i.invoke('leaf'),/already invoking/);
        await assert.rejects(i.invokeAsync('leaf'),/already invoking/);
        if(fail)await assert.rejects(pending,e=>leaf(e).message==='child failure');else await pending;
        return i.invoke('leaf');
      },wait:async()=>{await gate.promise;if(fail)throw new Error('child failure');}
    }});
    const pending=i.invokeAsync('run');gate.resolve();assert.equal(await pending,42);
    fail=false;assert.equal(await i.invokeAsync('run'),42);
  });
}


for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: recursive callbacks match native Wasm through binary and text loads`,async()=>{
    const source=`(module (import "h" "again" (func $again (param i32) (result i32)))
      (memory (export "memory") 1 2) (global (export "g") (mut i32) (i32.const 0))
      (func (export "run") (param i32) (result i32)
        global.get 0 i32.const 1 i32.add global.set 0
        local.get 0 if (result i32) local.get 0 i32.const 1 i32.sub call $again i32.const 1 i32.add
        else i32.const 1 memory.grow drop i32.const 40 end))`;
    const directory=await mkdtemp(join(tmpdir(),'wiw-reentry-'));
    try {
      const wat=join(directory,'guest.wat'),wasm=join(directory,'guest.wasm');
      await writeFile(wat,source);execFileSync('wat2wasm',[wat,'-o',wasm]);
      const bytes=await readFile(wasm);let native;
      native=(await WebAssembly.instantiate(bytes,{h:{again:n=>native.exports.run(n)}})).instance;
      assert.equal(native.exports.run(2),42);
      const i=await create();
      for(const binary of [false,true]){
        if(binary)i.loadBinary(bytes,{h:{again:n=>i.invoke('run',n)}});
        else i.load(source,{h:{again:n=>i.invoke('run',n)}});
        assert.equal(i.invoke('run',2),42);assert.equal(i.getGlobal('g'),native.exports.g.value);
        assert.equal(i.memoryPages(),native.exports.memory.buffer.byteLength/65536);
      }
    } finally {await rm(directory,{recursive:true,force:true});}
  });
}

for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: nested root arguments and host results respect the shared operand ceiling before writes`,async()=>{
    const i=await create(undefined,{limits:{parameters:5000,results:5000,locals:5000}});
    const source=`(module (import "h" "args" (func $args (param ${'i32 '.repeat(4100)})))
      (import "h" "results" (func $results (result ${'i32 '.repeat(4100)})))
      (export "args" (func $args)) (export "results" (func $results))
      (func (export "run") (result i32) i32.const 42))`;
    let called=false;
    i.load(source,{h:{args:()=>{called=true;},results:()=>new Array(4100).fill(1)}});
    assert.throws(()=>i.invoke('args',...new Array(4100).fill(0)),/resource limit/);assert.equal(called,false);
    assert.throws(()=>i.invoke('results'),e=>/resource limit/.test(leaf(e).message));assert.equal(i.invoke('run'),42);
    i.load(`(module (import "h" "outer" (func $outer (result i32)))
      (import "h" "results" (func $results (result ${'i32 '.repeat(128)})))
      (export "results" (func $results))
      (func (export "run") (result i32) ${'i32.const 0 '.repeat(4000)} call $outer
        ${'drop '.repeat(4000)}))`,{h:{outer:()=>{
        assert.throws(()=>i.invoke('results'),e=>/resource limit/.test(leaf(e).message));return 42;
      },results:()=>new Array(128).fill(1)}});
    // The outer operands remain unmodified after rejecting an oversized nested result vector.
    assert.equal(i.invoke('run'),0);
  });
}

for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: imported-root reentry uses a boundary without charging a nonexistent guest frame`,async()=>{
    const i=await create(undefined,{limits:{callFrames:1}});
    i.load(`(module (import "h" "outer" (func $outer (result i32)))
      (import "h" "leaf" (func $leaf (result i32)))
      (export "run" (func $outer)) (export "leaf" (func $leaf)))`,{h:{outer:()=>i.invoke('leaf'),leaf:()=>42}});
    assert.equal(i.invoke('run'),42);assert.equal(await i.invokeAsync('run'),42);
  });
}

for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: joining a child waits for guest completion without assimilating its opaque Promise result`,async()=>{
    const i=await create(),gate=deferred();let child;
    i.load(`(module (import "h" "outer" (func $outer (result i32)))
      (import "h" "leaf" (func $leaf (result externref)))
      (export "leaf" (func $leaf)) (export "run" (func $outer)))`,{h:{
      outer:()=>{child=i.invokeAsync('leaf');return 42;},leaf:()=>gate.promise
    }});
    try {
      const outer=i.invokeAsync('run');
      // Guest execution must finish even though the child's public result remains a pending Promise.
      const timeout=setTimeout(()=>gate.reject(new Error('opaque result blocked outer cleanup')),1000);
      try {assert.equal(await outer,42);} finally {clearTimeout(timeout);}
      const value={};gate.resolve(value);assert.equal(await child,value);
    } finally {gate.resolve();await child?.catch(()=>{});}
  });
}
