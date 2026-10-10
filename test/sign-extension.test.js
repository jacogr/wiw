import { runtimeFactories } from './runtime.js';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const binary = new URL('../build/wiw-opt.wasm', import.meta.url);
const cases = [
  ['i32', 8],
  ['i32', 16],
  ['i64', 8],
  ['i64', 16],
  ['i64', 32]
];

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: sign extensions preserve canonical bits, exact fuel and full operand capacity`, async () => {
    const engine = await create(binary);
    const source = `(module ${cases
      .map(
        ([type, width]) => `
      ;; Extend the low signed lane while discarding unrelated upper input bits.
      (func (export "${type}.extend${width}_s") (param ${type}) (result ${type})
        local.get 0 ${type}.extend${width}_s)`
      )
      .join('')})`;

    engine.load(source);

    for (const [type, width] of cases) {
      const name = `${type}.extend${width}_s`;
      const limit = 1n << BigInt(width);
      const values = [
        0n,
        1n,
        (limit >> 1n) - 1n,
        limit >> 1n,
        limit - 1n,
        limit,
        limit + 1n,
        -1n,
        -(1n << BigInt(type === 'i32' ? 31 : 63))
      ];

      for (const bits of values) {
        const arg = type === 'i64' ? bits : Number(BigInt.asIntN(32, bits));
        const expected = BigInt.asIntN(width, bits);

        engine.setFuel(2);
        assert.equal(engine.invoke(name, arg), type === 'i64' ? expected : Number(expected));
      }

      engine.setFuel(1);
      assert.throws(
        () => engine.invoke(name, type === 'i64' ? 1n : 1),
        new RegExp(`exhausted fuel at byte ${source.lastIndexOf(name)}$`)
      );
      engine.setFuel(2);
      assert.equal(engine.invoke(name, type === 'i64' ? -1n : -1), type === 'i64' ? -1n : -1);
    }

    for (const [type, width] of cases) {
      engine.setFuel(10000);
      engine.load(`(module (func (export "run") (result ${type})
        ${`${type}.const 1 `.repeat(4095)} ${type}.const ${1n << (BigInt(width) - 1n)}
        ${type}.extend${width}_s ${`${type}.add `.repeat(4095)}))`);

      const expected = 4095n - (1n << (BigInt(width) - 1n));

      assert.equal(engine.invoke('run'), type === 'i64' ? expected : Number(expected));
    }
  });
}
