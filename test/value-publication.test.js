import { runtimeFactories } from './runtime.js';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const binary = new URL('../build/wiw-opt.wasm', import.meta.url);
const vector = { type: 'v128', bits: 0xfedcba98765432100123456789abcdefn };

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: direct value publication preserves vectors, opaque references and scalar bits`, async () => {
    const engine = await create(binary);
    const reference = { identity: 'publication' };

    engine.load(`(module
      (global $g (mut v128) (v128.const i64x2 0 0))
      (func (export "run") (param v128 externref) (result v128 externref f32 f64 i32 i64 v128)
        (local v128)
        local.get 0 local.tee 2 global.set $g
        global.get $g drop
        i64.const 99 drop
        local.get 2 local.get 1
        f32.const -0 f64.const -0 i32.const -1 i64.const 0x123456789abcdef0
        global.get $g))`);

    for (const bits of [vector.bits, 1n << 127n, 0n, vector.bits]) {
      const value = { type: 'v128', bits };

      assert.deepEqual(engine.invokeRaw('run', value, { type: 'externref', value: reference }), [
        value,
        { type: 'externref', value: reference },
        { type: 'f32', bits: 0x80000000n },
        { type: 'f64', bits: 0x8000000000000000n },
        { type: 'i32', bits: 0xffffffffn },
        { type: 'i64', bits: 0x123456789abcdef0n },
        value
      ]);
    }
  });

  test(`${runtime}: each early publication path traps at operand capacity and recovers`, async () => {
    const engine = await create(binary);

    for (const push of ['i64.const 7', 'local.get 0', 'global.get $g', 'ref.func $leaf']) {
      // Each recursive frame retains 32 operands, reaching 4096 before the call limit.
      const source = `(module
        (global $g v128 (v128.const i64x2 0x0123456789abcdef 0xfedcba9876543210))
        (func $leaf) (elem declare func $leaf)
        (func $recurse (export "run") (local v128)
          ${`${push}\n`.repeat(32)} call $recurse ${'drop '.repeat(32)})
        (func (export "recover") (result v128) global.get $g))`;

      engine.load(source);
      engine.setFuel(100000);

      const offset = source.indexOf(push, source.indexOf('(func $recurse'));

      assert.throws(() => engine.invoke('run'), new RegExp(`resource limit at byte ${offset}$`));
      assert.deepEqual(engine.invokeRaw('recover'), vector);
      assert.throws(() => engine.invoke('run'), new RegExp(`resource limit at byte ${offset}$`));
      assert.deepEqual(engine.invokeRaw('recover'), vector);
    }
  });
}
