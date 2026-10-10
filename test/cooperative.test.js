import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createMemory, createGlobal } from '../wiw.js';
import { runtimeFactories } from './runtime.js';

const countdown = `(module (global $count (export "count") (mut i32) (i32.const 0))
  (func (export "run") (param i32) (result i32)
    (loop $again
      global.get $count i32.const 1 i32.add global.set $count
      local.get 0 i32.const 1 i32.sub local.tee 0 br_if $again)
    global.get $count))`;

// Compile a binary fixture to exercise cooperative binary loading through the same common runtime.
async function binary(source) {
  const directory = await mkdtemp(join(tmpdir(), 'wiw-cooperative-'));

  // Always release fixtures even when compilation or decoding fails.
  try {
    await writeFile(join(directory, 'guest.wat'), source);
    execFileSync('wat2wasm', [join(directory, 'guest.wat'), '-o', join(directory, 'guest.wasm')]);

    return await readFile(join(directory, 'guest.wasm'));
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

// Retain an expected trap for comparison of diagnostics and committed guest effects.
function caught(callback) {
  try {
    callback();
  } catch (error) {
    return error;
  }

  assert.fail('expected failure');
}

// Exercise cooperative dispatch and cancellation in both optimized runtime modes.
for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: cooperative dispatch yields without imports and returns the same result`, async () => {
    const engine = await create();

    engine.load(countdown);
    engine.setFuel64(1000000n);
    engine.setCooperativeExecution({ quantum: 100 });

    let timerRan = false;

    setImmediate(() => {
      timerRan = true;
    });
    assert.equal(await engine.invokeAsync('run', 1000), 1000);
    assert.equal(timerRan, true);
    assert.equal(engine.getGlobal('count'), 1000);
    engine.setCooperativeExecution(null);
    assert.equal(engine.invoke('run', 1), 1001);

    const bytes = await binary(countdown);

    engine.setCooperativeExecution({ quantum: 3 });
    await engine.loadBinaryAsync(bytes);
    assert.equal(await engine.invokeRawAsync('run', { type: 'i32', bits: 100n }).then((slot) => slot.bits), 100n);
  });

  test(`${runtime}: cancellation preserves completed writes and permits later invocation and reload`, async () => {
    const engine = await create();
    const controller = new AbortController();

    engine.load(countdown);
    engine.setFuel64((1n << 64n) - 1n);
    engine.setCooperativeExecution({ quantum: 100, signal: controller.signal });

    const reason = new Error('stop');

    setImmediate(() => controller.abort(reason));
    await assert.rejects(engine.invokeAsync('run', 10000000), (error) => {
      assert.equal(error.code, 'ABORTED');
      assert.equal(error.status, 35);
      assert.equal(error.phase, 'invoke');
      assert.equal(error.cause, reason);
      assert.equal(error.location.format, 'wat');

      return true;
    });

    const count = engine.getGlobal('count');

    assert.ok(count > 0 && count < 10000000);
    engine.setCooperativeExecution(null);
    assert.equal(engine.invoke('run', 1), count + 1);
    engine.load(countdown);
    assert.equal(engine.invoke('run', 1), 1);
  });

  test(`${runtime}: cooperative slices preserve exact fuel exhaustion and partial side effects`, async () => {
    const synchronous = await create(),
      asynchronous = await create();

    // Include tiny quanta and partial fused instruction budgets; slices never replenish invocation fuel.
    for (const quantum of [1, 3, 10]) {
      asynchronous.setCooperativeExecution({ quantum });

      for (const fuel of [0, 1, 2, 3, 5, 8, 13, 21, 34]) {
        synchronous.load(countdown);
        await asynchronous.loadAsync(countdown);
        synchronous.setFuel(fuel);
        asynchronous.setFuel(fuel);

        const expected = caught(() => synchronous.invoke('run', 100));

        await assert.rejects(asynchronous.invokeAsync('run', 100), (error) => {
          assert.equal(error.code, expected.code);
          assert.equal(error.byteOffset, expected.byteOffset);

          return true;
        });
        assert.equal(asynchronous.getGlobal('count'), synchronous.getGlobal('count'));
      }
    }
  });

  test(`${runtime}: automatic start remains unfinished across slices and cancellation retains imported writes`, async () => {
    const engine = await create();
    const memory = createMemory({ initial: 1 });
    const controller = new AbortController();

    engine.setCooperativeExecution({ quantum: 20, signal: controller.signal });
    engine.setFuel64(100000000n);
    setImmediate(() => controller.abort('start cancelled'));
    await assert.rejects(
      engine.loadAsync(
        `(module (memory (import "h" "m") 1)
      (data (i32.const 3) "X")
      (func $start (loop $again i32.const 0 i32.const 42 i32.store8 br $again)) (start $start))`,
        { h: { m: memory } }
      ),
      (error) => error.code === 'ABORTED' && error.phase === 'initialize'
    );
    assert.equal(memory.read(0, 1)[0], 42);
    assert.equal(memory.read(3, 1)[0], 88);
    engine.setCooperativeExecution({ quantum: 1 });
    await engine.loadAsync(
      '(module (global $g (export "g") (mut i32) (i32.const 0)) (func $start i32.const 42 global.set $g) (start $start))'
    );
    assert.equal(engine.getGlobal('g'), 42);
  });

  test(`${runtime}: cancellation waits for active host callbacks and callback-owned children`, async () => {
    const engine = await create();
    const controller = new AbortController();
    const gate = Promise.withResolvers();
    const value = createGlobal({ value: 'i32', mutable: true });
    let entered = false,
      childFinished = false,
      settled = false;

    engine.setCooperativeExecution({ quantum: 2, signal: controller.signal });
    engine.load(
      `(module (import "h" "wait" (func $wait)) (import "h" "g" (global $g (mut i32)))
      (func (export "run") call $wait i32.const 99 global.set $g)
      (func (export "child") (result i32) i32.const 7))`,
      {
        h: {
          g: value,
          // Cancellation does not discard a callback's ownership or abandon its pending effects.
          wait: async () => {
            entered = true;

            assert.equal(await engine.invokeAsync('child'), 7);

            childFinished = true;

            await gate.promise;

            value.value = 42;
          }
        }
      }
    );

    const pending = engine.invokeAsync('run');

    pending.catch(() => {
      settled = true;
    });

    // Let the nested child finish before aborting the callback's separate pending operation.
    while (!entered || !childFinished) await new Promise((resolve) => setImmediate(resolve));

    controller.abort('callback cancelled');
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(settled, false);
    assert.throws(() => engine.setCooperativeExecution(null), /invoking|busy|suspended/);
    gate.resolve();
    await assert.rejects(pending, (error) => error.code === 'ABORTED');
    assert.equal(value.value, 42);
    engine.setCooperativeExecution(null);
    assert.equal(engine.invoke('child'), 7);
  });

  test(`${runtime}: pre-aborted async requests have no effects and synchronous execution stays uninterrupted`, async () => {
    const engine = await create();
    const controller = new AbortController();

    controller.abort('already stopped');
    engine.load(countdown);
    engine.setCooperativeExecution({ signal: controller.signal });
    await assert.rejects(
      engine.invokeAsync('run', 1),
      (error) => error.code === 'ABORTED' && error.phase === 'request'
    );
    assert.equal(engine.getGlobal('count'), 0);
    assert.equal(engine.invoke('run', 1), 1);
    await assert.rejects(engine.loadAsync('(module)'), (error) => error.code === 'ABORTED');
    assert.equal(engine.invoke('run', 1), 2);
    assert.throws(() => engine.setCooperativeExecution({ quantum: 0 }), /quantum/);
    assert.throws(() => engine.setCooperativeExecution({ quantum: 1.5 }), /quantum/);
    assert.throws(() => engine.setCooperativeExecution({ signal: {} }), /AbortSignal/);
    assert.throws(() => engine.setCooperativeExecution({ quantumm: 1 }), /unknown/);
  });

  test(`${runtime}: slices preserve call frames, GC locals, exception handlers and vector high halves`, async () => {
    const engine = await create();

    engine.setCooperativeExecution({ quantum: 3 });
    engine.setFuel64(1000000n);
    engine.load(`(module (type $S (struct (field i32))) (type $A (array i32)) (tag $done)
      (func $work (param i32) (result i32) (local $saved (ref null $S))
        i32.const 42 struct.new $S local.set $saved
        (loop $again i32.const 65536 array.new_default $A drop
          local.get 0 i32.const 1 i32.sub local.tee 0 br_if $again)
        local.get $saved struct.get $S 0)
      (func (export "run") (result v128)
        (block $caught (try_table (catch $done $caught) i32.const 100 call $work i32.const 42 i32.ne if unreachable end throw $done))
        v128.const i64x2 0x123456789abcdef0 0xfedcba9876543210))`);

    const result = await engine.invokeRawAsync('run');

    assert.equal(result.type, 'v128');
    assert.equal(result.bits, 0xfedcba9876543210123456789abcdef0n);
  });
}
