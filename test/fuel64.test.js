import assert from 'node:assert/strict';
import { test } from 'node:test';
import { runtimeFactories } from './runtime.js';

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: full-width fuel preserves high bits, exact exhaustion, callbacks and recovery`, async () => {
    const engine = await create();
    const source = `(module
      (import "host" "tick" (func $tick (param i32) (result i32)))
      (func (export "sum") (result i32) i32.const 20 i32.const 22 i32.add)
      (func (export "host") (result i32) i32.const 41 call $tick))`;
    let calls = 0;

    engine.load(source, {
      host: {
        // Record one host callback reached by the guest instruction sequence.
        tick: (value) => {
          calls++;

          return value + 1;
        }
      }
    });

    for (const fuel of [1n << 32n, (1n << 32n) + 1n, 1n << 63n, (1n << 64n) - 1n]) {
      engine.setFuel64(fuel);
      assert.equal(engine.invoke('sum'), 42);
      assert.equal(engine.invoke('sum'), 42, 'a new invocation receives its own full budget');
      assert.equal(engine.invoke('host'), 42, 'high bits survive suspension/resumption');
    }

    assert.equal(calls, 4);

    const offsets = [source.indexOf('i32.const 20'), source.indexOf('i32.const 22'), source.indexOf('i32.add')];

    for (let fuel = 0; fuel < 3; fuel++) {
      engine.setFuel64(BigInt(fuel));
      assert.throws(() => engine.invoke('sum'), new RegExp(`exhausted fuel at byte ${offsets[fuel]}$`));
    }

    engine.setFuel64(3n);
    assert.equal(engine.invoke('sum'), 42);

    for (const invalid of [-1n, 1n << 64n, 0, 1, 1.5, NaN, Infinity, '3', null, undefined]) {
      assert.throws(() => engine.setFuel64(invalid), /unsigned i64 BigInt/);
      assert.equal(engine.invoke('sum'), 42, 'invalid setters preserve the previous budget');
    }

    engine.setFuel(2);
    assert.throws(() => engine.invoke('sum'), /exhausted fuel/);
    engine.setFuel(3);
    assert.equal(engine.invoke('sum'), 42);
    assert.throws(() => engine.setFuel(3n), /unsigned i32/);
    engine.load(
      `(module
      (import "host" "tick" (func $tick (param i32) (result i32)))
      (func (export "resume") (result i32) i32.const 41 call $tick i32.const 0 i32.add))`,
      {
        host: {
          // Record one host callback reached by the guest instruction sequence.
          tick: (value) => {
            engine.setFuel64(1n << 63n);

            return value + 1;
          }
        }
      }
    );
    engine.setFuel64(2n);
    assert.throws(() => engine.invoke('resume'), /exhausted fuel/, 'a callback cannot refill the active invocation');
    assert.equal(engine.invoke('resume'), 42, 'the callback sets the next invocation budget');
    engine.load('(module (func (export "run") (result i32) i32.const 7))');
    engine.setFuel64(1n << 32n);
    assert.equal(engine.invoke('run'), 7);
  });
}
