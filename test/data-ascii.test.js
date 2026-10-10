import assert from 'node:assert/strict';
import { test } from 'node:test';
import { runtimeFactories } from './runtime.js';

for (const [runtime, create] of runtimeFactories)
  test(`${runtime}: plain data runs preserve escaped and Unicode boundaries, capacity, names and recovery`, async () => {
    const engine = await create();

    for (const size of [0, 1, 7, 8, 15, 16, 17, 31, 32, 33, 127, 255]) {
      const plain = 'abcdefgh'.repeat(Math.ceil(size / 8)).slice(0, size);
      const payload = plain + 'λ' + String.raw`\00\ff\"\\\u{1f600}` + plain;
      const expected = Buffer.concat([
        Buffer.from(plain + 'λ'),
        Buffer.from([0, 255, 34, 92]),
        Buffer.from('😀' + plain)
      ]);

      engine.load(`(module (memory 1) (data (i32.const 3) "${payload}"))`);
      assert.deepEqual(engine.readMemory(3, expected.length), new Uint8Array(expected), `length ${size}`);
      assert.deepEqual(engine.readMemory(0, 3), new Uint8Array(3));
    }

    for (const size of [65519, 65520, 65521, 65535, 65536]) {
      engine.load(`(module (memory 1) (data (i32.const 0) "${'a'.repeat(size)}"))`);
      assert.deepEqual(engine.readMemory(0, size), new Uint8Array(size).fill(97), `capacity ${size}`);
    }

    assert.throws(
      () => engine.load(`(module (memory 1) (data (i32.const 0) "${'a'.repeat(65537)}"))`),
      /resource limit/
    );

    // Valid multibyte scalars copy completely; capacity tails retain the resource error.
    for (const scalar of ['λ', '中', '😀']) {
      const width = Buffer.byteLength(scalar);

      for (const spare of [0, 1, 2, 3, 4]) {
        const plain = 'x'.repeat(65536 - width - spare),
          payload = plain + scalar + 'y'.repeat(spare);

        engine.load(`(module (memory 1) (data (i32.const 0) "${payload}"))`);
        assert.deepEqual(
          engine.readMemory(65536 - width - spare, width + spare),
          new Uint8Array(Buffer.from(scalar + 'y'.repeat(spare)))
        );
      }

      assert.throws(
        () => engine.load(`(module (memory 1) (data (i32.const 0) "${'x'.repeat(65537 - width)}${scalar}"))`),
        /resource limit/
      );
    }

    const name = 'abcdefghijklmnopqλ';

    engine.load(`(module (func (export "abcdefghijklmnopq${String.raw`\u{3bb}`}" ) (result i32) i32.const 42))`);
    assert.equal(engine.invoke(name), 42);
    assert.throws(
      () => engine.load(`(module (func (export "abcdefghijklmnopq${String.raw`\ff`}")))`),
      /invalid|malformed|syntax/
    );
    engine.load('(module (func (export "run") (result i32) i32.const 42))');
    assert.equal(engine.invoke('run'), 42);
  });
