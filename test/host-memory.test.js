import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runtimeFactories } from './runtime.js';

const text = `(module
  (memory $first (export "first") (export "alias") 1 3)
  (memory $empty (export "empty") 0 2)
  (memory $wide (export "wide") i64 1 3)
  (data (memory $first) (i32.const 0) "FIRST")
  (data (memory $wide) (i64.const 0) "WIDE")
  (func (export "readFirst") (param i32) (result i32) local.get 0 i32.load8_u $first)
  (func (export "readWide") (param i64) (result i32) local.get 0 i32.load8_u $wide)
  (func (export "sizeFirst") (result i32) memory.size $first)
  (func (export "sizeWide") (result i64) memory.size $wide))`;

// Encode test data as a byte array.
const bytes = (value) => new TextEncoder().encode(value);

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: indexed and named host memory operations match native text/binary resources`, async () => {
    const dir = await mkdtemp(join(tmpdir(), 'wiw-host-memory-'));

    try {
      await writeFile(join(dir, 'guest.wat'), text);
      execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);

      const binary = await readFile(join(dir, 'guest.wasm'));

      for (const input of [text, binary]) {
        const engine = await create();

        // Select WAT loading for text input while retaining the binary decoder path for bytes.
        if (typeof input === 'string') engine.load(input);
        else engine.loadBinary(input);

        const {
          instance: { exports: native }
        } = await WebAssembly.instantiate(binary);

        assert.equal(engine.memoryPages(), 1);
        assert.equal(engine.memoryPages('alias'), 1);
        assert.equal(engine.memoryPages(1), 0);
        assert.equal(engine.memoryPages('wide'), 1);
        engine.writeMemory(3, bytes('abc'), 'alias');
        new Uint8Array(native.first.buffer).set(bytes('abc'), 3);
        engine.writeMemory(2n, bytes('xyz'), 2);
        new Uint8Array(native.wide.buffer).set(bytes('xyz'), 2);

        const saved = engine.readMemory(0n, 6, 'wide');

        assert.equal(engine.growMemory(1, 'empty'), native.empty.grow(1));
        assert.equal(engine.growMemory(1n, 'wide'), Number(native.wide.grow(1n)));
        assert.equal(engine.growMemory(1, 0), native.first.grow(1));

        for (const name of ['first', 'empty', 'wide']) {
          assert.deepEqual(
            engine.readMemory(0, native[name].buffer.byteLength, name),
            new Uint8Array(native[name].buffer)
          );
          assert.equal(engine.memoryPages(name), native[name].buffer.byteLength / 65536);
        }

        assert.deepEqual(saved, engine.readMemory(0n, 6, 2));
        assert.equal(engine.invoke('readFirst', 3), 97);
        assert.equal(engine.invoke('readWide', 2n), 120);
        assert.equal(engine.invoke('sizeFirst'), 2);
        assert.equal(engine.invoke('sizeWide'), 2n);
        assert.equal(engine.growMemory(0n, 'wide'), 2);
      }
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test(`${runtime}: host selection validates names, kinds, indices and reload generations`, async () => {
    const engine = await create();

    assert.throws(() => engine.memoryPages(), /no loaded module/);
    engine.load(text);

    for (const invalid of [-1, 3, 0.5, NaN, Infinity, 1n, {}, null]) {
      assert.throws(() => engine.memoryPages(invalid), /invalid memory index/);
      assert.throws(() => engine.readMemory(0, 0, invalid), /invalid memory index/);
      assert.throws(() => engine.growMemory(0, invalid), /invalid memory index/);
    }

    assert.throws(() => engine.readMemory(0, 0, 'missing'), /unknown export/);
    assert.throws(() => engine.writeMemory(0, new Uint8Array(), 'readFirst'), /export kind mismatch/);
    assert.equal(engine.memoryPages('first'), 1);
    engine.load('(module (memory (export "wide") 0) (memory (export "first") 2))');
    assert.equal(engine.memoryPages('first'), 2);
    assert.equal(engine.memoryPages('wide'), 0);
    assert.throws(() => engine.memoryPages('alias'), /unknown export/);
    assert.throws(() => engine.load('(module'), /invalid syntax/);
    assert.throws(() => engine.memoryPages('first'), /no loaded module/);
    engine.load('(module (memory 1) (memory 0 1))');
    assert.equal(engine.memoryPages(1), 0);
    assert.equal(engine.growMemory(1, 1), 0);
    engine.writeMemory(0, bytes('private'), 1);
    assert.deepEqual(engine.readMemory(0, 7, 1), bytes('private'));
    assert.deepEqual(engine.readMemory(0, 7), new Uint8Array(7));
    engine.load('(module)');
    assert.throws(() => engine.memoryPages(), /no guest memory/);
    assert.throws(() => engine.readMemory(0, 0), /no guest memory/);
    assert.throws(() => engine.growMemory(1), /no guest memory/);
    engine.load('(module (memory (export "零\\00") 0))');
    assert.equal(engine.memoryPages('零\0'), 0);
    assert.deepEqual(engine.readMemory(0, 0, '零\0'), new Uint8Array());
  });

  test(`${runtime}: wide host addresses and growth fail without truncation or partial writes`, async () => {
    const engine = await create();

    engine.load(text);

    for (const offset of [-1n, 65537n, 1n << 32n, 1n << 64n, -1, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER]) {
      assert.throws(() => engine.readMemory(offset, 0, 'wide'), /memory out of bounds/);
      assert.throws(() => engine.writeMemory(offset, bytes('bad'), 'wide'), /memory out of bounds/);
    }

    for (const length of [-1, 0.5, Infinity, NaN, 65537, 1n])
      assert.throws(() => engine.readMemory(0n, length, 'wide'), /memory out of bounds/);

    assert.deepEqual(engine.readMemory(65536n, 0, 'wide'), new Uint8Array());
    assert.throws(() => engine.writeMemory(65535n, bytes('bad'), 'wide'), /memory out of bounds/);
    assert.deepEqual(engine.readMemory(65535n, 1, 'wide'), new Uint8Array(1));
    engine.writeMemory(65536n, new Uint8Array(), 'wide');
    assert.throws(() => engine.readMemory(0n, 0, 'first'), /require memory64/);
    assert.throws(() => engine.growMemory(1n, 'first'), /requires memory64/);

    for (const pages of [-1n, 1n << 64n]) assert.throws(() => engine.growMemory(pages, 'wide'), /unsigned i64/);

    assert.equal(engine.growMemory((1n << 64n) - 1n, 'wide'), -1);
    assert.equal(engine.growMemory(1n << 32n, 'wide'), -1);
    assert.equal(engine.growMemory(0xffffffffn, 'wide'), -1);
    assert.equal(engine.growMemory(3n, 'wide'), -1);
    assert.equal(engine.memoryPages('wide'), 1);
    assert.deepEqual(engine.readMemory(0n, 4, 'wide'), bytes('WIDE'));
    assert.equal(engine.growMemory(1n, 'wide'), 1);
    assert.deepEqual(engine.readMemory(65536n, 32, 'wide'), new Uint8Array(32));
  });

  test(`${runtime}: nonzero shared memory aliases publish host writes and growth to their provider`, async () => {
    const provider = await create(),
      consumer = await create();

    provider.load('(module (memory 1) (memory (export "shared") 1 3))');
    consumer.load(
      `(module
      (memory $a (import "p" "shared") 1 3)
      (memory $b (import "p" "shared") 1 3)
      (memory $own 1)
      (export "a" (memory $a)) (export "b" (memory $b)) (export "own" (memory $own)))`,
      { p: provider.exportNamespace() }
    );
    consumer.writeMemory(12, bytes('shared'), 'b');
    assert.deepEqual(provider.readMemory(12, 6, 'shared'), bytes('shared'));
    assert.deepEqual(consumer.readMemory(12, 6, 'a'), bytes('shared'));
    assert.deepEqual(consumer.readMemory(12, 6, 'own'), new Uint8Array(6));
    assert.equal(consumer.growMemory(1, 'b'), 1);
    assert.equal(consumer.memoryPages('a'), 2);
    assert.equal(provider.memoryPages('shared'), 2);
    provider.writeMemory(65536, bytes('grown'), 'shared');
    assert.deepEqual(consumer.readMemory(65536, 5, 1), bytes('grown'));
    assert.equal(consumer.memoryPages('own'), 1);
  });

  test(`${runtime}: async imports access and grow selected memories without altering guest selection`, async () => {
    const engine = await create(),
      gate = Promise.withResolvers();
    const source = `(module (import "h" "step" (func $step))
      (memory $first (export "first") 1 2)
      (memory $wide (export "wide") i64 1 3)
      (func (export "run") (result i32)
        call $step i64.const 65536 i32.load8_u $wide memory.size $first i32.add))`;

    engine.load(source, {
      h: {
        // Apply the host callback used by the guest invocation regression.
        step: async () => {
          await gate.promise;
          assert.equal(engine.growMemory(1n, 'wide'), 1);
          engine.writeMemory(65536n, new Uint8Array([41]), 'wide');
          assert.equal(engine.memoryPages('first'), 1);
        }
      }
    });

    const pending = engine.invokeAsync('run');

    assert.equal(engine.memoryPages('wide'), 1);
    gate.resolve();
    assert.equal(await pending, 42);
    await engine.loadAsync(
      `(module (import "h" "step" (func $step))
      (memory (export "first") 1) (memory (export "wide") i64 1 2)
      (func $start call $step) (start $start))`,
      {
        h: {
          // Apply the host callback used by the guest invocation regression.
          step: async () => {
            await Promise.resolve();
            engine.writeMemory(0n, bytes('start'), 'wide');
            assert.equal(engine.growMemory(1n, 'wide'), 1);
          }
        }
      }
    );
    assert.deepEqual(engine.readMemory(0n, 5, 'wide'), bytes('start'));
    assert.equal(engine.memoryPages('wide'), 2);
  });
}
