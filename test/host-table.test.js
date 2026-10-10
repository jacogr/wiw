import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { runtimeFactories } from './runtime.js';

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: host table reads, writes and growth retain function and opaque external identities`, async () => {
    const i = await create();

    i.load(`(module (type $t (func (result i32)))
      (table $f (export "functions") (export "alias") 1 4 funcref)
      (table $e (export "external") 1 4 externref)
      (func $answer (export "answer") (result i32) i32.const 42)
      (elem (i32.const 0) $answer)
      (func (export "call") (param i32) (result i32) local.get 0 call_indirect $f (type $t)))`);

    const answer = i.exportFunction('answer'),
      object = {},
      promise = Promise.resolve(object);

    assert.equal(i.tableSize(), 1);
    assert.equal(i.getTable(0), answer);
    assert.equal(i.growTable(2, answer, 'alias'), 1);
    assert.equal(i.tableSize('functions'), 3);
    assert.equal(i.invoke('call', 2), 42);
    i.setTable(0, null, 'alias');
    assert.equal(i.getTable(0), null);
    assert.throws(() => i.invoke('call', 0), /undefined element/);
    i.setTable(0, answer);
    assert.equal(i.invoke('call', 0), 42);

    for (const value of [
      object,
      promise,
      undefined,
      -0,
      NaN,
      42n,
      () => {},
      {
        // Resolve or reject the test thenable with its controlled callback behavior.
        get then() {
          throw Error('opaque');
        }
      }
    ]) {
      i.setTable(0, value, 'external');
      assert.ok(Object.is(i.getTable(0, 'external'), value));
      assert.equal(i.growTable(0, value, 'external'), 1);
    }

    assert.equal(i.growTable(2, object, 'external'), 1);
    assert.equal(i.getTable(2, 'external'), object);
    assert.equal(i.growTable(2, object, 'external'), -1);
    assert.equal(i.tableSize('external'), 3);
  });

  test(`${runtime}: host tables check selectors, entry bounds and stale functions across reloads`, async () => {
    const i = await create();

    assert.throws(() => i.tableSize(), /no loaded module/);
    i.load(`(module (table (export "t") 1 2 funcref) (memory (export "m") 0)
      (func (export "f") (result i32) i32.const 1))`);

    const old = i.exportFunction('f');

    for (const selector of [-1, 1, NaN, 0.5, {}, null, 0n])
      assert.throws(() => i.tableSize(selector), /invalid table index/);

    assert.throws(() => i.getTable(0, 'missing'), /unknown export/);
    assert.throws(() => i.tableSize('m'), /export kind mismatch/);

    for (const index of [-1, 1, Infinity, NaN, 0.5, 1n << 32n]) {
      assert.throws(() => i.getTable(index), /table out of bounds|require table64/);
      assert.throws(() => i.setTable(index, old), /table out of bounds|require table64/);
    }

    assert.throws(() => i.setTable(0, () => {}), /live wiw function/);
    assert.equal(i.getTable(0), null);
    i.setTable(0, old);
    assert.equal(i.getTable(0), old);
    i.load('(module (table 0 1 externref) (table (export "t") 2 funcref))');
    assert.equal(i.tableSize('t'), 2);
    assert.equal(i.tableSize(), 0);
    assert.throws(() => i.setTable(0, old, 't'), /live wiw function/);
    assert.throws(() => i.setTable(0, undefined, 't'), /live wiw function/);
    i.load('(module)');
    assert.throws(() => i.tableSize(), /no guest table/);
  });

  test(`${runtime}: host table64 bounds and growth reject full-width overflow without truncation`, async () => {
    const i = await create();

    i.load('(module (table (export "wide") i64 1 3 externref))');

    const object = {};

    i.setTable(0n, object, 'wide');
    assert.equal(i.getTable(0n, 'wide'), object);

    for (const index of [-1n, 1n, 1n << 32n, 1n << 64n])
      assert.throws(() => i.getTable(index, 'wide'), /out of bounds/);

    assert.equal(i.growTable(1n, object, 'wide'), 1);
    assert.equal(i.getTable(1n, 'wide'), object);
    assert.equal(i.growTable(1n << 32n, object, 'wide'), -1);
    assert.equal(i.growTable((1n << 64n) - 1n, object, 'wide'), -1);
    assert.equal(i.tableSize('wide'), 2);
    assert.throws(() => i.growTable(-1n, object, 'wide'), /unsigned i64/);
    assert.throws(() => i.growTable(1n << 64n, object, 'wide'), /unsigned i64/);
  });

  test(`${runtime}: host setters enforce concrete and non-null function table types`, async () => {
    const i = await create();

    i.load(`(module (type $t (func (param i32) (result i32)))
      (func $good (export "good") (type $t) local.get 0)
      (func (export "bad") (param f32) (result f32) local.get 0)
      (table (export "typed") 1 3 (ref $t) (ref.func $good)))`);

    const good = i.exportFunction('good'),
      bad = i.exportFunction('bad');

    assert.equal(i.getTable(0, 'typed'), good);

    for (const value of [null, bad]) {
      assert.throws(() => i.setTable(0, value, 'typed'), /table element type mismatch/);
      assert.throws(() => i.growTable(1, value, 'typed'), /table element type mismatch/);
      assert.equal(i.tableSize('typed'), 1);
      assert.equal(i.getTable(0, 'typed'), good);
    }

    assert.equal(i.growTable(1, good, 'typed'), 1);
    assert.equal(i.getTable(1, 'typed'), good);
  });

  test(`${runtime}: host access preserves managed table references across collection`, async () => {
    const i = await create();

    i.load(`(module (type $S (struct (field i32))) (type $A (array i32))
      (table (export "objects") 1 3 (ref null $S))
      (func (export "new") (result (ref $S)) i32.const 42 struct.new $S)
      (func (export "bad") (result (ref $A)) i32.const 1 array.new_default $A)
      (func (export "read") (param (ref $S)) (result i32) local.get 0 struct.get $S 0))`);

    const object = i.invoke('new'),
      bad = i.invoke('bad');

    i.setTable(0, object, 'objects');
    assert.throws(() => i.setTable(0, bad, 'objects'), /table element type mismatch/);
    i.collectGarbage();
    assert.equal(i.getTable(0, 'objects'), object);
    assert.equal(i.invoke('read', i.getTable(0, 'objects')), 42);
    assert.equal(i.growTable(1, object, 'objects'), 1);

    const namespace = i.exportNamespace(); // Exporting a GC table must preserve its reference kind.
    assert.equal(namespace.objects.kind, 'table');
    i.collectGarbage();
    assert.equal(i.getTable(1, 'objects'), object);

    const foreign = await create();

    assert.throws(
      () =>
        foreign.load(
          `(module (type $S (struct (field i32)))
      (table (import "p" "objects") 1 3 (ref null $S)))`,
          { p: namespace }
        ),
      /shared table element type mismatch/
    );
    i.setTable(0, null, 'objects');
    assert.equal(i.getTable(0, 'objects'), null);
  });

  test(`${runtime}: host mutations and async forwarding synchronize shared table aliases`, async () => {
    const p = await create(),
      c = await create();

    p.load(
      `(module (import "h" "wait" (func $wait))
      (table (export "t") 1 3 funcref)
      (func (export "answer") (result i32) call $wait i32.const 42))`,
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
      (table $a (import "p" "t") 1 3 funcref)
      (table $b (import "p" "t") 1 3 funcref)
      (export "a" (table $a)) (export "b" (table $b))
      (func (export "run") (param i32) (result i32) local.get 0 call_indirect $a (type $t)))`,
      { p: p.exportNamespace() }
    );

    const answer = p.exportFunctionAsync('answer');

    c.setTable(0, answer, 'b');
    assert.equal(await c.invokeAsync('run', 0), 42);
    assert.equal(p.getTable(0, 't'), p.exportFunction('answer'));
    assert.equal(c.growTable(1, answer, 'b'), 1);
    assert.equal(p.tableSize('t'), 2);
    assert.equal(c.tableSize('a'), 2);
    assert.equal(await c.invokeAsync('run', 1), 42);
    p.setTable(0, null, 't');
    assert.equal(c.getTable(0, 'a'), null);
  });
}

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: async start and callbacks can install table functions without guest reentry`, async () => {
    const i = await create();

    await i.loadAsync(
      `(module (import "h" "install" (func $install))
      (type $t (func (result i32))) (table (export "t") 0 2 funcref)
      (func (export "answer") (result i32) i32.const 42)
      (func $start call $install) (start $start)
      (func (export "run") (result i32) i32.const 0 call_indirect (type $t)))`,
      {
        h: {
          // Install the guest function into its table from the host callback.
          install: async () => {
            await Promise.resolve();
            assert.equal(i.growTable(1, i.exportFunction('answer'), 't'), 0);
          }
        }
      }
    );
    assert.equal(await i.invokeAsync('run'), 42);
    assert.equal(i.tableSize('t'), 1);
    i.setTable(0, null, 't');
    assert.throws(() => i.invoke('run'), /undefined element/);
  });
  test(`${runtime}: host exception tables retain live payload handles and nullability`, async () => {
    const i = await create();

    i.load(`(module (tag $t (param i32)) (table (export "exceptions") 1 2 exnref)
      (func (export "capture") (result exnref)
        block $caught (result exnref) try_table (catch_all_ref $caught)
          i32.const 42 throw $t end unreachable end)
      (func (export "read") (param exnref) (result i32)
        block $caught (result i32) try_table (catch $t $caught)
          local.get 0 throw_ref end unreachable end))`);

    const value = i.invoke('capture');

    i.setTable(0, value, 'exceptions');
    assert.equal(i.getTable(0, 'exceptions'), value);
    i.collectGarbage();
    assert.equal(i.invoke('read', i.getTable(0, 'exceptions')), 42);
    assert.equal(i.growTable(1, value, 'exceptions'), 1);
    assert.throws(() => i.setTable(0, {}, 'exceptions'), /live opaque/);
    i.setTable(0, null, 'exceptions');
    assert.equal(i.getTable(0, 'exceptions'), null);
  });
}

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: text and binary host table operations match native WebAssembly tables`, async () => {
    const dir = await mkdtemp(join(tmpdir(), 'wiw-host-table-'));

    try {
      const source = `(module (table (export "f") 1 3 funcref) (table (export "e") 1 3 externref)
        (func (export "answer") (result i32) i32.const 42))`;

      await writeFile(join(dir, 'guest.wat'), source);
      execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);

      const binary = await readFile(join(dir, 'guest.wasm'));

      for (const input of [source, binary]) {
        const i = await create();

        // Select WAT loading for text input while retaining equivalent binary coverage.
        if (typeof input === 'string') i.load(input);
        else i.loadBinary(input);

        const {
          instance: { exports: native }
        } = await WebAssembly.instantiate(binary);
        const object = {};

        i.setTable(0, object, 'e');
        native.e.set(0, object);
        assert.equal(i.getTable(0, 'e'), native.e.get(0));
        assert.equal(i.growTable(2, object, 'e'), native.e.grow(2, object));
        i.setTable(0, i.exportFunction('answer'), 'f');
        native.f.set(0, native.answer);
        assert.equal(i.getTable(0, 'f')(), native.f.get(0)());
        assert.equal(i.growTable(2, i.exportFunction('answer'), 'f'), native.f.grow(2, native.answer));
        assert.equal(i.getTable(2, 'f')(), native.f.get(2)());

        for (const name of ['f', 'e']) {
          assert.equal(i.tableSize(name), native[name].length);
          assert.throws(() => native[name].grow(1), RangeError);
          assert.equal(i.growTable(1, null, name), -1);
          assert.throws(() => i.setTable(3, null, name), /out of bounds/);
          assert.throws(() => native[name].set(3, null), RangeError);
        }
      }
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
}
