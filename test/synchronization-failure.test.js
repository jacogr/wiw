import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createMemory, createTable, createGlobal } from '../wiw.js';
import { runtimeFactories, createBootstrapInterpreter } from './runtime.js';

// Construct shared resources whose callbacks or cooperative timers can exceed a consumer's capacity.
async function fixture(create, failure, stage) {
  const provider = await createBootstrapInterpreter();

  provider.load('(module (func (export "fn")))');

  const memory = createMemory({ initial: 1, maximum: 2 });
  const table = createTable({ initial: 1, maximum: 4097, element: 'externref' });
  const number = createGlobal({ value: 'i32', mutable: true });
  const reference = createGlobal({ value: 'externref', mutable: true });
  const fn = createGlobal({ value: 'funcref', mutable: true }, provider.exportFunction('fn'));
  const token = {};
  const engine = await create(undefined, {
    limits: {
      memoryPages: failure === 'memory' ? 1 : 2,
      tableEntries: failure === 'table' ? 4096 : 4097
    }
  });

  // Publish newer host bytes, entries and globals before resumption attempts to import the whole batch.
  function change() {
    assert.equal(memory.grow(1), 1);
    memory.write(0, Uint8Array.of(42));
    memory.write(65536, Uint8Array.of(99));
    assert.equal(table.grow(4096, token), 1);
    table.set(0, token);

    number.value = 42;
    reference.value = token;

    // A stale retained function exercises failure after earlier resources were copied successfully.
    if (failure === 'global') provider.load('(module)');
  }

  const cooperative = stage.startsWith('cooperative');
  const initializing = stage.includes('start');
  const asynchronous = cooperative || stage.startsWith('async');
  const imports = {
    h: {
      memory,
      table,
      number,
      reference,
      fn,
      // Both callback forms must preserve effects if their final resource refresh fails.
      change: asynchronous
        ? async () => {
            await Promise.resolve();
            change();
          }
        : change
    }
  };
  const source = `(module
    (import "h" "number" (global $number (mut i32)))
    (import "h" "memory" (memory 1 2))
    (import "h" "table" (table 1 4097 externref))
    (import "h" "reference" (global (mut externref)))
    (import "h" "fn" (global (mut funcref)))
    (import "h" "change" (func $change))
    (func $run (export "run") (local $count i32)
      i32.const 0 i32.const 7 i32.store8 i32.const 7 global.set $number
      ${
        cooperative
          ? '(local.set $count (i32.const 1000)) (loop $again local.get $count i32.const 1 i32.sub local.tee $count br_if $again)'
          : 'call $change'
      })
    ${initializing ? '(data (i32.const 3) "X") (start $run)' : ''})`;

  // Cooperative resumption refreshes after a timer rather than through an imported callback.
  if (cooperative) engine.setCooperativeExecution({ quantum: 100 });

  // Load non-start fixtures before scheduling the host-side mutation at the first dispatch yield.
  if (!initializing) engine.load(source, imports);

  const expected =
    failure === 'memory'
      ? /shared memory growth exceeds capacity/
      : failure === 'table'
      ? /shared table growth exceeds capacity/
      : /stale|live wiw/;
  const matches = (error) => expected.test(error.cause?.message ?? error.message);

  // Initialization and invocation use separate cleanup paths, and each must relinquish stale publication authority.
  if (asynchronous) {
    // Schedule mutation before the driver's setImmediate continuation is queued.
    if (cooperative) setImmediate(change);

    await assert.rejects(initializing ? engine.loadAsync(source, imports) : engine.invokeAsync('run'), matches);
  } else {
    assert.throws(() => (initializing ? engine.load(source, imports) : engine.invoke('run')), matches);
  }

  assert.equal(memory.pages, 2);
  assert.equal(memory.read(0, 1)[0], 42);
  assert.equal(memory.read(65536, 1)[0], 99);
  assert.equal(table.length, 4097);
  assert.equal(table.get(0), token);
  assert.equal(table.get(1), token);
  assert.equal(number.value, 42);
  assert.equal(reference.value, token);

  // Failed global refresh must retain the stale host reference rather than replace it with an older guest value.
  if (failure === 'global') assert.throws(() => fn.value, /stale|live wiw/);

  // Segment writes published before the callback remain visible alongside its newer host writes.
  if (initializing) assert.equal(memory.read(3, 1)[0], 88);

  engine.setCooperativeExecution(null);
  engine.load('(module (func (export "ok") (result i32) i32.const 1))');
  assert.equal(engine.invoke('ok'), 1);
}

// Exercise failure before/after partial copying and through every execution/initialization cleanup path.
for (const [runtime, create] of runtimeFactories) {
  for (const stage of ['callback', 'async-callback', 'start', 'async-start', 'cooperative', 'cooperative-start']) {
    test(`${runtime}: ${stage} failed refresh preserves all newer host resources`, async () => {
      // Resource order deliberately places a global before the failing memory/table and references afterward.
      for (const failure of ['memory', 'table', 'global']) await fixture(create, failure, stage);
    });
  }

  test(`${runtime}: failed refresh also preserves resources owned by a provider guest`, async () => {
    const provider = await createBootstrapInterpreter();

    provider.load(
      '(module (memory (export "m") 1 2) (table (export "t") 1 2 externref) (global (export "g") (mut i32) (i32.const 0)))'
    );

    const imports = provider.exportNamespace();
    const engine = await create(undefined, { limits: { memoryPages: 1 } });
    const token = {};

    engine.load(
      '(module (import "p" "m" (memory 1 2)) (import "p" "t" (table 1 2 externref)) (import "p" "g" (global (mut i32))) (import "p" "change" (func $change)) (func (export "run") call $change))',
      {
        p: {
          ...imports,
          // Provider APIs publish host state that the smaller consumer cannot import after growth.
          change: () => {
            provider.growMemory(1);
            provider.writeMemory(65536, Uint8Array.of(99));
            provider.growTable(1, token);
            provider.setGlobal('g', 42);
          }
        }
      }
    );
    assert.throws(
      () => engine.invoke('run'),
      (error) => /shared memory growth exceeds capacity/.test(error.cause?.message)
    );
    assert.equal(provider.memoryPages(), 2);
    assert.equal(provider.readMemory(65536, 1)[0], 99);
    assert.equal(provider.tableSize(), 2);
    assert.equal(provider.getTable(1), token);
    assert.equal(provider.getGlobal('g'), 42);
  });
}
