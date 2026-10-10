import { runtimeFactories } from './runtime.js';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const binary = new URL('../build/wiw-opt.wasm', import.meta.url);

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: non-trapping unary, binary and conversion operations work at full operand capacity`, async () => {
    const engine = await create(binary);

    for (const [type, operations, expected] of [
      ['i32', 'i32.clz', 4126],
      ['i64', 'i64.eqz i64.extend_i32_u', 4095n]
    ]) {
      engine.load(`(module (func (export "run") (result ${type})
        ${`${type}.const 1 `.repeat(4096)} ${operations} ${`${type}.add `.repeat(4095)}))`);

      for (let repeat = 0; repeat < 2; repeat++) assert.equal(engine.invoke('run'), expected);
    }
  });

  test(`${runtime}: in-place integer results preserve fuel boundaries, wrapping and live caller vectors`, async () => {
    const engine = await create(binary);
    const source = `(module (func (export "run") (param i64 i64) (result i64)
      local.get 0 local.get 1 i64.sub i64.eqz i64.extend_i32_u))`;
    const sequence = ['local.get 0', 'local.get 1', 'i64.sub', 'i64.eqz', 'i64.extend_i32_u'];

    engine.load(source);

    for (let fuel = 0; fuel < sequence.length; fuel++) {
      engine.setFuel(fuel);
      assert.throws(
        () => engine.invoke('run', -(1n << 63n), 1n),
        new RegExp(`exhausted fuel at byte ${source.indexOf(sequence[fuel])}$`)
      );
      engine.setFuel(5);
      assert.equal(engine.invoke('run', -(1n << 63n), 1n), 0n);
      assert.equal(engine.invoke('run', 7n, 7n), 1n);
    }

    engine.setFuel(1000);
    engine.load(`(module
      (func $subtract (param i64 i64) (result i64) local.get 0 local.get 1 i64.sub)
      (func (export "run") (param v128) (result v128 i64)
        local.get 0 (call $subtract (i64.const -9223372036854775808) (i64.const 1))))`);

    const vector = { type: 'v128', bits: 0xfedcba98765432100123456789abcdefn };

    assert.deepEqual(engine.invokeRaw('run', vector), [vector, { type: 'i64', bits: 0x7fffffffffffffffn }]);
  });
}
