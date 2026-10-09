import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {test} from 'node:test';
import {runtimeFactories} from './runtime.js';

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: allocation pressure reclaims dead arrays within one call and across calls`, async () => {
    const engine = await create();
    engine.load(`(module (type $A (array i32))
      (func (export "run") (param i32) (local $i i32)
        loop $again i32.const 262144 array.new_default $A drop
          local.get $i i32.const 1 i32.add local.tee $i local.get 0 i32.lt_u br_if $again end)
      (func (export "large") i32.const 1048575 array.new_default $A drop))`);
    engine.setFuel(1000000);
    engine.invoke('run', 20);
    for (let i = 0; i < 10; i++) engine.invoke('run', 3);
    assert.ok(engine.collectGarbage() > 0);
    assert.equal(engine.collectGarbage(), 0);
    engine.invoke('large'); engine.invoke('large');
    assert.equal(engine.collectGarbage(), 16777216);
  });

  test(`${runtime}: precise roots preserve locals, saved caller operands, constructor inputs and numeric lookalikes`, async () => {
    const engine = await create();
    engine.load(`(module (type $S (struct (field i32))) (type $A (array (ref null $S)))
      (type $D (array i32)) (type $P (struct (field (ref $S))))
      (global $numeric (mut i64) (i64.const 0x40000000))
      (func $pressure i32.const 1048570 array.new_default $D drop
        i32.const 262144 array.new_default $D drop)
      (func $read (param (ref $S)) (result i32) call $pressure local.get 0 struct.get $S 0)
      (func (export "local") (result i32) (local $live (ref null $S))
        i32.const 42 struct.new $S local.set $live call $pressure local.get $live struct.get $S 0)
      (func (export "operand") (result i32) i32.const 43 struct.new $S call $pressure struct.get $S 0)
      (func (export "caller") (result i32)
        i32.const 44 struct.new $S i32.const 45 struct.new $S call $read drop struct.get $S 0)
      (func (export "array") (result i32)
        i32.const 46 struct.new $S i32.const 1048570 array.new_default $D drop
        i32.const 262144 array.new $A i32.const 262143 array.get $A struct.get $S 0)
      (func (export "struct") (result i32)
        i32.const 47 struct.new $S i32.const 1048571 array.new_default $D drop
        struct.new $P struct.get $P 0 struct.get $S 0)
      (func (export "numbers") (result i64)
        i64.const 0x40000000 i32.const 262144 array.new_default $D drop call $pressure)
      (func (export "clear") i32.const 262144 array.new_default $D drop))`);
    for (const [name, value] of [['local',42], ['operand',43], ['caller',44], ['array',46], ['struct',47]]) {
      assert.equal(engine.invoke(name), value);
      assert.ok(engine.collectGarbage() > 0);
      assert.equal(engine.collectGarbage(), 0);
    }
    assert.equal(engine.invoke('numbers'), 0x40000000n);
    assert.ok(engine.collectGarbage() > 0);
  });

  test(`${runtime}: collection traces cycles and shared fields, coalesces holes, preserves table/global roots and clears reload state`, async () => {
    const engine = await create();
    engine.load(`(module (type $N (struct (field (mut (ref null $N))) (field (mut i32))))
      (type $A (array (mut (ref null $N)))) (type $D (array i32))
      (global $root (mut (ref null $N)) (ref.null $N))
      (global $array (mut (ref null $A)) (ref.null $A))
      (table $t 1 (ref null $N))
      (func (export "setup") (local $n (ref null $N))
        ref.null $N i32.const 77 struct.new $N local.set $n
        local.get $n local.get $n struct.set $N 0
        local.get $n global.set $root
        local.get $n i32.const 3 array.new $A global.set $array
        i32.const 0 local.get $n table.set $t)
      (func (export "read") (result i32) global.get $array i32.const 2 array.get $A struct.get $N 0 struct.get $N 1)
      (func (export "mutate") i32.const 0 table.get $t i32.const 99 struct.set $N 1)
      (func (export "dropGlobal") ref.null $N global.set $root ref.null $A global.set $array)
      (func (export "dropTable") i32.const 0 ref.null $N table.set $t)
      (func (export "readTable") (result i32) i32.const 0 table.get $t struct.get $N 1)
      (func (export "deadCycle") (local $n (ref null $N))
        ref.null $N i32.const 123 struct.new $N local.tee $n local.get $n struct.set $N 0)
      (func (export "garbage") i32.const 262144 array.new_default $D drop))`);
    engine.invoke('setup');
    for (let i = 0; i < 10; i++) engine.invoke('garbage');
    assert.ok(engine.collectGarbage() > 0);
    assert.equal(engine.invoke('read'), 77);
    engine.invoke('mutate'); assert.equal(engine.invoke('read'), 99);
    engine.invoke('dropGlobal'); assert.ok(engine.collectGarbage() > 0);
    assert.equal(engine.invoke('readTable'), 99);
    engine.invoke('dropTable'); assert.equal(engine.collectGarbage(), 48);
    engine.invoke('deadCycle'); assert.equal(engine.collectGarbage(), 48);
    engine.load('(module (func (export "answer") (result i32) i32.const 42))');
    assert.equal(engine.collectGarbage(), 0); assert.equal(engine.invoke('answer'), 42);
  });

  test(`${runtime}: GC preserves JavaScript handles, conversion identity, host callbacks and rejects stale references`, async () => {
    const engine = await create();
    const source = `(module (type $S (struct (field i32))) (type $D (array i32))
      (import "h" "keep" (func $keep (param (ref $S))))
      (func (export "new") (result (ref $S)) i32.const 42 struct.new $S)
      (func (export "read") (param (ref $S)) (result i32) local.get 0 struct.get $S 0)
      (func (export "external") (param (ref $S)) (result externref) local.get 0 extern.convert_any)
      (func (export "pressure") i32.const 1048570 array.new_default $D drop
        i32.const 262144 array.new_default $D drop)
      (func (export "callback") i32.const 99 struct.new $S call $keep))`;
    let saved;
    engine.load(source, {h:{keep: value => {saved = value; assert.throws(() => engine.collectGarbage(), /already invoking/);}}});
    const reference = engine.invoke('new');
    engine.invoke('pressure'); engine.collectGarbage();
    assert.equal(engine.invoke('read', reference), 42);
    assert.equal(engine.invoke('external', reference), reference);
    engine.invoke('callback'); engine.invoke('pressure'); engine.collectGarbage();
    assert.equal(engine.invoke('read', saved), 99);
    engine.load(source, {h:{keep(){}}});
    assert.throws(() => engine.invoke('read', reference), /live opaque/);
  });

  test(`${runtime}: weak host caches allow unreachable JavaScript handles to be reclaimed`, () => {
    // Explicit V8 collection makes the host-lifetime check independent from automatic GC scheduling.
    execFileSync(process.execPath, ['--expose-gc', '--input-type=module', '-e', `
      import assert from 'node:assert/strict';
      import {setImmediate} from 'node:timers/promises';
      import {runtimeFactories} from './test/runtime.js';
      const create = runtimeFactories.find(([name]) => name === ${JSON.stringify(runtime)})[1];
      const engine = await create();
      engine.load('(module (type $A (array i32)) (func (export "new") (result (ref $A)) i32.const 65536 array.new_default $A) (func (export "len") (param (ref $A)) (result i32) local.get 0 array.len))');
      const live = engine.invoke('new');
      const dead = new WeakRef(engine.invoke('new'));
      assert.equal(engine.collectGarbage(), 0);
      let reclaimed = 0;
      for (let i = 0; i < 50 && !reclaimed; i++) {
        await setImmediate(); global.gc(); await setImmediate(); global.gc();
        reclaimed += engine.collectGarbage();
      }
      assert.equal(dead.deref(), undefined);
      assert.equal(reclaimed, 1048592);
      assert.equal(engine.invoke('len', live), 65536);
    `], {cwd: new URL('..', import.meta.url), stdio: 'pipe'});
  });
}

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: exception references retain typed payload graphs and uncaught host payloads across collection`, async () => {
    const engine = await create();
    engine.load(`(module (type $S (struct (field i32))) (type $D (array i32))
      (tag $tag (param (ref $S) v128 i64))
      (global $caught (mut exnref) (ref.null exn))
      (func $pressure i32.const 1048560 array.new_default $D drop i32.const 262144 array.new_default $D drop)
      (func (export "capture")
        block $caughtBlock (result exnref)
          try_table (catch_all_ref $caughtBlock)
            i32.const 42 struct.new $S v128.const i64x2 0x40000000 -1 i64.const 0x40000000 throw $tag
          end unreachable
        end global.set $caught)
      (func (export "check") (result i32) call $pressure
        block $payload (result (ref $S) v128 i64)
          try_table (catch $tag $payload) global.get $caught throw_ref end unreachable
        end drop drop struct.get $S 0)
      (func (export "uncaught") global.get $caught throw_ref)
      (func (export "clear") ref.null exn global.set $caught))`);
    engine.invoke('capture'); assert.equal(engine.collectGarbage(), 0);
    assert.equal(engine.invoke('check'), 42); engine.collectGarbage();
    let caught;
    try { engine.invoke('uncaught'); } catch (error) {caught = error;}
    assert.equal(caught?.name, 'WiwException');
    engine.invoke('clear');
    // The copied host exception owns its struct handle, but the guest exception itself is now dead.
    assert.equal(engine.collectGarbage(), 112);
    assert.equal(engine.collectGarbage(), 0);
  });

  test(`${runtime}: non-moving collection reuses and coalesces interior holes with live objects on both sides`, async () => {
    const engine = await create();
    engine.load(`(module (type $A (array (mut i32)))
      (global $first (mut (ref null $A)) (ref.null $A))
      (global $last (mut (ref null $A)) (ref.null $A))
      (func (export "setup")
        i32.const 11 i32.const 262144 array.new $A global.set $first
        i32.const 262144 array.new_default $A drop
        i32.const 262144 array.new_default $A drop
        i32.const 22 i32.const 262140 array.new $A global.set $last)
      (func (export "reuse") i32.const 524289 array.new_default $A drop)
      (func (export "first") (result i32) global.get $first i32.const 262143 array.get $A)
      (func (export "last") (result i32) global.get $last i32.const 262139 array.get $A)
      (func (export "clear") ref.null $A global.set $first ref.null $A global.set $last))`);
    engine.invoke('setup');
    assert.equal(engine.collectGarbage(), 8388640);
    for (let i = 0; i < 6; i++) {
      engine.invoke('reuse'); engine.collectGarbage();
      assert.equal(engine.invoke('first'), 11); assert.equal(engine.invoke('last'), 22);
    }
    engine.invoke('clear'); assert.equal(engine.collectGarbage(), 8388576);
  });

  test(`${runtime}: nested constants and live passive elements remain rooted during initialization and collection`, async () => {
    const engine = await create();
    engine.load(`(module (type $S (struct (field i32))) (type $A (array (ref $S))) (type $D (array i32))
      (global $root (mut (ref null $A))
        (array.new $A (struct.new $S (i32.const 42)) (i32.const 3)))
      (elem $objects (ref $S) (struct.new $S (i32.const 77)))
      (func (export "read") (result i32) global.get $root i32.const 2 array.get $A struct.get $S 0)
      (func (export "element") (result i32) i32.const 0 i32.const 1 array.new_elem $A $objects i32.const 0 array.get $A struct.get $S 0)
      (func (export "pressure") i32.const 1048550 array.new_default $D drop i32.const 262144 array.new_default $D drop)
      (func (export "drop") elem.drop $objects ref.null $A global.set $root))`);
    assert.equal(engine.invoke('read'), 42);
    assert.equal(engine.invoke('element'), 77);
    engine.invoke('pressure'); engine.collectGarbage();
    assert.equal(engine.invoke('read'), 42); assert.equal(engine.invoke('element'), 77);
    engine.invoke('drop'); assert.ok(engine.collectGarbage() > 0);
    assert.equal(engine.collectGarbage(), 0);
  });
}

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: iterative marking retains long graphs and reclaims numeric lookalikes in fields and upper exception payloads`, async () => {
    const engine = await create();
    const numericParams = Array(64).fill('i64').join(' ');
    const numericValues = Array(64).fill('i64.const 0x40000000').join(' ');
    const drops = Array(64).fill('drop').join(' ');
    engine.load(`(module (type $N (struct (field (ref null $N)) (field i32)))
      (type $D (array i32)) (type $S (struct (field i64)))
      (global $root (mut (ref null $N)) (ref.null $N))
      (global $numeric (mut (ref null $S)) (ref.null $S))
      (global $exception (mut exnref) (ref.null exn))
      (tag $tag (param ${numericParams} (ref $N)))
      (func (export "build") (param i32) (local $i i32)
        loop $again global.get $root local.get $i struct.new $N global.set $root
          local.get $i i32.const 1 i32.add local.tee $i local.get 0 i32.lt_u br_if $again end)
      (func (export "count") (result i32) (local $n (ref null $N)) (local $count i32)
        global.get $root local.set $n block $done loop $again
          local.get $n ref.is_null br_if $done local.get $count i32.const 1 i32.add local.set $count
          local.get $n struct.get $N 0 local.set $n br $again end end local.get $count)
      (func (export "clear") ref.null $N global.set $root ref.null exn global.set $exception)
      (func (export "numeric") i32.const 262144 array.new_default $D drop
        i64.const 0x40000000 struct.new $S global.set $numeric)
      (func (export "capture") block $caught (result exnref)
        try_table (catch_all_ref $caught)
          ${numericValues} ref.null $N i32.const 77 struct.new $N throw $tag
        end unreachable end global.set $exception)
      (func (export "payload") (result i32) (local $result i32)
        block $caught (result ${numericParams} (ref $N))
          try_table (catch $tag $caught) global.get $exception throw_ref end unreachable
        end struct.get $N 1 local.set $result ${drops} local.get $result))`);
    engine.setFuel(1000000);
    engine.invoke('numeric'); assert.equal(engine.collectGarbage(), 4194320);
    engine.invoke('build', 20000); assert.equal(engine.collectGarbage(), 0);
    assert.equal(engine.invoke('count'), 20000);
    engine.invoke('clear'); assert.equal(engine.collectGarbage(), 960000);
    engine.invoke('capture'); assert.equal(engine.collectGarbage(), 0);
    assert.equal(engine.invoke('payload'), 77);
    engine.invoke('clear'); assert.ok(engine.collectGarbage() > 0);
    assert.equal(engine.collectGarbage(), 0);
  });

  test(`${runtime}: collection during imported-tag initialization protects nested constructors and start allocations`, async () => {
    const engine = await create();
    // Deferred initializers execute again after binding, forcing collection while a nested parent is incomplete.
    const provider = await create();
    provider.load('(module (tag (export "t")))');
    engine.load(`(module (type $D (array i32))
      (type $S (struct (field (ref $D)) (field (ref $D))))
      (tag (import "p" "t"))
      (global $g (mut (ref null $S))
        (struct.new $S (array.new_default $D (i32.const 262144)) (array.new_default $D (i32.const 262144))))
      (func $start i32.const 262144 array.new_default $D drop i32.const 262144 array.new_default $D drop i32.const 262144 array.new_default $D drop)
      (start $start)
      (func (export "read") (result i32) global.get $g struct.get $S 0 array.len)
      (func (export "other") (result i32) global.get $g struct.get $S 1 array.len))`, {p: provider.exportNamespace()});
    assert.equal(engine.invoke('read'), 262144); assert.equal(engine.invoke('other'), 262144);
    assert.ok(engine.collectGarbage() > 0);
    assert.equal(engine.collectGarbage(), 0);
  });
}

// Standard GC wire encoding: array i32 plus a void function allocating and dropping five 4 MiB arrays.
const instructions = Array.from({length:5}, () => [0x41,0x80,0x80,0x10,0xfb,0x07,0x00,0x1a]).flat();
const body = [0,...instructions,0x0b];
const collectionBinary = Uint8Array.from([0,97,115,109,1,0,0,0,
  1,7,2,0x5e,0x7f,0,0x60,0,0, 3,2,1,1,
  7,7,1,3,114,117,110,0,0, 10,body.length+2,1,body.length,...body]);
for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: binary guests collect under exact fuel and preserve native results`, async () => {
    const native = (await WebAssembly.instantiate(collectionBinary)).instance;
    assert.equal(native.exports.run(), undefined);
    const engine = await create(); engine.loadBinary(collectionBinary);
    engine.setFuel(15);
    for (let i = 0; i < 5; i++) assert.equal(engine.invoke('run'), undefined);
    assert.ok(engine.collectGarbage() > 0);
    engine.setFuel(14);
    assert.throws(() => engine.invoke('run'), /exhausted fuel/);
    assert.ok(engine.collectGarbage() > 0);
    engine.setFuel(15); assert.equal(engine.invoke('run'), undefined);
  });
}

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: imported exception allocation collects safely while preserving suspended caller locals and payload identity`, async () => {
    const engine = await create();
    let saved;
    engine.load(`(module (type $S (struct (field i32))) (type $D (array i32))
      (import "h" "throw" (func $host)) (tag $tag (param (ref $S)))
      (func (export "capture") i32.const 42 struct.new $S throw $tag)
      (func (export "forward") (param i32) (result i32) (local $live (ref null $S))
        i32.const 99 struct.new $S local.set $live
        local.get 0 array.new_default $D drop
        block $payload (result (ref $S))
          try_table (catch $tag $payload) call $host end unreachable
        end struct.get $S 0 local.get $live struct.get $S 0 i32.add))`, {h:{throw(){throw saved;}}});
    try {engine.invoke('capture');} catch (error) {saved = error;}
    assert.equal(saved?.name, 'WiwException');
    assert.equal(engine.invoke('forward', 1048566), 141);
    engine.collectGarbage();
    assert.equal(engine.invoke('forward', 1048500), 141);
  });
}

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: failed allocations stop before later host effects and explicit collection recovers from traps`, async () => {
    const engine = await create(); let effects = 0;
    engine.load(`(module (type $A (array i32)) (import "h" "effect" (func $effect))
      (func (export "trap") i32.const -1 array.new_default $A drop call $effect)
      (func (export "run") i32.const 262144 array.new_default $A drop))`, {h:{effect(){effects++;}}});
    assert.throws(() => engine.invoke('trap'), /resource limit/);
    assert.equal(effects, 0); assert.equal(engine.collectGarbage(), 0);
    engine.invoke('run'); assert.equal(engine.collectGarbage(), 4194320);
  });
}
