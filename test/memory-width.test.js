import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createBootstrapInterpreter, createInterpreter} from '../wiw.js';

const accesses = [
  ['i32.load',4], ['i32.load8_s',1], ['i32.load8_u',1], ['i32.load16_s',2], ['i32.load16_u',2],
  ['i32.store',4], ['i32.store8',1], ['i32.store16',2],
  ['i64.load',8], ['i64.load8_s',1], ['i64.load8_u',1], ['i64.load16_s',2], ['i64.load16_u',2],
  ['i64.load32_s',4], ['i64.load32_u',4], ['i64.store',8], ['i64.store8',1], ['i64.store16',2], ['i64.store32',4],
  ['f32.load',4], ['f32.store',4], ['f64.load',8], ['f64.store',8]
];
for (const [runtime, create] of [['bootstrap',createBootstrapInterpreter],['interpreted',createInterpreter]]) {
  test(`${runtime}: natural scalar width bounds each access independently of its alignment hint`, async () => {
    const engine = await create();
    for (const [op,width] of accesses) {
      const type = op.split('.')[0], store = op.includes('store');
      // A deliberately small alignment must not shrink the actual range check.
      engine.load(`(module (memory 1)
        (func (export "run") (param i32) ${store ? '' : `(result ${type})`}
          local.get 0 ${store ? `${type}.const 1` : ''} ${op} align=1))`);
      engine.invoke('run',65536-width);
      const before = engine.readMemory(65536-8,8);
      assert.throws(() => engine.invoke('run',65537-width), /memory out of bounds/, op);
      assert.deepEqual(engine.readMemory(65536-8,8),before,op);
      engine.invoke('run',65536-width);
    }
    engine.load('(module (func (export "run") (param i64) (result i64) local.get 0 i64.load $wide offset=0xffffffffffffffff align=1) (memory $wide i64 1))');
    assert.throws(() => engine.invoke('run',1n), /memory out of bounds/);
  });
}
