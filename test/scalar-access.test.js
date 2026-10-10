import { runtimeFactories } from './runtime.js';
import assert from 'node:assert/strict';
import { test } from 'node:test';

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: scalar selection follows growth, callbacks and bulk transitions between memory widths`, async () => {
    const engine = await create();

    engine.load(
      `(module
      (import "env" "grow" (func $grow))
      (memory $first 1 2) (memory $wide i64 1 2)
      (func (export "run") (result i64)
        i32.const 3 i32.const -1 i32.store $first align=1
        i64.const 5 i64.const 0x123456789abcdef i64.store $wide align=1
        call $grow
        i32.const 3 i32.load $first align=1 i32.const -1 i32.ne if unreachable end
        i64.const 17 i64.const 5 i64.const 8 memory.copy $wide $wide
        i32.const 30 i32.const 90 i32.const 4 memory.fill $first
        i64.const 17 i64.load $wide align=1)
      (func (export "wide") (param i64) (result i64) local.get 0 i64.load $wide)
      (func (export "wideSize") (result i64) memory.size $wide)
      (func (export "wideGrow") (result i64) i64.const 1 memory.grow $wide)
      (func (export "firstSize") (result i32) memory.size $first))`,
      { env: { grow: () => assert.equal(engine.growMemory(1), 1) } }
    );
    assert.equal(engine.invoke('run'), 0x123456789abcdefn);
    assert.equal(engine.invoke('firstSize'), 2);
    assert.equal(engine.invoke('wideSize'), 1n);
    assert.equal(engine.invoke('wideGrow'), 1n);
    assert.equal(engine.invoke('wideSize'), 2n);
    assert.equal(engine.invoke('wide', 17n), 0x123456789abcdefn);
    assert.equal(engine.invoke('wide', 65536n), 0n);
    assert.throws(() => engine.invoke('wide', (1n << 64n) - 1n), /memory out of bounds/);
    assert.equal(engine.invoke('wide', 17n), 0x123456789abcdefn);
  });
}
