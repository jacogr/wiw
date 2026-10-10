import { runtimeFactories } from './runtime.js';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const binary = new URL('../build/wiw-opt.wasm', import.meta.url);
const vectorMask = (1n << 128n) - 1n;
const functions = [];

for (const width of [8, 16, 32, 64]) {
  const shape = `i${width}x${128 / width}`,
    type = width === 64 ? 'i64' : 'i32';

  functions.push(`;; Compare signed lanes against another vector without losing either half.
    (func (export "compare${width}") (param v128 v128) (result v128)
      local.get 0 local.get 1 ${shape}.lt_s)`);

  for (let lane = 0; lane < 128 / width; lane++) {
    const extract = `${shape}.extract_lane${width < 32 ? '_s' : ''} ${lane}`;

    functions.push(`;; Read this signed lane at either side of the vector's half boundary.
      (func (export "extract${width}_${lane}") (param v128) (result ${type})
        local.get 0 ${extract})`);
    functions.push(`;; Replace only this lane, preserving all neighboring lane bits.
      (func (export "replace${width}_${lane}") (param v128 ${type}) (result v128)
        local.get 0 local.get 1 ${shape}.replace_lane ${lane})`);
  }
}

const source = `(module ${functions.join('\n')})`;

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: every fixed-width lane preserves signed boundaries, neighboring bits and exact guest fuel`, async () => {
    const engine = await create(binary);

    for (const padding of ['', '(; reload with a different instruction arena origin ;)']) {
      engine.load(padding + source);

      for (const width of [8, 16, 32, 64]) {
        const size = BigInt(width),
          mask = (1n << size) - 1n;
        const values = [0n, 1n, (1n << (size - 1n)) - 1n, 1n << (size - 1n), mask];

        for (const seed of [0, 2, 4]) {
          let bits = 0n,
            other = 0n,
            comparison = 0n;

          for (let lane = 0; lane < 128 / width; lane++) {
            const a = values[(lane + seed) % values.length],
              b = values[(lane + seed + 1) % values.length];
            const shift = BigInt(lane) * size;

            bits |= a << shift;
            other |= b << shift;

            // Set the comparison lane mask when the signed source lane is less than its counterpart.
            if (BigInt.asIntN(width, a) < BigInt.asIntN(width, b)) comparison |= mask << shift;
          }

          engine.setFuel(3);
          assert.equal(engine.invoke(`compare${width}`, bits, other), comparison);

          for (let lane = 0; lane < 128 / width; lane++) {
            const shift = BigInt(lane) * size,
              raw = (bits >> shift) & mask;
            const signed = BigInt.asIntN(width, raw);

            engine.setFuel(2);
            assert.equal(engine.invoke(`extract${width}_${lane}`, bits), width === 64 ? signed : Number(signed));

            for (const value of values) {
              const scalar = BigInt.asIntN(width, value);

              engine.setFuel(3);

              const result = engine.invoke(`replace${width}_${lane}`, bits, width === 64 ? scalar : Number(scalar));

              assert.equal(result, (bits & (vectorMask ^ (mask << shift))) | (value << shift));
            }
          }
        }
      }

      engine.setFuel(1);
      assert.throws(() => engine.invoke('extract8_0', vectorMask), /exhausted fuel/);
      engine.setFuel(2);
      assert.equal(engine.invoke('extract8_0', vectorMask), -1);
    }
  });
}
