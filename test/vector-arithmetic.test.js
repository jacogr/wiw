import assert from 'node:assert/strict';
import { test } from 'node:test';
import { runtimeFactories } from './runtime.js';

// Model integer lane wrapping and comparison masks independently of the interpreter.
const patterns = [
  0n,
  1n,
  0x7fffffffffffffffffffffffffffffffn,
  0x80000000000000000000000000000000n,
  (1n << 128n) - 1n,
  0x0123456789abcdeffedcba9876543210n
];

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: packed integer arithmetic preserves lane overflow, masks, raw halves and fuel`, async () => {
    const engine = await create();

    for (const width of [8, 16, 32])
      for (const op of width === 8 ? ['add', 'sub', 'eq', 'ne'] : ['add', 'sub', 'mul', 'eq', 'ne']) {
        const shape = `i${width}x${128 / width}`,
          source = `(module (func (export "run") (param v128 v128) (result v128) local.get 0 local.get 1 ${shape}.${op}))`;

        engine.load(source);

        const size = BigInt(width),
          mask = (1n << size) - 1n;

        for (const a of patterns)
          for (const b of patterns) {
            let expected = 0n;

            for (let lane = 0; lane < 128 / width; lane++) {
              const shift = BigInt(lane) * size,
                x = (a >> shift) & mask,
                y = (b >> shift) & mask;
              const value =
                op === 'add'
                  ? x + y
                  : op === 'sub'
                  ? x - y
                  : op === 'mul'
                  ? x * y
                  : op === 'eq'
                  ? x === y
                    ? mask
                    : 0n
                  : x !== y
                  ? mask
                  : 0n;

              expected |= (value & mask) << shift;
            }

            engine.setFuel(3);
            assert.equal(engine.invoke('run', a, b), expected, `${shape}.${op}/${a}/${b}`);
          }

        engine.setFuel(2);
        assert.throws(
          () => engine.invoke('run', patterns[5], patterns[4]),
          new RegExp(`exhausted fuel at byte ${source.indexOf(shape + '.' + op)}$`)
        );
        engine.setFuel(3);
        assert.doesNotThrow(() => engine.invoke('run', patterns[5], patterns[4]));
      }

    for (const width of [8, 16, 32, 64]) {
      const shape = `i${width}x${128 / width}`;

      engine.load(`(module (func (export "run") (param v128) (result i32) local.get 0 ${shape}.all_true))`);

      for (const bits of [...patterns, 0x01010101010101010101010101010101n]) {
        const size = BigInt(width),
          mask = (1n << size) - 1n;
        const expected = Array.from({ length: 128 / width }, (_, lane) => (bits >> (BigInt(lane) * size)) & mask).every(
          (value) => value !== 0n
        )
          ? 1
          : 0;

        engine.setFuel(2);
        assert.equal(engine.invoke('run', bits), expected, `${shape}.all_true/${bits}`);
      }
    }
  });
}
