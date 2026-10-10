import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createInterpreter, asyncImport } from './runtime.js';
import { execFileSync } from 'node:child_process';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Create an externally resolvable promise for suspension and ordering checks.
const deferred = () => Promise.withResolvers();
const source = `(module
  (import "h" "step" (func $step (param i32) (result i32)))
  (memory (export "memory") 1 2)
  (global (export "g") (mut i32) (i32.const 0))
  (func $inner (param i32) (result i32) local.get 0 call $step)
  (func (export "run") (param i32) (result i32)
    block (result i32) i32.const 10 local.get 0 call $inner i32.add end)
  (func (export "read") (result i32) i32.const 0 i32.load))`;

test('async suspension preserves frames and permits resource access while guarding execution', async () => {
  const i = await createInterpreter(),
    gate = deferred();

  i.load(source, {
    h: {
      // Apply the host callback used by the guest invocation regression.
      step: async (value) => {
        await gate.promise;
        i.writeMemory(0, new Uint8Array([42, 0, 0, 0]));
        i.growMemory(1);
        i.setGlobal('g', value);

        return value + 1;
      }
    }
  });

  const pending = i.invokeAsync('run', 31);

  assert.throws(() => i.invoke('run', 0), /already invoking/);
  assert.throws(() => i.load('(module)'), /already invoking/);
  assert.throws(() => i.collectGarbage(), /already invoking/);
  await assert.rejects(i.invokeAsync('run', 0), /already invoking/);
  gate.resolve();
  assert.equal(await pending, 42);
  assert.equal(i.invoke('read'), 42);
  assert.equal(i.getGlobal('g'), 31);
  i.collectGarbage();
});

test('async failures, invalid results and hostile thenables recover at the import call', async () => {
  const i = await createInterpreter();
  const failure = new Error('offline');

  // Return the configured asynchronous import outcome for the recovery regression.
  let result = () => Promise.reject(failure);

  i.load(source, { h: { step: (value) => result(value) } });
  await assert.rejects(i.invokeAsync('run', 1), (error) => error.cause === failure && /h.step/.test(error.message));

  result = async () => 'bad';

  await assert.rejects(i.invokeAsync('run', 1), /host import/);

  result = () => ({
    // Resolve or reject the test thenable with its controlled callback behavior.
    get then() {
      throw failure;
    }
  });

  await assert.rejects(i.invokeAsync('run', 1), (error) => error.cause === failure);

  result = (value) => ({
    // Resolve or reject the test thenable with its controlled callback behavior.
    then(resolve) {
      resolve(value + 1);
    }
  });

  assert.equal(await i.invokeAsync('run', 31), 42);

  result = async (value) => value + 1;

  assert.throws(() => i.invoke('run', 31), /host import/);
  assert.equal(await i.invokeAsync('run', 31), 42);
});

test('async start awaits void imports for WAT and binary modules and recovers after rejection', async () => {
  const i = await createInterpreter();
  const text = `(module (import "h" "ready" (func $ready))
    (global (export "g") (mut i32) (i32.const 0))
    (func $start call $ready i32.const 42 global.set 0) (start $start))`;
  const gate = deferred();
  const pending = i.loadAsync(text, { h: { ready: () => gate.promise } });

  assert.equal(i.getGlobal('g'), 0);
  assert.throws(() => i.load('(module)'), /already invoking/);
  gate.resolve();
  await pending;
  assert.equal(i.getGlobal('g'), 42);
  await assert.rejects(
    i.loadAsync(text, {
      h: {
        // Complete the controlled host callback used by guest initialization.
        ready: async () => {
          throw new Error('no');
        }
      }
    }),
    /host import/
  );

  const dir = await mkdtemp(join(tmpdir(), 'wiw-async-'));

  try {
    await writeFile(join(dir, 'guest.wat'), text);
    execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);
    await i.loadBinaryAsync(await readFile(join(dir, 'guest.wasm')), { h: { ready: async () => {} } });
    assert.equal(i.getGlobal('g'), 42);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('async fuel retains the active budget across awaits', async () => {
  const i = await createInterpreter();
  let calls = 0;

  i.load(
    `(module (import "h" "tick" (func $tick))
    (func (export "run") loop call $tick br 0 end))`,
    {
      h: {
        // Record one host callback reached by the guest instruction sequence.
        tick: async () => {
          calls++;

          await Promise.resolve();
          i.setFuel(1000);
        }
      }
    }
  );
  i.setFuel(12);
  await assert.rejects(i.invokeAsync('run'), /exhausted fuel/);
  assert.ok(calls > 0 && calls < 12);
  i.load(source, { h: { step: async (x) => x + 1 } });
  assert.equal(await i.invokeAsync('run', 31), 42);
});

test('async typed forwarding preserves raw floats, vector halves and multiple results', async () => {
  const p = await createInterpreter(),
    c = await createInterpreter();

  p.load(
    `(module (import "h" "wait" (func $wait))
    (func (export "run") (param f32 v128) (result f32 v128)
      call $wait local.get 0 local.get 1))`,
    {
      h: {
        // Return the controlled suspension promise for this guest callback.
        wait: async () => {
          await Promise.resolve();
        }
      }
    }
  );

  const forwarded = p.exportFunctionAsync('run');

  c.load(
    `(module (import "p" "run" (func $run (param f32 v128) (result f32 v128)))
    (export "run" (func $run)))`,
    { p: { run: forwarded } }
  );

  const args = [
    { type: 'f32', bits: 0x7fa12345n },
    { type: 'v128', bits: (0xfedcba9876543210n << 64n) | 0x123456789abcdef0n }
  ];

  assert.deepEqual(await c.invokeRawAsync('run', ...args), args);
  p.load('(module)');
  assert.throws(
    () => c.load(`(module (import "p" "run" (func (param f32 v128) (result f32 v128))))`, { p: { run: forwarded } }),
    /stale binding/
  );
});

test('async reference imports distinguish opaque Promise values from awaited values', async () => {
  const i = await createInterpreter(),
    value = deferred(),
    object = {};
  const text = `(module (import "h" "get" (func $get (result externref))) (export "get" (func $get)))`;

  i.load(text, { h: { get: () => value.promise } });
  assert.equal((await i.invokeRawAsync('get')).value, value.promise);
  assert.equal(i.invoke('get'), value.promise);

  const hostile = {
    // Resolve or reject the test thenable with its controlled callback behavior.
    get then() {
      throw new Error('must stay opaque');
    }
  };

  i.load(text, { h: { get: () => hostile } });
  assert.equal((await i.invokeRawAsync('get')).value, hostile);
  i.load(text, { h: { get: asyncImport(async () => object) } });
  assert.equal((await i.invokeRawAsync('get')).value, object);
  assert.throws(() => i.invoke('get'), /host import/);
  value.resolve(object);
});

test('independent async invocations do not consume one another’s forwarding budget', async () => {
  const i = await createInterpreter(),
    gate = deferred();

  i.load(source, { h: { step: () => gate.promise } });

  const pending = i.invokeAsync('run', 1);
  const other = await createInterpreter();

  other.load(source, { h: { step: async (value) => value + 1 } });
  assert.equal(await other.invokeAsync('run', 31), 42);
  gate.resolve(2);
  assert.equal(await pending, 12);
});

test('async rejected guest exceptions retain tag identity and payloads through handlers', async () => {
  const p = await createInterpreter(),
    c = await createInterpreter();

  p.load(`(module (tag (export "t") (param i32))
    (global (export "g") (mut i32) (i32.const 0))
    (func (export "throw") (param i32) i32.const 42 global.set 0 local.get 0 throw 0))`);

  const namespace = p.exportNamespace();

  c.load(
    `(module (tag $t (import "p" "t") (param i32))
    (global $g (import "p" "g") (mut i32))
    (import "p" "throw" (func $throw (param i32)))
    (func (export "run") (result i32)
      block $caught (result i32)
        try_table (catch $t $caught) i32.const 42 call $throw end
        i32.const 0
      end global.get $g i32.add))`,
    {
      p: {
        t: namespace.t,
        g: namespace.g,

        // Throw the tagged exception used to exercise guest exception handling.
        throw: async (value) => {
          await Promise.resolve();
          namespace.throw(value);
        }
      }
    }
  );
  assert.equal(await c.invokeAsync('run'), 84);
  assert.equal(await c.invokeAsync('run'), 84);
});

test('async shared resources synchronize across awaited forwarding boundaries', async () => {
  const p = await createInterpreter(),
    c = await createInterpreter(),
    gate = deferred();

  p.load(`(module (memory (export "memory") 1 2)
    (func (export "write") (param i32) i32.const 0 local.get 0 i32.store))`);
  c.load(
    `(module (import "h" "wait" (func $wait))
    (memory (import "p" "memory") 1 2)
    (func (export "run") (result i32) call $wait i32.const 0 i32.load))`,
    { p: p.exportNamespaceAsync(), h: { wait: () => gate.promise } }
  );

  const pending = c.invokeAsync('run');

  p.invoke('write', 42);
  gate.resolve();
  assert.equal(await pending, 42);
});

test('async forwarding depth remains bounded after awaits and all instances recover', async () => {
  const engines = [];
  const text = `(module (import "h" "next" (func $next (result i32))) (export "run" (func $next)))`;

  for (let n = 0; n < 129; n++) engines.push(await createInterpreter());

  for (let n = 0; n < engines.length; n++)
    engines[n].load(text, {
      h: {
        // Advance the host fixture to its next regression value.
        next: async () => {
          await Promise.resolve();

          return n + 1 < engines.length ? engines[n + 1].invokeAsync('run') : 42;
        }
      }
    });

  await assert.rejects(engines[0].invokeAsync('run'), (error) => {
    while (error.cause) error = error.cause;

    return /forwarding depth limit/.test(error.message);
  });
  assert.equal(await engines[1].invokeAsync('run'), 42);

  for (const engine of engines) engine.load('(module)');
});

test('async indirect forwarding follows live funcrefs and preserves shared table identities', async () => {
  const p = await createInterpreter(),
    c = await createInterpreter();

  p.load(
    `(module (import "h" "wait" (func $wait))
    (table (export "table") 1 funcref)
    (func $answer (result i32) call $wait i32.const 42)
    (elem (i32.const 0) $answer))`,
    {
      h: {
        // Return the controlled suspension promise for this guest callback.
        wait: async () => {
          await Promise.resolve();
        }
      }
    }
  );
  c.load(
    `(module (type $t (func (result i32)))
    (table (import "p" "table") 1 funcref)
    (func (export "run") (result i32) i32.const 0 call_indirect (type $t)))`,
    { p: p.exportNamespaceAsync() }
  );
  assert.equal(await c.invokeAsync('run'), 42);
  assert.throws(() => c.invoke('run'), /host import/);
  assert.equal(await c.invokeAsync('run'), 42);
});

test('async exports retain aliases, stale generations and ordinary Promise result cleanup', async () => {
  const i = await createInterpreter(),
    value = deferred(),
    object = {};

  i.load(
    `(module (import "h" "get" (func $get (result externref)))
    (export "get" (func $get)) (export "alias" (func $get)))`,
    { h: { get: () => value.promise } }
  );

  const namespace = i.exportNamespaceAsync();

  assert.equal(namespace.get, namespace.alias);
  assert.equal(namespace.get, i.exportFunctionAsync('get'));

  const pending = i.invokeAsync('get');

  // Guest execution is finished even though JavaScript is still assimilating its Promise result.
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(i.invoke('get'), value.promise);
  value.resolve(object);
  assert.equal(await pending, object);
  i.load('(module)');
  await assert.rejects(namespace.get(), /stale forwarded function/);
  await assert.rejects(i.invokeAsync('get'), /unknown export/);
  await assert.rejects(i.loadBinaryAsync('bad'), /Uint8Array/);
  assert.throws(() => asyncImport(null), /must be a function/);
});
