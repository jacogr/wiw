import { runtimeFactories } from './runtime.js';
import assert from 'node:assert/strict';
import { test } from 'node:test';

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: scalar float dispatch retains precise traps, raw bits and fuel recovery`, async () => {
    const engine = await create();
    const source = `(module
      (func (export "convert") (param f64) (result i64) local.get 0 i64.trunc_f64_s)
      (func (export "sat") (param f64) (result i64) local.get 0 i64.trunc_sat_f64_s)
      (func (export "bits") (param f64) (result i64) local.get 0 i64.reinterpret_f64)
      (func (export "sum") (param f64 f64) (result f64) local.get 0 local.get 1 f64.add))`;

    engine.load(source);
    assert.equal(engine.invoke('convert', -1.75), -1n);

    for (const [value, error] of [
      [NaN, 'invalid conversion to integer'],
      [Infinity, 'integer overflow'],
      [2 ** 63, 'integer overflow']
    ]) {
      assert.throws(
        () => engine.invoke('convert', value),
        new RegExp(`${error} at byte ${source.indexOf('i64.trunc_f64_s')}$`)
      );
      assert.equal(engine.invoke('convert', 42.75), 42n);
    }

    const nan = 0x7ff0000000000123n;

    assert.deepEqual(engine.invokeRaw('bits', { type: 'f64', bits: nan }), { type: 'i64', bits: nan });
    assert.equal(engine.invoke('sat', NaN), 0n);
    assert.equal(engine.invoke('sat', Infinity), (1n << 63n) - 1n);
    engine.setFuel(2);
    assert.throws(
      () => engine.invoke('sum', 1.5, 2.5),
      new RegExp(`exhausted fuel at byte ${source.indexOf('f64.add')}$`)
    );
    engine.setFuel(3);
    assert.equal(engine.invoke('sum', 1.5, 2.5), 4);
    assert.ok(Object.is(engine.invoke('sum', -0, -0), -0));
  });
}
